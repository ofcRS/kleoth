import AppKit
import KleothCore

// THE CONTRACT FILE for dictation v1 (design doc §3.14). Every task builds
// against these declarations: the pill (T6) and hotkey monitor (T1) conform to
// the protocols here, the inserter (T7) throws `TextInsertionError`, and the
// controller (T8) drives all of them. Change a signature here and you change
// every lane — don't.

// MARK: Pill

/// What the floating pill shows. The controller owns transitions; the pill
/// only renders.
enum DictationPillState: Equatable, Sendable {
    case hidden
    case listening(handsFree: Bool)
    case transcribing
    case polishing
    case done
    /// Text WAS pasted/copied, but something degraded (raw fallback, clipboard-only).
    case warning(String)
    /// Nothing was pasted; sticky until dismissed/replaced.
    case failed(DictationPillFault)

    /// `.done` → 1.0 s, `.warning` → 3.0 s, everything else nil (persists).
    var autoHideAfter: Duration? {
        switch self {
        case .done: return .seconds(1)
        case .warning: return .seconds(3)
        case .hidden, .listening, .transcribing, .polishing, .failed: return nil
        }
    }
}

/// Why a dictation produced nothing — each carries user-facing copy and, when
/// the user can fix it themselves, an action button.
enum DictationPillFault: Equatable, Sendable {
    case missingElevenLabsKey
    case needsAccessibility
    case secureInput
    case message(String)

    var text: String {
        switch self {
        case .missingElevenLabsKey: return "Add an ElevenLabs key to dictate"
        case .needsAccessibility: return "Kleoth needs Accessibility access"
        case .secureInput: return "The focused field blocks dictation"
        case .message(let message): return message
        }
    }

    var action: DictationPillAction? {
        switch self {
        case .missingElevenLabsKey: return .openSettings
        case .needsAccessibility: return .openAccessibilitySettings
        case .secureInput, .message: return nil
        }
    }
}

enum DictationPillAction: Equatable, Sendable {
    case openSettings
    case openAccessibilitySettings

    var title: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .openAccessibilitySettings: return "Open Accessibility"
        }
    }
}

/// The floating pill as the controller sees it (implemented by
/// `DictationPillController`, T6).
@MainActor
protocol DictationPillPresenting: AnyObject {
    var onAction: ((DictationPillAction) -> Void)? { get set }
    /// ✕ or click on a `.failed` pill.
    var onDismiss: (() -> Void)? { get set }
    /// Replaces the phase; cancels any pending auto-hide. `.hidden` == `dismiss()`.
    func show(_ state: DictationPillState)
    /// 0…1, already normalized + smoothed by the caller.
    func setLevel(_ level: Double)
    func dismiss()
    func resetPosition()
}

// MARK: Hotkey

/// The fn+shift chord monitor as the controller sees it (implemented by
/// `DictationHotkeyMonitor`, T1, around the pure `DictationChordMachine`).
@MainActor
protocol DictationHotkeyMonitoring: AnyObject {
    var events: AsyncStream<DictationHotkeyEvent> { get }
    var isRunning: Bool { get }
    /// While true, an Escape keyDown emits `.escapePressed`. The controller sets it to TRUE on
    /// `.began` / `.toggledOn` (the moment the pill appears) and back to false only in
    /// `endSession()` (§2.3) — listening cancel paths and `run()`'s single `defer`.
    var escapeCancels: Bool { get set }
    /// false (and installs nothing) when !AXIsProcessTrusted().
    @discardableResult
    func start() -> Bool
    /// Removes the monitors and cancels the deadline task. Does NOT finish the `events`
    /// stream — `start()` may be called again (Settings toggle off→on) on the same stream.
    /// The controller ends consumption by cancelling its `eventTask` (`AsyncStream` iteration
    /// returns nil on task cancellation), which `shutdown()` does.
    func stop()
    /// Feeds `.abort` into the machine.
    func abort()
}

// MARK: How views reach the controller
// Every SwiftUI view that touches dictation (`SettingsDictationSection`, `DictationsListView`,
// `DictationDetailView`, the optional `MenuView` button) declares
//     @EnvironmentObject private var dictation: DictationController
// and NOTHING else — never `DictationController.shared`: reading `@Published` through a plain
// static does not subscribe the view, so `logRevision` / `isTrusted` would never refresh it.
// The `@StateObject` + `.environmentObject(dictation)` wiring lives in `KleothApp.swift`.

// MARK: Insertion

/// The app that had keyboard focus — sampled at chord-down for the polish
/// prompt + log, and again at paste time by the inserter.
struct DictationTarget: Sendable, Equatable {
    var bundleIdentifier: String?
    var localizedName: String?

    @MainActor
    static func frontmost() -> DictationTarget {
        let app = NSWorkspace.shared.frontmostApplication
        return DictationTarget(
            bundleIdentifier: app?.bundleIdentifier,
            localizedName: app?.localizedName
        )
    }

    /// True when the frontmost app is Kleoth itself.
    var isKleoth: Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return bundleIdentifier == (Bundle.main.bundleIdentifier ?? "dev.kleoth.app")
    }
}

/// Why `TextInserting.insert` could not post ⌘V. On every case except
/// `.emptyText` the dictated text has been left on the clipboard (unmarked) so
/// the user can paste it by hand.
enum TextInsertionError: Error, LocalizedError, Equatable {
    case emptyText
    /// Text left on the clipboard.
    case accessibilityNotTrusted
    /// Text left on the clipboard.
    case secureInputActive
    /// Text left on the clipboard.
    case eventCreationFailed

    /// `self != .emptyText`.
    var textLeftOnClipboard: Bool {
        self != .emptyText
    }

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Nothing to insert."
        case .accessibilityNotTrusted:
            return "Kleoth needs Accessibility access to paste. Text copied — press ⌘V."
        case .secureInputActive:
            return "Secure input is on in the focused app. Text copied — press ⌘V."
        case .eventCreationFailed:
            return "Couldn't send the paste keystroke. Text copied — press ⌘V."
        }
    }
}

/// Pasteboard → ⌘V → restore (implemented by `TextInserter`, T7).
@MainActor
protocol TextInserting: AnyObject {
    /// Snapshot → write → ⌘V → restore after `DictationDefaults.pasteboardRestoreDelay`.
    /// Returns the app the keystroke was aimed at. On every thrown case except
    /// `.emptyText` the text stays on the clipboard and no restore is scheduled.
    @discardableResult
    func insert(_ text: String, pressTimeTarget: DictationTarget) async throws -> DictationTarget
}

// MARK: Errors surfaced by the controller

enum DictationError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case accessibilityNotTrusted
    case microphoneDenied
    case missingElevenLabsKey
    case secureInputActive
    case captureFailed(String)
    /// ScribeError description, user-facing.
    case transcription(String)
    /// e.g. "Transcription timed out."
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Dictation is turned off."
        case .accessibilityNotTrusted:
            return DictationPillFault.needsAccessibility.text
        case .microphoneDenied:
            return "Kleoth needs microphone access. Allow it in System Settings → Privacy & Security → Microphone."
        case .missingElevenLabsKey:
            return DictationPillFault.missingElevenLabsKey.text
        case .secureInputActive:
            return DictationPillFault.secureInput.text
        case .captureFailed(let message), .transcription(let message), .timedOut(let message):
            return message
        }
    }
}
