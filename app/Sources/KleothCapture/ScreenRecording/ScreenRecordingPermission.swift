import CoreGraphics
import Foundation
import KleothCore

/// Screen Recording TCC for the running process, mirrored on
/// `AccessibilityPermission` (design §3.2).
///
/// macOS gives no "query without prompting AND without lying" API here either:
/// `CGPreflightScreenCaptureAccess()` answers for the process as it was
/// launched, so a grant made while the app runs still reads false until the
/// next launch — that is the "stale" state, and telling it apart from a real
/// denial is exactly what the requested-at stamp is for.
///
/// Lives in KleothCapture (not the app target) so the `screenrec` probe can use
/// it. Note that a binary exec'd from a shell is TCC-attributed to the shell —
/// the probe's permission state is the terminal's, not Kleoth's.
public enum ScreenRecordingPermission {
    public enum State: Sendable, Equatable {
        case granted
        /// Never asked: the system prompt has not been shown for this app yet.
        case notDetermined
        /// Preflight says no although we have asked: either the user declined,
        /// or they granted it and the process was never relaunched.
        case deniedOrStale
    }

    public static func state(defaults: UserDefaults) -> State {
        if CGPreflightScreenCaptureAccess() { return .granted }
        let key = ScreenRecordingDefaults.permissionRequestedDefaultsKey
        guard defaults.object(forKey: key) != nil else { return .notDetermined }
        return .deniedOrStale
    }

    /// Shows the system prompt when undetermined and stamps the request, so a
    /// later `false` preflight can be reported as "denied or stale" rather than
    /// "never asked". Returns the immediate preflight answer, which is `false`
    /// on the very first grant (the app has to be relaunched).
    @discardableResult
    public static func request(defaults: UserDefaults) -> Bool {
        defaults.set(Date(), forKey: ScreenRecordingDefaults.permissionRequestedDefaultsKey)
        return CGRequestScreenCaptureAccess()
    }

    /// Deep link to the Screen Recording pane of System Settings.
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
