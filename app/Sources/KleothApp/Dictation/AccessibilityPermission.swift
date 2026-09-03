import AppKit
import ApplicationServices

/// Accessibility (AX) trust for the running process — required both for the
/// global fn+shift key monitors and for posting the synthetic ⌘V that inserts
/// dictated text.
///
/// macOS has no "revoke" or "query without prompting" API beyond
/// `AXIsProcessTrusted()`; the prompt call is one-shot per process and only
/// shows the system dialog the first time. Trust is bound to the app bundle
/// and its code signature, so a bare SwiftPM binary is never trusted.
@MainActor
enum AccessibilityPermission {
    /// `AXIsProcessTrusted()` — true once the user has enabled Kleoth under
    /// System Settings → Privacy & Security → Accessibility.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the "Kleoth would like to control this computer using
    /// accessibility features" dialog when untrusted; returns the current trust
    /// state. There is no `prompt:` overload of `AXIsProcessTrusted` — the
    /// options dictionary keyed by `kAXTrustedCheckOptionPrompt` is the real API.
    ///
    /// The key is spelled out as its documented string value
    /// (`"AXTrustedCheckOptionPrompt"`): the `kAXTrustedCheckOptionPrompt`
    /// symbol is imported as a global `var` (`Unmanaged<CFString>`), which
    /// Swift 6 strict concurrency rejects as shared mutable state.
    @discardableResult
    static func promptIfNeeded() -> Bool {
        let options = [promptOptionKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The string behind `kAXTrustedCheckOptionPrompt` (AXUIElement.h).
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt" as CFString

    /// Deep link to the Accessibility pane of System Settings.
    static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// Opens System Settings at the Accessibility pane.
    static func openSystemSettings() {
        guard let url = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}
