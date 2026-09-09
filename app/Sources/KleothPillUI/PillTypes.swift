import Foundation
import KleothCore

// The pill half of the contract, moved out of
// `KleothApp/Dictation/DictationTypes.swift` into this library so that the
// `pillsandbox` tool can drive the real pill without the rest of the app.
// Change a signature here and you change every lane — don't.
//
// It started as the dictation contract (dictation design doc §3.14); since the
// screen-recording pass it also carries the recording phases and the BACKDROP
// (screen-recording design §3.3, §6.1). The `DictationPillPresenting` protocol
// is deliberately UNCHANGED by that pass — `setResting(_:)` stays, and the
// backdrop generalization is an addition on the concrete controller only.

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
    /// A screen recording is in flight — this is the pill's BACKDROP while it
    /// runs (never tucked). `since` is FIXED for the session so that every
    /// re-show (after each dictation `dismiss()`) compares equal and fires no
    /// spring, `MotionBeat`, re-layout or announcement. The digits come from a
    /// `TimelineView(.periodic(from: since, by: 1))` in the view, not from a
    /// per-second `show()`.
    case recording(since: Date)
    /// Finalizing the movie file (≤ 5 s): the `.recording` capsule with a
    /// travelling wave instead of the dot.
    case saving
    /// "2:14 · 48 MB" — a green check plus the text, auto-hiding after 4 s;
    /// a click reveals the file in Finder.
    case saved(String)

    /// `.done` → 1.0 s, `.warning` → 3.0 s, `.saved` → 4.0 s, everything else
    /// nil (persists). `.recording` and `.saving` last as long as the session.
    public var autoHideAfter: Duration? {
        switch self {
        case .done: return .seconds(1)
        case .warning: return .seconds(3)
        case .saved: return .seconds(4)
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .failed,
             .recording, .saving:
            return nil
        }
    }

    /// Only warnings, failures and the saved confirmation carry words; every
    /// other phase is motion.
    public var showsText: Bool {
        switch self {
        case .warning, .failed, .saved: return true
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done,
             .recording, .saving:
            return false
        }
    }
}

/// What the pill collapses to when no phase is live — the generalization of
/// the old `restingVisible: Bool`. A running screen recording outranks the
/// dictation resting capsule (`PillCoordinator.recompute()`).
public enum DictationPillBackdrop: Equatable, Sendable {
    case hidden
    case idle
    case recording(since: Date)

    /// The phase this backdrop shows as, or nil when the pill should be gone.
    public var state: DictationPillState? {
        switch self {
        case .hidden: return nil
        case .idle: return .idle
        case .recording(let since): return .recording(since: since)
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
    /// Screen Recording was never granted (or was declined).
    case screenRecordingNeeded
    /// Granted, but this process was launched before the grant — TCC only
    /// answers for the process as it started, so a relaunch is the fix.
    case screenRecordingStale

    /// Belt and braces for `.message`: no state may carry an unbounded line
    /// into the pill (the panel width follows this text). The controller
    /// already shortens known error shapes at the source.
    public static let maxMessageLength = 140

    public var text: String {
        switch self {
        case .missingElevenLabsKey: return "Add an ElevenLabs key to dictate"
        case .needsAccessibility: return "Kleoth needs Accessibility access"
        case .secureInput: return "The focused field blocks dictation"
        case .screenRecordingNeeded: return "Allow Screen Recording, then quit and reopen Kleoth"
        case .screenRecordingStale: return "Quit and reopen Kleoth to finish enabling Screen Recording"
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
        case .screenRecordingNeeded, .screenRecordingStale: return .openScreenRecordingSettings
        case .secureInput, .message: return nil
        }
    }
}

public enum DictationPillAction: Equatable, Sendable {
    case openSettings
    case openAccessibilitySettings
    /// Tap on the peeking resting pill / its record glyph.
    case startScreenRecording
    /// Tap on the `.recording` capsule.
    case stopScreenRecording
    /// Tap on the `.saved` confirmation.
    case revealLastRecording
    case openScreenRecordingSettings
    // MARK: Pill menu + peek dock (interaction demo, 2026-09-08)
    /// Mic glyph on the peeked resting pill, or the menu's first row: a
    /// hands-free dictation without touching the keyboard.
    case startHandsFreeDictation
    /// Click on the hands-free listening capsule.
    case stopHandsFreeDictation
    /// Microphone submenu. `nil` = follow the system default.
    case selectMicrophone(String?)
    case pasteLastDictation
    case openDictationHistory
    case hideForAnHour

    /// The label of the pill's action BUTTON. Empty for the tap-only actions:
    /// they are the capsule itself, not a button with words.
    public var title: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .openAccessibilitySettings: return "Open Accessibility"
        case .startScreenRecording, .stopScreenRecording, .revealLastRecording: return ""
        case .openScreenRecordingSettings: return "Open Screen Recording"
        case .startHandsFreeDictation, .stopHandsFreeDictation, .selectMicrophone,
             .pasteLastDictation, .openDictationHistory, .hideForAnHour:
            return ""
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


// MARK: - Pill menu (interaction demo, 2026-09-08)

/// One input device for the pill menu's Microphone submenu.
public struct PillMicrophone: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the host knows that the pill's menu shows. The pill asks for it
/// every time the menu opens (`DictationPillController.menuContent`), so it
/// is always current and the pill library keeps no audio or history state.
public struct PillMenuContent: Sendable {
    public var microphones: [PillMicrophone]
    /// The user's explicit pick, or nil for "Automatic".
    public var selectedMicrophoneId: String?
    /// The device the system (or the pick) resolves to right now.
    public var inUseMicrophoneName: String?
    /// The last dictation's first words, for the "Paste last dictation" row.
    public var lastDictationPreview: String?
    /// The hotkey, for the dictation row's hint.
    public var hotkeyDescription: String

    public init(
        microphones: [PillMicrophone] = [],
        selectedMicrophoneId: String? = nil,
        inUseMicrophoneName: String? = nil,
        lastDictationPreview: String? = nil,
        hotkeyDescription: String = ""
    ) {
        self.microphones = microphones
        self.selectedMicrophoneId = selectedMicrophoneId
        self.inUseMicrophoneName = inUseMicrophoneName
        self.lastDictationPreview = lastDictationPreview
        self.hotkeyDescription = hotkeyDescription
    }
}
