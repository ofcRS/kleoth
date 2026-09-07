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

/// AppKit delegate for the menu-bar agent. Handles the entry points that a
/// pure SwiftUI `App` can't cleanly own for an `LSUIElement` app: inbound
/// `kleoth://` URLs and the global record/stop hotkey (both funnel into the
/// shared `RecordingController.handle(_:)` so every surface runs one code
/// path), plus the dictation controller's launch / trust-refresh / terminate
/// hooks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { @MainActor in RecordingController.shared?.handle(.toggle) }
        }

        // Dictation (fn+shift). `AppDelegate` is a plain `NSObject` and
        // `DictationController` is `@MainActor`; both delegate callbacks arrive
        // on the main thread, so assume — never hop — so the hotkey monitor is
        // installed before the first chord can arrive.
        MainActor.assumeIsolated { DictationController.shared?.startIfEnabled() }

        // Screen recording: sweep any `*.recording.mp4` left by a crash or a
        // `kill` (neither terminate delegate runs for those) and read the
        // current Screen Recording grant.
        MainActor.assumeIsolated { ScreenRecordingController.shared?.startIfNeeded() }

        // Neither Accessibility trust nor Screen Recording has a change
        // notification: re-check whenever the user comes back from System
        // Settings, so a fresh grant installs the monitors without a relaunch
        // (Screen Recording still needs one — the row says so).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DictationController.shared?.refreshTrust()
                ScreenRecordingController.shared?.refreshPermission()
            }
        }
    }

    /// A screen recording in flight is the one thing worth delaying quit for:
    /// `finishWriting` needs a moment, and an unfinalized file is debris the
    /// launch sweep has to rescue. Returns `.terminateLater` and replies once
    /// the file is closed — or after `finalizeTimeout`, whichever comes first.
    ///
    /// Reached by ⌘Q, the popover's Quit, logout and Apple-Event quit. NOT by
    /// `kill -TERM`/`-9`: AppKit installs no SIGTERM handler, so the process
    /// dies before any delegate runs and the fragmented file is the safety net.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Synchronous, like `applicationWillTerminate`: a `Task` hop may never
        // run once the app is on its way out.
        let waiting = MainActor.assumeIsolated {
            ScreenRecordingController.shared?.beginTerminationStop {
                NSApp.reply(toApplicationShouldTerminate: true)
            } ?? false
        }
        return waiting ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // NOT `Task { @MainActor in … }`: the process may exit before a hop runs.
        // Synchronous: drops any live dictation, deletes its temp clips, removes
        // the NSEvent monitors.
        MainActor.assumeIsolated { DictationController.shared?.shutdown() }
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
