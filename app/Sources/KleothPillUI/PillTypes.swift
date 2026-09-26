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
    /// A meeting records — the pill's BACKDROP while it runs (never tucked,
    /// flat on every edge), between the screen recording (which outranks it)
    /// and the resting pill. `since` is FIXED for the meeting so every re-show
    /// after a dictation compares equal and fires no spring (the
    /// `.recording(since:)` rule). Meetings-in-the-pill design §3.1.3.
    case meeting(since: Date)
    /// "Meeting saved · 42:10" (· "transcribing" when auto-transcribe is on):
    /// a green check plus the text, 4 s; a click opens History on that meeting.
    case meetingSaved(String)
    /// A question with buttons — "Zoom call — record it?" with Record / Never
    /// for Zoom / ✕, or the stop suggestion. Sticky (the ✕); its owner
    /// withdraws it. A tap on the capsule does nothing: a stray click must
    /// never decline. Meetings-in-the-pill design §3.2.3, §4.3.
    case prompt(PillPrompt)

    /// `.done` → 1.0 s, `.warning` → 3.0 s, `.saved`/`.meetingSaved` → 4.0 s,
    /// everything else nil (persists). `.recording`, `.saving` and `.meeting`
    /// last as long as the session; `.prompt` until its owner withdraws it
    /// (or the user answers).
    public var autoHideAfter: Duration? {
        switch self {
        case .done: return .seconds(1)
        case .warning: return .seconds(3)
        case .saved, .meetingSaved: return .seconds(4)
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .failed,
             .recording, .saving, .meeting, .prompt:
            return nil
        }
    }

    /// Only warnings, failures, the two saved confirmations and a prompt carry
    /// words; every other phase is motion.
    public var showsText: Bool {
        switch self {
        case .warning, .failed, .saved, .meetingSaved, .prompt: return true
        case .hidden, .idle, .armed, .listening, .transcribing, .polishing, .done,
             .recording, .saving, .meeting:
            return false
        }
    }
}

/// A question the pill asks with buttons (meetings-in-the-pill design §3.2.3,
/// §3.2.5, §4.3): the call offer ("Zoom call — record it?" · Record · Never for
/// Zoom · ✕) and the stop suggestion ("Zoom released the mic — stop
/// recording?" · Stop · ✕). The ✕ is always there; its owner withdraws it.
public struct PillPrompt: Equatable, Sendable {
    public enum Tint: Sendable, Equatable { case accent, record }
    /// The owner's handle on this prompt (`DictationPillState.promptId`).
    public var id: String
    /// Capped at `DictationPillFault.maxMessageLength` by the initializer.
    public var text: String
    /// Offers `person.2.wave.2.fill`, the stop suggestion `stop.circle.fill`.
    public var symbolName: String
    /// The glyph's and the primary button's colour: `.record` (the recording
    /// red) for an offer, `.accent` for the stop suggestion.
    public var tint: Tint
    public var primary: DictationPillAction
    /// The quieter second button ("Never for Zoom"); nil = none.
    public var secondary: DictationPillAction?

    public init(
        id: String, text: String, symbolName: String, tint: Tint,
        primary: DictationPillAction, secondary: DictationPillAction? = nil
    ) {
        self.id = id
        // The `DictationPillFault.message` rule: one line, bounded — the panel
        // width follows this text.
        let single = text.replacingOccurrences(of: "\n", with: " ")
        self.text = single.count > DictationPillFault.maxMessageLength
            ? String(single.prefix(DictationPillFault.maxMessageLength)) + "…"
            : single
        self.symbolName = symbolName
        self.tint = tint
        self.primary = primary
        self.secondary = secondary
    }
}

extension DictationPillState {
    /// The prompt's id when a `.prompt` is showing.
    public var promptId: String? {
        if case .prompt(let prompt) = self { return prompt.id }
        return nil
    }
}

/// What the pill collapses to when no phase is live — the generalization of
/// the old `restingVisible: Bool`. A running screen recording outranks the
/// dictation resting capsule (`PillCoordinator.recompute()`).
public enum DictationPillBackdrop: Equatable, Sendable {
    case hidden
    case idle
    case recording(since: Date)
    /// A meeting records (any origin). Outranked by `.recording`, outranks `.idle`.
    case meeting(since: Date)

    /// The phase this backdrop shows as, or nil when the pill should be gone.
    public var state: DictationPillState? {
        switch self {
        case .hidden: return nil
        case .idle: return .idle
        case .recording(let since): return .recording(since: since)
        case .meeting(let since): return .meeting(since: since)
        }
    }
}

/// Why a dictation produced nothing — each carries user-facing copy and, when
/// the user can fix it themselves, an action button.
public enum DictationPillFault: Equatable, Sendable {
    case missingElevenLabsKey
    case needsAccessibility
    /// Secure input is on somewhere in the session. `holder` is the app
    /// holding it (display name), nil when it can't be named.
    case secureInput(holder: String?)
    case message(String)
    /// Screen Recording was never granted (or was declined).
    case screenRecordingNeeded
    /// Granted, but this process was launched before the grant — TCC only
    /// answers for the process as it started, so a relaunch is the fix.
    case screenRecordingStale
    /// The transcription failed but the audio was KEPT (a pending row in
    /// History): "Timed out — saved to History", with a Retry button that
    /// sends the kept clip again. Nothing was lost, so it is drawn in the
    /// pending tint, not the failure red (dictation-retry design §3.3).
    /// `dictationId` is the pending row's id; it rides on the Retry action,
    /// so the retry never depends on host state a dismissal could clear.
    case transcriptionKept(String, dictationId: String)

