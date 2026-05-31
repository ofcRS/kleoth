import AppKit
import SwiftUI
import KeyboardShortcuts

/// Global hotkey names. The user binds these in Settings; the handler is
/// registered in `AppDelegate`.
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
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

    /// Routes `kleoth://record`, `kleoth://stop`, `kleoth://toggle`,
    /// `kleoth://summarize-latest`, `kleoth://slack-latest`.
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
