import AppKit
import Combine
import KleothCore
import OSLog
import Sparkle

/// In-app updates: Sparkle 2 behind one small controller (design:
/// `docs/plans/2026-11-16-updater.md`).
///
/// Sparkle reads the appcast (`SUFeedURL`, the latest GitHub release's `appcast.xml`) once a day:
/// `SUEnableAutomaticChecks` in Info.plist turns that on without Sparkle's permission prompt, and
/// Settings → General turns it off. An update is installed only from an archive signed with the
/// EdDSA key whose public half is `SUPublicEDKey`, and only when the user says so
/// (`SUAllowsAutomaticUpdates` is off).
///
/// A scheduled find is shown one of two ways (`UpdatePolicy.sparkleShowsScheduledUpdate`): near
/// launch, with nothing in flight and no first-run window up, Sparkle's own alert comes forward;
/// every other time the popover says "New version of Kleoth is available" with an Update button —
/// Sparkle's gentle reminders, which a menu-bar app needs because its alert would otherwise open
/// behind other apps' windows. Update brings Sparkle's alert (release notes, Install Update).
///
/// Installing quits and relaunches Kleoth, so it waits (`shouldPostponeRelaunch`) while a meeting
/// records or transcribes, a screen recording runs or a dictation is in flight, and goes ahead by
/// itself once they end. The popover says so meanwhile.
///
/// A `-KleothDemo` launch (the smoke test, the demo films) never creates Sparkle's updater: no
/// check, no network, nothing written to defaults. Settings still shows the row, inert.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
    /// A found update Kleoth shows in the popover, or one held until work in flight ends.
    struct PendingUpdate: Equatable {
        /// What the user sees: `CFBundleShortVersionString` of the update.
        let version: String
        /// For an install held back: "the meeting recording", "the transcription", … (`UpdatePolicy`).
        var waitingFor: String?
    }

    private static var instance: UpdaterController?

    /// The one updater. `KleothApp` (its `@StateObject`) and `AppDelegate` (which starts it) both
    /// ask; whichever asks first creates it.
    static func sharedInstance() -> UpdaterController {
        if let instance { return instance }
        let made = UpdaterController()
        instance = made
        return made
    }

    /// A scheduled check found this update and Kleoth shows it (the popover notice). Nil once the
    /// user has looked at it in Sparkle's alert, or the session ends.
    @Published private(set) var available: PendingUpdate?
    /// The user chose to install this update while something was in flight: it installs, and
    /// Kleoth relaunches, once that ends.
    @Published private(set) var waitingToInstall: PendingUpdate?
    /// Sparkle's own flag: false while a check or an update session is already under way.
    @Published private(set) var canCheckForUpdates = false
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (stored by Sparkle in Kleoth's defaults).
    @Published private(set) var automaticallyChecks = false

    /// False in demo mode, or in a build without a feed or a public key (a dev build's Info.plist
    /// is the same file, so in practice only demo mode): no Sparkle at all.
    let isEnabled: Bool
    /// "0.5.5 (10)" — what Settings and the popover show.
    let currentVersionLabel: String
    /// "0.5.5".
    let currentVersion: String

    private let log = Logger(subsystem: "dev.kleoth", category: "Updates")
    private var standard: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []
    /// Sparkle's continuation for a relaunch held back by `shouldPostponeRelaunch`.
    private var heldRelaunch: (() -> Void)?
    private var heldRelaunchTimer: Timer?
    /// Ticks in a row the app has been idle while a relaunch is held.
    private var idleTicks = 0
    /// Set once this session's relaunch has been held back: Sparkle postpones only once per
    /// session, so a second install request while still busy is refused instead (see
    /// `updaterShouldRelaunchApplication`).
    private var postponedThisSession = false

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        currentVersion = short ?? "?"
        currentVersionLabel = UpdatePolicy.versionLabel(shortVersion: short, build: info["CFBundleVersion"] as? String)
        let configured = (info["SUFeedURL"] as? String)?.isEmpty == false
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false
        isEnabled = !DemoMode.isOn && configured
        super.init()
    }

    /// Starts Sparkle: the daily scheduled check from now on (the first one at once when a day has
    /// passed since the last). From `applicationDidFinishLaunching`; a no-op in demo mode.
    func start() {
        guard isEnabled, standard == nil else { return }
        // Started by hand rather than in the initializer: delegates wired, then the cycle begins.
        // A misconfigured build gets Sparkle's own "Unable to Check For Updates" alert here.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        standard = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
            .store(in: &cancellables)
        controller.startUpdater()
        // A feed URL left in Kleoth's defaults (Sparkle's deprecated `setFeedURL`) would win over
        // Info.plist's. Kleoth never sets one; clear any, so the feed is always the one shipped.
        if let stray = updater.clearFeedURLFromUserDefaults() {
            log.notice("cleared a feed URL override from defaults: \(stray.absoluteString, privacy: .public)")
        }
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    /// "Check for Updates…" (popover, Settings, the app menu) and the popover's Update: Sparkle's
    /// window, in front. With a found update pending it brings that update's alert back.
    func checkForUpdates() {
        guard let standard, standard.updater.canCheckForUpdates else { return }
        // A menu-bar app's windows open behind the frontmost app's: become a regular app first
        // (Dock icon, ⌘-Tab), as History and Settings do. Undone when the session finishes.
        AppActivation.shared.windowOpened()
        standard.checkForUpdates(nil)
    }

    /// Settings → General → "Check for updates automatically".
    func setAutomaticallyChecks(_ on: Bool) {
        guard let updater = standard?.updater else { return }
        updater.automaticallyChecksForUpdates = on
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    // MARK: - What is in flight

    /// The captures and jobs a relaunch would cut short, read from the live controllers.
    private func currentActivity() -> UpdatePolicy.Activity {
        let meetings = RecordingController.shared
        let dictation = DictationController.shared
        return UpdatePolicy.Activity(
            meetingRecording: meetings?.isRecording ?? false,
            meetingProcessing: meetings?.isProcessing ?? false,
            screenRecording: ScreenRecordingController.shared?.isActive ?? false,
            dictation: (dictation?.isSessionActive ?? false) || !(dictation?.busyPendingIds.isEmpty ?? true)
        )
    }

    /// A held relaunch goes ahead after two idle ticks in a row (≥ 1 s): every capture flips its
    /// busy flag in one main-actor turn, so this is margin, not a fix for a gap.
    private func holdRelaunch(_ handler: @escaping () -> Void, version: String, waitingFor: String?) {
        heldRelaunch = handler
        postponedThisSession = true
        idleTicks = 0
        waitingToInstall = PendingUpdate(version: version, waitingFor: waitingFor)
        available = nil
        heldRelaunchTimer?.invalidate()
        heldRelaunchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHeldRelaunch() }
        }
    }

    private func tickHeldRelaunch() {
        guard let handler = heldRelaunch else { return clearHeldRelaunch() }
        let activity = currentActivity()
        guard UpdatePolicy.mayRelaunch(activity) else {
            idleTicks = 0
            if waitingToInstall?.waitingFor != activity.waitingFor {
                waitingToInstall?.waitingFor = activity.waitingFor
            }
            return
        }
        idleTicks += 1
        guard idleTicks >= 2 else { return }
        log.notice("relaunching to install \(self.waitingToInstall?.version ?? "?", privacy: .public): nothing in flight")
        clearHeldRelaunch()
        handler()
    }

    private func clearHeldRelaunch() {
        heldRelaunchTimer?.invalidate()
        heldRelaunchTimer = nil
        heldRelaunch = nil
        waitingToInstall = nil
        idleTicks = 0
    }

    /// Sparkle's "Ready to Install" window can't be closed, and after Install and Relaunch it
    /// would sit there, maybe on a shared screen, until the recording ends. Ordered out while the
    /// relaunch is held; Sparkle brings it back itself if it has anything more to show.
    private func hideReadyToInstallWindow() {
        for window in NSApp.windows where window.isVisible {
            guard let controller = window.windowController else { continue }
            if NSStringFromClass(type(of: controller)) == "SUStatusController" {
                window.orderOut(nil)
            }
        }
    }

    /// After Sparkle's last window closes, drop back to a menu-bar agent unless History or
    /// Settings is still open (`AppActivation.windowClosed` reads the live window list).
    private func scheduleActivationReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AppActivation.shared.windowClosed()
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterController: SPUUpdaterDelegate {
    /// Asked before Sparkle quits Kleoth to install: "not yet" while anything is in flight; the
    /// held continuation runs once it ends (`tickHeldRelaunch`).
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let activity = currentActivity()
        guard !UpdatePolicy.mayRelaunch(activity) else { return false }
        log.notice("holding the install of \(item.displayVersionString, privacy: .public) until \(activity.waitingFor ?? "?", privacy: .public) ends")
        holdRelaunch(installHandler, version: item.displayVersionString, waitingFor: activity.waitingFor)
        hideReadyToInstallWindow()
        // That was Sparkle's last window for now: no Dock icon for the rest of the meeting.
        scheduleActivationReset()
        return true
    }

    /// Sparkle asks this first on every install request, and postpones (above) only once per
    /// session. So a second Install and Relaunch while still busy — from a window the user brought
    /// back — is refused here: the install is called off rather than relaunching over a capture.
    /// The update is offered again at the next check.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard postponedThisSession else { return true }
        let mayRelaunch = UpdatePolicy.mayRelaunch(currentActivity())
        if !mayRelaunch { log.notice("refused a second install request while busy") }
        return mayRelaunch
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let code = (error as NSError).code
        // SUNoUpdateError (1001) is "you're up to date", not a failure.
        if code != 1001 {
            log.error("update aborted: \(error.localizedDescription, privacy: .public) (\(code))")
        }
        clearHeldRelaunch()
        postponedThisSession = false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // A held relaunch outlives the cycle on purpose: the installer is waiting for it.
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders)

// `@preconcurrency`: Sparkle calls these on the main thread but does not annotate the protocol.
extension UpdaterController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        UpdatePolicy.sparkleShowsScheduledUpdate(
            immediateFocus: immediateFocus,
            activity: currentActivity(),
            firstRunOnScreen: RecordingController.shared?.needsOnboarding ?? false
        )
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            // Sparkle's alert is coming (a check the user asked for, or a scheduled one near
            // launch): be a regular app so it is in front and ⌘-Tab-able.
            AppActivation.shared.windowOpened()
        } else {
            // Kleoth shows it: the popover notice, until the user looks or the session ends.
            log.notice("update \(update.displayVersionString, privacy: .public) found; shown in the popover")
            available = PendingUpdate(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
        if heldRelaunch == nil { postponedThisSession = false }
        scheduleActivationReset()
    }
}
