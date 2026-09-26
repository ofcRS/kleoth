import ApplicationServices
import CoreGraphics
import Foundation

/// Titles of a process's normal-layer windows, front to back, any Space.
/// `CGWindowListCopyWindowInfo` names when Screen Recording is already
/// granted (`CGPreflightScreenCaptureAccess`), else `AXWindows`/`AXTitle` when
/// Accessibility is (0.5 s messaging timeout), else nothing. NEVER prompts.
/// Call off the main actor.
public enum WindowTitleReader {
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
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let elements = windows as? [AXUIElement] else { return [] }
        return elements.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, !text.isEmpty else { return nil }
            return text
        }
    }
}
