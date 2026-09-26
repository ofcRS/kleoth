import AppKit
import Combine
import Foundation
import KleothCapture
import KleothCore
import KleothPillUI
import os

/// Runs call detection (meetings-in-the-pill design §3.2, §4.4): the
/// `MicActivityMonitor` while detection is on or a meeting records, owner
/// resolution and window titles off the main actor, the pure
/// `MeetingDetector`, its effects as pill prompts through `PillCoordinator`,
/// the "never" list in the Keychain, and the context every meeting gets at
/// stop.
///
/// One instance (`sharedInstance()`): `KleothApp` holds it as a
/// `@StateObject` injected into Settings only, and `applicationDidFinishLaunching`
/// starts it — whichever asks first creates it, so detection never waits for
/// the Settings scene to be built. Never created or started on a
/// `-KleothDemo` launch (no `KleothApp`, no delegate; `start()` checks too).
///
/// Privacy: window titles are read only through `WindowTitleReader` (with a
/// grant Kleoth already has — never a prompt), used for the match, kept only
/// when they matched a meeting pattern, and never logged. The log gets source
/// keys (bundle ids), kinds, booleans and counts.
@MainActor
final class MeetingDetectionController: ObservableObject {
    private(set) static var shared: MeetingDetectionController?

    /// The one controller, created on first use.
    static func sharedInstance() -> MeetingDetectionController {
        if let shared { return shared }
        let controller = MeetingDetectionController()
        shared = controller
        return controller
    }

    /// Settings → Meetings → "Offer to record calls" (Keychain `meeting_detection`).
    @Published private(set) var isEnabled: Bool
    /// Source key → name, "Never offered for" (Keychain `meeting_detection_ignored`).
    @Published private(set) var ignored: [String: String]
    /// "Call detection isn't available: <OSStatus>" when the monitor cannot start.
    @Published private(set) var unavailableReason: String?

    private let monitor = MicActivityMonitor()
    private var detector = MeetingDetector()
    /// What the detector was last told (`updateEnvironment` feeds only changes).
    private var environment: MeetingDetector.Environment
    private var recordingSince: Date?
    private var started = false
    private var subscriptions: Set<AnyCancellable> = []

    /// Whether `monitor` runs, kept here: its own `isRunning` is a `queue.sync`.
    private var monitorRunning = false
    /// Bumped at every monitor start: a callback hop from an earlier run that
    /// lands after a stop + restart is dropped (the new run only reports a
    /// CHANGE, so a stale set would stand).
    private var monitorRun = 0
    /// Bumped by every resolution started and by a monitor stop: only the
    /// newest resolution is fed.
    private var resolveGeneration = 0
    private var tickTask: Task<Void, Never>?
    /// The mic clients the monitor last reported (it reports only CHANGES);
    /// re-resolved every `pollWhileHeld` s while a refresh is wanted
    /// (`keepRefreshing`).
    private var heldClients: [MicClient] = []
    /// The next re-resolution of `heldClients`, chained after each one.
    private var refreshTask: Task<Void, Never>?
    /// The newest resolution is still running off the main actor: its end
    /// chains the next refresh, so none is scheduled meanwhile.
    private var resolving = false
    /// The source keys last logged, so the 3 s refresh logs only a change.
    private var loggedKeys: String?

    /// Titles per owner pid, reused for `titleCacheSeconds` (§4.4); expired
    /// entries are dropped at every merge, and all of it once nothing holds
    /// the mic or the monitor stops — titles that matched nothing are used
    /// for the match only.
    private var titleCache: [pid_t: CachedTitles] = [:]
    /// The matched window title per app bundle id seen during the current
    /// meeting — the context's fallback when the primary source carries none.
    private var lastTitles: [String: String] = [:]

    /// Events are drained one at a time (`feed`).
    private var feeding = false
    private var queued: [MeetingDetector.Event] = []

    private let log = Logger(subsystem: "dev.kleoth", category: "MeetingDetection")

    private init() {
        let settings = AppConfig.settings()
        isEnabled = settings.meetingDetection
        ignored = settings.meetingDetectionIgnored
        environment = MeetingDetector.Environment(
            offersEnabled: settings.meetingDetection,
            ignoredKeys: Set(settings.meetingDetectionIgnored.keys)
        )
    }

    // MARK: - Lifecycle

