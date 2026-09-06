import AppKit
import Foundation
import KleothCapture
import KleothCore

/// Owns one screen-recording session end to end: permission, region pick,
/// `ScreenRecorder`, the pill backdrop, the recovered-file sweep, and the quit
/// hand-off (design §3.4). `@MainActor`, app-lifetime `shared` — the
/// `RecordingController` / `DictationController` shape.
///
/// **T0 STUB** — the surface is final, every method is empty, and nothing
/// constructs it yet (T5 adds the `@StateObject` in `KleothApp.swift` and the
/// `AppDelegate` hooks). `beginTerminationStop` returning `false` means "nothing
/// to wait for", which is the correct answer while the lane is stubbed.
@MainActor
final class ScreenRecordingController: ObservableObject {
    private(set) static var shared: ScreenRecordingController?

    /// The pure session machine's state — the single source of truth every
    /// surface reads (T1 implements the machine itself).
    @Published private(set) var machineState: ScreenRecordingSessionMachine.State = .idle
    @Published private(set) var lastSummary: ScreenRecordingSummary?
    /// "Stopped: display disconnected" / "mic dropped 1.2 s at 3:12" /
    /// "Recovered a screen recording" — one line for the popover.
    @Published private(set) var lastStopDetail: String?
    @Published private(set) var permissionState: ScreenRecordingPermission.State = .notDetermined

    /// Where a start came from — the pill or the popover row (§2.2).
    enum Origin {
        case pill
        case popover
    }

    private let coordinator: PillCoordinator
    private let defaults: UserDefaults

    convenience init() {
        self.init(coordinator: PillCoordinator.shared, defaults: .standard)
        Self.shared = self
    }

    init(coordinator: PillCoordinator, defaults: UserDefaults) {
        self.coordinator = coordinator
        self.defaults = defaults
    }

    /// Pill backdrop, menu-bar glyph, quit guard, popover row.
    var isActive: Bool {
        switch machineState {
        case .idle, .saved, .failed: return false
        case .checkingPermission, .pickingRegion, .starting, .recording, .stopping, .saving: return true
        }
    }

    /// The session's fixed start — the popover's `TimelineView` digits.
    var since: Date? {
        switch machineState {
        case .starting(let since), .recording(let since): return since
        case .idle, .checkingPermission, .pickingRegion, .stopping, .saving, .saved, .failed: return nil
        }
    }

    // MARK: - Commands (T5)

    /// Preflight → picker → pill `.recording` → `recorder.start()`; every
    /// failure becomes a sticky fault (§7).
    func start(from origin: Origin) {
        _ = origin
        _ = coordinator
        _ = defaults
    }

    func stop() {}

    /// `NSWorkspace.activateFileViewerSelecting`.
    func revealLast() {}

    func copyLastPath() {}

    /// Settings button; creates the folder when it is missing.
    func openRecordingsFolder() {}

    /// 1 Hz while the Settings pane is open, and on `didBecomeActive`.
    func refreshPermission() {}

    /// Launch: sweep leftover `*.recording.mp4` → `-recovered` / trash, then
    /// `refreshPermission()`.
    func startIfNeeded() {}

    /// Quit path. Returns false immediately when nothing is recording;
    /// otherwise begins `stop(.quit)` and calls `completion` on the main actor
    /// when the file is finalized or `finalizeTimeout` expires. Synchronous
    /// entry on purpose — `applicationShouldTerminate` runs on the main thread
    /// and the process may exit before any hop.
    func beginTerminationStop(completion: @escaping @MainActor () -> Void) -> Bool {
        _ = completion
        return false
    }
}
