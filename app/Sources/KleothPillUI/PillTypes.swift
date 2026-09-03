import Foundation
import KleothCore

// The pill half of the dictation contract (design doc §3.14), moved out of
// `KleothApp/Dictation/DictationTypes.swift` into this library so that the
// `pillsandbox` tool can drive the real pill without the rest of the app.
// Change a signature here and you change every lane — don't.

/// What the floating pill shows. The controller owns transitions; the pill
/// only renders.
public enum DictationPillState: Equatable, Sendable {
    case hidden
    /// Visible but inactive: the compact resting capsule shown whenever the
    /// hotkey is armed (dictation enabled + Accessibility trusted). The pill
    /// collapses back to this after every session instead of disappearing.
    case idle
    /// Chord down, mic on, not yet confirmed as a hold: the resting capsule
    /// pulled fully out of its edge (the hover-peek look) so the press is
    /// acknowledged on the first frame. `.listening` grows out of it at
    /// `DictationDefaults.minHold`; a discarded tap sinks it back.
    case armed
    case listening(handsFree: Bool)
    case transcribing
    case polishing
    case done
    /// Text WAS pasted/copied, but something degraded (raw fallback, clipboard-only).
    case warning(String)
    /// Nothing was pasted; sticky until dismissed/replaced.
    case failed(DictationPillFault)

    /// `.done` → 1.0 s, `.warning` → 3.0 s, everything else nil (persists).
    public var autoHideAfter: Duration? {
        switch self {
        case .done: return .seconds(1)
        case .warning: return .seconds(3)
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .failed: return nil
        }
    }

    /// Only warnings and failures carry words; every other phase is motion.
    public var showsText: Bool {
        switch self {
        case .warning, .failed: return true
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done: return false
        }
    }
}

/// Why a dictation produced nothing — each carries user-facing copy and, when
/// the user can fix it themselves, an action button.
public enum DictationPillFault: Equatable, Sendable {
    case missingElevenLabsKey
    case needsAccessibility
    case secureInput
    case message(String)

    /// Belt and braces for `.message`: no state may carry an unbounded line
    /// into the pill (the panel width follows this text). The controller
    /// already shortens known error shapes at the source.
    public static let maxMessageLength = 140

    public var text: String {
        switch self {
        case .missingElevenLabsKey: return "Add an ElevenLabs key to dictate"
        case .needsAccessibility: return "Kleoth needs Accessibility access"
        case .secureInput: return "The focused field blocks dictation"
        case .message(let message):
            let single = message.replacingOccurrences(of: "\n", with: " ")
            guard single.count > Self.maxMessageLength else { return single }
            return String(single.prefix(Self.maxMessageLength)) + "…"
        }
    }

    public var action: DictationPillAction? {
        switch self {
        case .missingElevenLabsKey: return .openSettings
        case .needsAccessibility: return .openAccessibilitySettings
        case .secureInput, .message: return nil
        }
    }
}

public enum DictationPillAction: Equatable, Sendable {
    case openSettings
    case openAccessibilitySettings

    public var title: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .openAccessibilitySettings: return "Open Accessibility"
        }
    }
}

/// The floating pill as the controller sees it (implemented by
/// `DictationPillController`, T6).
@MainActor
public protocol DictationPillPresenting: AnyObject {
    var onAction: ((DictationPillAction) -> Void)? { get set }
    /// ✕ or click on a `.failed` pill.
    var onDismiss: (() -> Void)? { get set }
    /// Replaces the phase; cancels any pending auto-hide. `.hidden` == `dismiss()`.
    func show(_ state: DictationPillState)
    /// 0…1, already normalized + smoothed by the caller.
    func setLevel(_ level: Double)
    /// Ends the active phase. With the resting pill on (`setResting(true)`)
    /// this collapses to `.idle`; otherwise the panel fades out.
    func dismiss()
    /// Whether the compact resting capsule stays on screen between sessions.
    /// The controller mirrors `isMonitoring` into this: armed hotkey → pill
    /// visible; disabled / untrusted / quitting → gone.
    func setResting(_ visible: Bool)
    func resetPosition()
}