    /// From `applicationDidFinishLaunching`, after `MeetingPillBridge.install()`.
    func start() {
        guard !DemoMode.isOn, !started else { return }
        started = true
        // The detector starts with detection off and an empty list; the sinks
        // below only feed CHANGES, so the settings go in once here.
        feed(.environment(environment, at: Date()))

        if let recording = RecordingController.shared {
            recording.$recordingSince.sink { [weak self] since in
                Task { @MainActor in self?.recordingChanged(since) }
            }.store(in: &subscriptions)
            recording.meetingContextProvider = { [weak self] startedAt, stoppedAt in
                self?.context(startedAt: startedAt, stoppedAt: stoppedAt) ?? MeetingContext()
            }
        } else {
            log.fault("RecordingController.shared is nil at launch — no meeting context, no stop suggestion")
        }
        if let screen = ScreenRecordingController.shared {
            screen.$machineState.sink { [weak self] _ in
                // `@Published` fires on willSet: read `isActive` after the hop.
                Task { @MainActor in
                    self?.updateEnvironment { $0.screenRecording = ScreenRecordingController.shared?.isActive ?? false }
                }
            }.store(in: &subscriptions)
        } else {
            log.fault("ScreenRecordingController.shared is nil at launch — offers won't wait for a screen recording")
        }
        if let dictation = DictationController.shared {
            dictation.$pillHiddenUntil.sink { [weak self] until in
                Task { @MainActor in self?.updateEnvironment { $0.pillHidden = until != nil } }
            }.store(in: &subscriptions)
        } else {
            log.fault("DictationController.shared is nil at launch — offers won't respect Hide for 1 hour")
        }
        PillCoordinator.shared.onMeetingPromptDisplaced = { [weak self] id in
            self?.answer(offerId: id, .displaced)
        }
        syncMonitor()
        log.notice("call detection started — offers \(self.isEnabled ? "on" : "off", privacy: .public)")
    }

    /// Detection on, or a meeting recording (context is collected for every
    /// meeting, §3.2.1).
    private var wantsMonitor: Bool { isEnabled || recordingSince != nil }

