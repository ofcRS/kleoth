import AppKit
import SwiftUI
import KeyboardShortcuts

/// Global hotkey names. The user binds these in Settings; the handler is
/// registered in `AppDelegate`.
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}

/// Manages the app's activation policy so this menu-bar agent (`LSUIElement`,
/// i.e. `.accessory`) temporarily becomes a regular app — gaining a Dock icon and
/// an entry in the ⌘-Tab application switcher — while it has a real window open
/// (History / Settings), then drops back to a pure menu-bar agent once the last
/// one closes.
///
/// Without this, an `.accessory` app's windows don't appear in ⌘-Tab, so the
/// History window can't be tabbed to or treated like a normal window.
///
/// The down-transition is computed from the *live* window list rather than a
/// reference count, so it self-heals (no leak if a close event is missed) and
/// handles overlapping windows correctly: closing History while Settings is still
/// open keeps the app regular. Main-actor isolated — every `NSApp` policy change
/// happens on the main thread.
@MainActor
final class AppActivation {
    static let shared = AppActivation()

    /// Call when a managed window (History / Settings) appears: become a regular,
    /// ⌘-Tab-able app and bring it forward.
    func windowOpened() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call when a managed window disappears: revert to a pure menu-bar agent only
    /// once no real (titled) content window remains visible. Deferred to the next
    /// runloop tick so the closing window has already left the visible set; the
    /// menu-bar popover and status item are borderless, so they don't count.
    func windowClosed() {
        DispatchQueue.main.async {
            let hasContentWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled)
            }
            if !hasContentWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// AppKit delegate for the menu-bar agent. Handles the two entry points that a
/// pure SwiftUI `App` can't cleanly own for an `LSUIElement` app: inbound
/// `kleoth://` URLs and the global record/stop hotkey. Both funnel into the
/// shared `RecordingController.handle(_:)` so every surface runs one code path.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { @MainActor in RecordingController.shared?.handle(.toggle) }
        }
    }

    /// Routes `kleoth://record`, `kleoth://stop`, `kleoth://toggle`, and
    /// `kleoth://summarize-latest`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "kleoth" {
            let verb = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let command = RecordingController.Command(rawValue: verb) else {
                NSLog("Kleoth: ignoring unknown URL command '\(verb)'")
                continue
            }
            Task { @MainActor in RecordingController.shared?.handle(command) }
        }
    }
}
