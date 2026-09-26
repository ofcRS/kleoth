import ApplicationServices
import CoreGraphics
import Foundation

/// Titles of a process's normal-layer windows, front to back, any Space.
/// `CGWindowListCopyWindowInfo` names when Screen Recording is already
/// granted (`CGPreflightScreenCaptureAccess`), else `AXWindows`/`AXTitle` when
/// Accessibility is (0.5 s messaging timeout), else nothing. NEVER prompts.
/// Call off the main actor.
public enum WindowTitleReader {
    /// Per AX element read (design §5: "AX call hangs → 0.5 s").
    static let messagingTimeout: Float = 0.5

    public static func titles(ofProcess pid: pid_t) -> [String] {
        if CGPreflightScreenCaptureAccess() {
            guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
            return list.compactMap { info in
                guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let name = info[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
                return name
            }
        }
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        // Each element messaged gets the timeout: it does not carry from the
        // application element to the windows it returns, whose reads would
        // otherwise wait the ~6 s default on a hung app (`FocusedTextReader`'s
        // rule). Never on the system-wide element — that sets it process-wide.
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let elements = windows as? [AXUIElement] else { return [] }
        return elements.compactMap { window in
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, !text.isEmpty else { return nil }
            return text
        }
    }
}
