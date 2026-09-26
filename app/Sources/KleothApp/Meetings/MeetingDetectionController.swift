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
    /// Bumped by every observation and by a monitor stop: only the newest
    /// resolution is fed.
    private var resolveGeneration = 0
    private var resolveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    /// Titles per owner pid, reused for `titleCacheSeconds` (§4.4).
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
        if wantsMonitor, !monitorRunning {
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
        } else if !wantsMonitor, monitorRunning {
            monitor.stop()
            monitorRunning = false
            resolveGeneration += 1
            resolveTask?.cancel()
            resolveTask = nil
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

    private func observed(_ clients: [MicClient], run: Int) {
        guard run == monitorRun, monitorRunning else { return }
        resolveTask?.cancel()
        resolveGeneration += 1
        let generation = resolveGeneration
        let cache = titleCache
        resolveTask = Task.detached(priority: .utility) { [weak self] in
            // Owners, assertions and titles off the main actor: AX can block
            // up to 0.5 s per window.
            let (holders, fresh) = Self.resolve(clients, cache: cache, now: Date())
            guard !Task.isCancelled else { return }
            await self?.sourcesResolved(holders, freshTitles: fresh, generation: generation)
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

    private func sourcesResolved(_ holders: [String: Holder], freshTitles: [pid_t: CachedTitles], generation: Int) {
        guard generation == resolveGeneration else { return }
        let now = Date()
        titleCache.merge(freshTitles) { _, new in new }
        if titleCache.count > 64 {
            titleCache = titleCache.filter { now.timeIntervalSince($0.value.at) < MeetingDetectionDefaults.titleCacheSeconds }
        }
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
        log.info("mic held by \(sources.count, privacy: .public) source(s): \(keys, privacy: .public)")
        feed(.observed(sources, at: now))
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
                // under the pointer, a running screen recording): refused,
                // and the machine asks again after `busyRetry`. This is also
                // how "Hide for 1 hour" and a screen recording hold back a
                // STOP suggestion — the machine does not suppress it for
                // either (only offers), so the pill's answer is the gate.
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