    private func syncMonitor() {
        guard started else { return }
        if wantsMonitor {
            guard !monitorRunning else { return }
            monitorRun += 1
            let run = monitorRun
            do {
                try monitor.start { [weak self] clients in
                    // On the monitor's queue: hop before touching anything —
                    // the monitor's own `isRunning` / `stop` would deadlock here.
                    Task { @MainActor in self?.observed(clients, run: run) }
                }
                monitorRunning = true
                unavailableReason = nil
                log.notice("mic activity monitor started")
            } catch MicActivityMonitorError.listenerFailed(let status) {
                unavailableReason = "Call detection isn't available: \(status)"
                log.error("mic activity monitor failed: \(status, privacy: .public)")
            } catch {
                unavailableReason = "Call detection isn't available: \(error.localizedDescription)"
                log.error("mic activity monitor failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            // A failure to start no longer matters once nothing wants the
            // monitor; the next start tries again and says so again.
            if unavailableReason != nil { unavailableReason = nil }
            guard monitorRunning else { return }
            monitor.stop()
            monitorRunning = false
            resolveGeneration += 1
            resolving = false
            refreshTask?.cancel()
            refreshTask = nil
            heldClients = []
            titleCache = [:]
            loggedKeys = nil
            log.notice("mic activity monitor stopped")
            // Nothing is watched now: every session is released, and expires
            // after its grace like any other.
            feed(.observed([], at: Date()))
        }
    }

    private func recordingChanged(_ since: Date?) {
        guard since != recordingSince else { return }
        if since != nil { lastTitles = [:] }
        recordingSince = since
        updateEnvironment { $0.meetingSince = since }
        syncMonitor()
    }

    private func updateEnvironment(_ change: (inout MeetingDetector.Environment) -> Void) {
        var next = environment
        change(&next)
        guard next != environment else { return }
        environment = next
        feed(.environment(next, at: Date()))
    }

    // MARK: - Settings

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        Keychain.set(on ? "true" : "false", Keychain.Account.meetingDetection)
        log.notice("call detection \(on ? "on" : "off", privacy: .public)")
        updateEnvironment { $0.offersEnabled = on }
        syncMonitor()
    }

    /// Settings → "Never offered for" → Remove.
    func unignore(key: String) {
        guard ignored.removeValue(forKey: key) != nil else { return }
        persistIgnored()
    }

    private func persistIgnored() {
        Keychain.set(MeetingDetectionIgnored.encode(ignored), Keychain.Account.meetingDetectionIgnored)
        updateEnvironment { $0.ignoredKeys = Set(ignored.keys) }
    }

    // MARK: - Observations → sources

    private struct CachedTitles: Sendable {
        var titles: [String]
        var at: Date
    }

    /// One app holding the mic (all its clients), resolved off the main actor.
    private struct Holder: Sendable {
        var owner: MicOwner
        var titles: [String] = []
        var titledPids: Set<pid_t> = []
        var hasWebCall = false
    }

    /// The monitor's report: the full set of clients, on a change only.
    private func observed(_ clients: [MicClient], run: Int) {
        guard run == monitorRun, monitorRunning else { return }
        heldClients = clients
        startResolution(clients, run: run)
    }

    /// Resolves `clients` off the main actor: owners, assertions and titles —
    /// AX can block up to 0.5 s per window. A newer resolution supersedes this
    /// one without cancelling it (its titles still reach the cache); only the
    /// newest is fed.
    private func startResolution(_ clients: [MicClient], run: Int) {
        refreshTask?.cancel()
        refreshTask = nil
        resolveGeneration += 1
        resolving = true
        let generation = resolveGeneration
        let cache = titleCache
        Task.detached(priority: .utility) { [weak self] in
            let (holders, fresh) = Self.resolve(clients, cache: cache, now: Date())
            await self?.sourcesResolved(holders, freshTitles: fresh, generation: generation, run: run)
        }
    }

    /// Whether the held clients are worth resolving again: a meeting records
    /// (its context wants the title), or the detector could still offer a
    /// session, whose class may yet go up (`hasOfferableSession`). Not for an
    /// app that has held the mic past `maxOfferAge`, one already offered,
    /// answered or "never" (a browser that can still name a call aside), or
    /// with detection off and nothing recording — those must not wake Kleoth
    /// every 3 s for as long as the mic stays held.
    private var wantsRefresh: Bool {
        monitorRunning && !heldClients.isEmpty
            && (recordingSince != nil || detector.hasOfferableSession(at: Date()))
    }

    /// While a refresh is wanted, the same clients are resolved again every
    /// `pollWhileHeld` s: a meeting title or a web-call assertion that appears
    /// after the mic was taken (a lobby, then the call; a switch to the Meet
    /// tab) moves the session up a class (§3.2.2, §3.2.4) and reaches the
    /// context (§3.2.6). The monitor itself reports only a change of the SET,
    /// which a call joined in the same Chrome audio service never is. Titles
    /// come from the `titleCacheSeconds` cache, so a window is read at most
    /// every 30 s.
    ///
    /// Called after every `feed`: the detector's answer only turns from "no"
    /// to "yes" through an event (a displaced offer, detection switched on, a
    /// meeting starting), so the chain picks up again from there. At most one
    /// refresh is pending, and none while a resolution runs — its end feeds
    /// the detector, which chains the next: a slow title read is never
    /// cancelled by a refresh, and refreshes can't pile up.
    private func keepRefreshing() {
        guard refreshTask == nil, !resolving, wantsRefresh else { return }
        let run = monitorRun
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MeetingDetectionDefaults.pollWhileHeld))
            // Not cancelled = still the pending one (every replacement cancels first).
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            guard run == self.monitorRun, self.wantsRefresh else { return }
            self.startResolution(self.heldClients, run: run)
        }
    }

    /// Clients → the apps a person would name, each with its window titles
    /// (never for a `.never` app; cached per pid) and whether a web-call
    /// assertion is held by it or by any process of the same app.
    nonisolated private static func resolve(
        _ clients: [MicClient], cache: [pid_t: CachedTitles], now: Date
    ) -> (holders: [String: Holder], fresh: [pid_t: CachedTitles]) {
        let webPids = WebCallAssertions.pids()
        let webApps = Set(webPids.compactMap {
            MicOwnerResolver.owner(of: MicClient(pid: $0, bundleId: nil, executablePath: nil))?.bundleId
        })
        var holders: [String: Holder] = [:]
        var fresh: [pid_t: CachedTitles] = [:]
        for client in clients {
            guard let owner = MicOwnerResolver.owner(of: client) else { continue }
            var holder = holders[owner.bundleId] ?? Holder(owner: owner)
            if MeetingAppCatalog.verdict(bundleId: owner.bundleId, appName: owner.name) != .never,
               !holder.titledPids.contains(owner.pid) {
                holder.titledPids.insert(owner.pid)
                if let cached = cache[owner.pid] ?? fresh[owner.pid],
                   now.timeIntervalSince(cached.at) < MeetingDetectionDefaults.titleCacheSeconds {
                    holder.titles += cached.titles
                } else {
                    let titles = WindowTitleReader.titles(ofProcess: owner.pid)
                    fresh[owner.pid] = CachedTitles(titles: titles, at: now)
                    holder.titles += titles
                }
            }
            if webPids.contains(client.pid) || webApps.contains(owner.bundleId) { holder.hasWebCall = true }
            holders[owner.bundleId] = holder
        }
        return (holders, fresh)
    }

    private func sourcesResolved(
        _ holders: [String: Holder], freshTitles: [pid_t: CachedTitles], generation: Int, run: Int
    ) {
        // A run the monitor has since stopped: nothing of it stays.
        guard run == monitorRun, monitorRunning else { return }
        let now = Date()
        // Even a superseded resolution's titles are kept: the next one reads
        // them from the cache instead of asking AX again.
        titleCache.merge(freshTitles) { old, new in new.at >= old.at ? new : old }
        titleCache = titleCache.filter { now.timeIntervalSince($0.value.at) < MeetingDetectionDefaults.titleCacheSeconds }
        // Nothing holds the mic now: no title is kept for later.
        if heldClients.isEmpty { titleCache = [:] }
        guard generation == resolveGeneration else { return }
        resolving = false
        var sources = Set<MeetingSource>()
        for (bundleId, holder) in holders {
            guard let source = MeetingSource.make(
                bundleId: bundleId, appName: holder.owner.name,
                windowTitles: holder.titles, hasWebCall: holder.hasWebCall
            ) else { continue }
            sources.insert(source)
            if recordingSince != nil, let title = source.windowTitle { lastTitles[bundleId] = title }
        }
        let keys = sources.map(\.key).sorted().joined(separator: ",")
        if keys != loggedKeys {
            loggedKeys = keys
            log.info("mic held by \(sources.count, privacy: .public) source(s): \(keys, privacy: .public)")
        }
        feed(.observed(sources, at: now))   // chains the next refresh (`keepRefreshing`)
    }

    // MARK: - The machine

    /// Events are drained one at a time: an effect can produce another event
    /// (a refused show → `.refused`; a coordinator report → `.displaced`; a
    /// persisted "never" → `.environment`), which must not re-enter `handle`.
    private func feed(_ event: MeetingDetector.Event) {
        queued.append(event)
        guard !feeding else { return }
        feeding = true
        defer { feeding = false }
        while !queued.isEmpty {
            let next = queued.removeFirst()
            for effect in detector.handle(next) { apply(effect) }
        }
        scheduleTick()
        keepRefreshing()
    }

    private func apply(_ effect: MeetingDetector.Effect) {
        let coordinator = PillCoordinator.shared
        switch effect {
        case .show(let offer):
            let prompt: PillPrompt
            switch offer.kind {
            case .start:
                prompt = PillPrompt(
                    id: offer.id,
                    text: MeetingOfferText.offer(for: offer.source, calendarTitle: currentCalendarTitle(for: offer.source)),
                    symbolName: "person.2.wave.2.fill", tint: .record,
                    primary: .meeting(.acceptOffer(id: offer.id)),
                    // The display NAME: the pill words the button itself
                    // ("Never for Zoom" / "Never for calls in Chrome").
                    secondary: .meeting(.neverOffer(key: offer.source.key, name: offer.source.name))
                )
            case .stop:
                prompt = PillPrompt(
                    id: offer.id, text: MeetingOfferText.stop(for: offer.source),
                    symbolName: "stop.circle.fill", tint: .accent,
                    primary: .meeting(.acceptStop(id: offer.id))
                )
            }
            if coordinator.showMeetingPhase(.prompt(prompt)) {
                log.notice("\(offer.kind == .start ? "offer" : "stop suggestion", privacy: .public) shown: \(offer.source.key, privacy: .public)")
            } else {
                // The pill is busy (a dictation, a save, the dock or menu
                // under the pointer) or yields to a screen recording's bar
                // the machine hasn't heard of yet: refused, and the machine
                // asks again after `busyRetry`. A running screen recording
                // holds back a stop suggestion in the MACHINE (§3.2.5), as it
                // does offers. "Hide for 1 hour" holds back offers only: the
                // coordinator never refuses a prompt for it, so a stop
                // suggestion shows over the meeting bar, which a hidden pill
                // shows anyway (the hot-mic rule).
                queued.append(.answered(offerId: offer.id, .refused, at: Date()))
            }
        case .withdraw(let offerId):
            if coordinator.currentMeetingPromptId == offerId { coordinator.dismissMeetingPhase() }
        case .ignore(let key, let name):
            ignored[key] = name
            persistIgnored()
            log.notice("never offered again: \(key, privacy: .public)")
        }
    }

    /// The pill's answer on the offer `offerId`: accept (the bridge's Record /
    /// Stop), ✕, displaced (the coordinator). True when it was the visible
    /// offer — anything else is stale (a double click, a prompt the detector
    /// already withdrew) and changes nothing.
    @discardableResult
    func answer(offerId: String, _ answer: MeetingDetector.Answer) -> Bool {
        guard detector.visibleOffer?.id == offerId else { return false }
        feed(.answered(offerId: offerId, answer, at: Date()))
        return true
    }

    /// "Never for …" on the visible offer (the action carries key + name, not
    /// the id). The detector persists it (`.ignore`) but leaves the prompt to
    /// its host: it goes here, unless the answer already put the next due
    /// source's offer in its place.
    func neverVisibleOffer(key: String, name: String) {
        guard let offer = detector.visibleOffer, offer.kind == .start, offer.source.key == key else { return }
        feed(.answered(offerId: offer.id, .never, at: Date()))
        let coordinator = PillCoordinator.shared
        if coordinator.currentMeetingPromptId == offer.id { coordinator.dismissMeetingPhase() }
    }

    /// A `.tick` at the detector's next deadline — every second at most while
    /// a prompt is up (the pointer on the pill holds it), and never sooner
    /// than 0.25 s: a deadline already past must not become a main-actor loop
    /// (pre-flight C-1; the machine keeps its deadlines ahead, this is the
    /// belt and braces).
    private func scheduleTick() {
        tickTask?.cancel()
        tickTask = nil
        guard let deadline = detector.nextDeadline else { return }
        let promptUp = detector.visibleOffer != nil
        let wait = max(0.25, min(deadline.timeIntervalSinceNow, promptUp ? 1 : 3600))
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.feed(.tick(at: Date(), pointerOnPill: PillCoordinator.shared.isPointerOverPill))
        }
    }

    // MARK: - Context

    /// The meeting's app / service / window title / mic seconds (§3.2.6):
    /// the longest holder (≥ 20 s), else the linked source. The origin and
    /// the calendar are `RecordingController`'s, which reads this at stop,
    /// before the detector hears the meeting end.
    func context(startedAt: Date, stoppedAt: Date) -> MeetingContext {
        var context = MeetingContext()
        guard let primary = detector.meetingSource(at: stoppedAt) else { return context }
        let source = primary.source
        context.appName = source.appName
        context.appBundleId = source.appBundleId
        context.service = Self.service(of: source)
        context.windowTitle = source.windowTitle ?? lastTitles[source.appBundleId]
        context.micSeconds = primary.micSeconds.rounded()
        return context
    }

    /// The service a source names — a call or chat app, or a browser call on
    /// a known site — else nil (a browser or an unknown app names none).
    private static func service(of source: MeetingSource) -> String? {
        switch source.sourceClass {
        case .callApp, .chatApp: source.name
        case .browserCall: source.key.hasPrefix("site:") ? source.name : nil
        case .browser, .otherApp: nil
        }
    }

    /// The title of the calendar event on now for an offer on `source`, for
    /// its text ("“Weekly sync” on Zoom — record it?") — only with calendar
    /// access already granted: no EventKit call otherwise, never a prompt.
    /// The same matcher as the meeting's own naming at stop, with the source's
    /// service as the link hint. Never logged.
    private func currentCalendarTitle(for source: MeetingSource) -> String? {
        guard RecordingController.shared?.calendarAuthorized == true else { return nil }
        let now = Date()
        return CalendarLookup.candidates(around: now).flatMap {
            CalendarEventMatcher.best($0, at: now, serviceId: Self.service(of: source))?.title
        }
    }
}