    /// Belt and braces for `.message`: no state may carry an unbounded line
    /// into the pill (the panel width follows this text). The controller
    /// already shortens known error shapes at the source.
    public static let maxMessageLength = 140

    public var text: String {
        switch self {
        case .missingElevenLabsKey: return "Add an ElevenLabs key to dictate"
        case .needsAccessibility: return "Kleoth needs Accessibility access"
        case .secureInput(let holder?): return "\(holder) has secure input on — dictation blocked"
        case .secureInput(nil): return "Secure input is on — dictation blocked"
        case .screenRecordingNeeded: return "Allow Screen Recording, then quit and reopen Kleoth"
        case .screenRecordingStale: return "Quit and reopen Kleoth to finish enabling Screen Recording"
        case .message(let message), .transcriptionKept(let message, _):
            let single = message.replacingOccurrences(of: "\n", with: " ")
            guard single.count > Self.maxMessageLength else { return single }
            return String(single.prefix(Self.maxMessageLength)) + "…"
        }
    }

    /// Nothing is lost and the pill itself can put it right (Retry).
    public var isRecoverable: Bool {
        if case .transcriptionKept = self { return true }
        return false
    }

    /// The leading glyph: the octagon for a dead end, a circular arrow for a
    /// kept dictation waiting to be retried.
    public var symbolName: String {
        isRecoverable ? "exclamationmark.arrow.circlepath" : "xmark.octagon.fill"
    }

    public var action: DictationPillAction? {
        switch self {
        case .missingElevenLabsKey: return .openSettings
        case .needsAccessibility: return .openAccessibilitySettings
        case .screenRecordingNeeded, .screenRecordingStale: return .openScreenRecordingSettings
        case .transcriptionKept(_, let id): return .retryTranscription(dictationId: id)
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
    /// Click on the push-to-talk listening capsule (fn+shift still held): the
    /// same dictation keeps going hands-free.
    case switchToHandsFree
    /// Microphone submenu. `nil` = follow the system default.
    case selectMicrophone(String?)
    case pasteLastDictation
    case openDictationHistory
    case hideForAnHour
    /// The Retry button on a `.transcriptionKept` pill: transcribe the kept
    /// clip of the pending row `dictationId` again and paste it into the
    /// frontmost app.
    case retryTranscription(dictationId: String)
    /// Everything the meeting side owns, in ONE case, so the dictation and
    /// screen-recording controllers each carry a single `break` line and
    /// phase 2 extends `MeetingPillAction` without touching them.
    case meeting(MeetingPillAction)

    /// The label of the pill's action BUTTON. Empty for the tap-only actions:
    /// they are the capsule itself, not a button with words.
    public var title: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .openAccessibilitySettings: return "Open Accessibility"
        case .startScreenRecording, .stopScreenRecording, .revealLastRecording: return ""
        case .openScreenRecordingSettings: return "Open Screen Recording"
        case .retryTranscription: return "Retry"
        case .startHandsFreeDictation, .stopHandsFreeDictation, .switchToHandsFree,
             .selectMicrophone, .pasteLastDictation, .openDictationHistory, .hideForAnHour:
            return ""
        case .meeting(let action): return action.title
        }
    }
}

/// The meeting side's pill actions (meetings-in-the-pill design §4.3).
public enum MeetingPillAction: Equatable, Sendable {
    /// The dock's Meeting field, the menu's "Record meeting" row.
    case start
    /// The meeting bar's Stop, the menu's "Stop meeting recording" row.
    case stop
    /// A click on `.meetingSaved`: History on that meeting.
    case openLast
    // MARK: Phase 2 — call detection (design §3.2.3–§3.2.5)
    /// Record on the offer `id`: start the meeting like the Meeting field.
    case acceptOffer(id: String)
    /// "Never for Zoom": store `key` (and `name`, for Settings) in the
    /// never-offer list and withdraw the offer (§3.2.4).
    case neverOffer(key: String, name: String)
    /// Stop on the stop suggestion `id`: stop the meeting like the bar's Stop.
    case acceptStop(id: String)

    /// The label of a BUTTON carrying this action; empty for the tap-only
    /// actions (they are the capsule or a dock field, not a button with words).
    public var title: String {
        switch self {
        case .start, .stop, .openLast: return ""
        case .acceptOffer: return "Record"
        // §3.2.4: an unnamed call in a browser is "Never for calls in Chrome"
        // (the name is the browser's) — the same rule as
        // `MeetingSource.neverLabel`; everything else "Never for <name>".
        case .neverOffer(let key, let name):
            return key.hasPrefix("webcall:") ? "Never for calls in \(name)" : "Never for \(name)"
        case .acceptStop: return "Stop"
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
    /// What the pill's menu shows — microphones, the last dictation, the
    /// hotkey — asked on every open, so the pill keeps no audio or history
    /// state of its own. nil → an empty `PillMenuContent`.
    var menuContent: (() -> PillMenuContent)? { get set }
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
    /// The running meeting's fixed start, for the menu's meeting row; nil = no meeting recording.
    public var meetingSince: Date?

    public init(
        microphones: [PillMicrophone] = [],
        selectedMicrophoneId: String? = nil,
        inUseMicrophoneName: String? = nil,
        lastDictationPreview: String? = nil,
        hotkeyDescription: String = "",
        meetingSince: Date? = nil
    ) {
        self.microphones = microphones
        self.selectedMicrophoneId = selectedMicrophoneId
        self.inUseMicrophoneName = inUseMicrophoneName
        self.lastDictationPreview = lastDictationPreview
        self.hotkeyDescription = hotkeyDescription
        self.meetingSince = meetingSince
    }
}
