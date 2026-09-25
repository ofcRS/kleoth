import Foundation

/// Single source of truth for every dictation constant. Nothing else may
/// redefine these numbers.
public enum DictationDefaults {
    /// Polish model. Benchmarked live 2026-09-03 through the real `DictationPolisher`
    /// (`dictate --text … --runs 4`, RU + EN samples, strict `json_schema`, `temperature 0.2`,
    /// `require_parameters: true`): `google/gemini-3.5-flash-lite` median **0.85–1.05 s**
    /// ($0.0006/dictation, RU preserved, self-corrections applied, spoken lists rendered);
    /// `google/gemini-3.8-flash` + `reasoning low` 1.45 s; `z-ai/glm-5.3-flash` + `reasoning low`
    /// 3.6–4.1 s; `deepseek-v4-flash` / `qwen3.7-flash` time out at 8 s (uncapped reasoning).
    /// Latency is what the user feels between releasing the key and the paste, so the fastest
    /// correct model wins. Needs Google reachable on the account (ZDR toggle off — see CLAUDE.md);
    /// when it is not, the polisher falls through to `fallbackPolishModel`.
    public static let polishModel = "google/gemini-3.5-flash-lite"
    /// Second model tried when the primary fails with an HTTP error (routing 404 under an
    /// account guardrail, 429, 5xx) and enough of `polishTimeout` is left. Chosen because it is
    /// reachable under every OpenRouter privacy setting seen on this account (ZDR on or off) and
    /// verified live (200, RU preserved). Set to nil to disable the second attempt.
    public static let fallbackPolishModel: String? = "z-ai/glm-5.3-flash"
    /// Minimum remaining budget worth spending on the fallback attempt.
    public static let minimumFallbackBudget: TimeInterval = 2
    /// Former polish defaults that a stored `dictation_model` may still name, mapped to the
    /// current one. `z-ai/glm-5.3-flash` was the default for a few hours on 2026-09-03 and got
    /// PERSISTED into the Keychain of every install whose Settings opened that day; the app then
    /// kept polishing on it — median 3.6–4.1 s with a tail past the (then 8 s) budget, 16 of 85
    /// polishes timing out on this Mac — while the shipped default did the same texts in 1–2 s.
    /// Applied by ``migratingPolishModel(_:)`` on every load and persisted the first time Settings
    /// opens (the `ModelCatalog.retiredModels` idiom). The slug stays the automatic
    /// `fallbackPolishModel`; it is only no longer offered as the *primary*.
    public static let retiredPolishModels: [String: String] = [
        "z-ai/glm-5.3-flash": polishModel,
    ]
    /// The replacement for a stored polish slug: `ModelCatalog.migrating` first (dead slugs), then
    /// ``retiredPolishModels`` (slow former polish defaults); otherwise the slug unchanged.
    public static func migratingPolishModel(_ slug: String) -> String {
        let base = ModelCatalog.migrating(slug)
        return retiredPolishModels[base] ?? base
    }
    /// Per-model `reasoning` caps sent with the polish request. Model-specific, NOT a general
    /// speed-up — measured live 2026-09-03 under `require_parameters: true`: on
    /// `z-ai/glm-5.3-flash` `low` drops ~100–360 reasoning tokens to 0 (mean 8.4 s → 3.4 s,
    /// identical output); on `google/gemini-3.8-flash` `low` turns cut-off/timeout fallbacks into
    /// 1.2–1.6 s successes; `minimal` measured fine on the other Gemini Flash models. On
    /// `meta-llama/llama-3.3-70b-instruct` the key **404s** ("No endpoints found that can handle
    /// the requested parameters" — the client's relaxed retry recovers, at the price of a round
    /// trip); on `deepseek/deepseek-v4-flash` it *enables* reasoning (0 → 216 tokens, 4.9 → 9.5 s).
    /// Add a slug here only after measuring it with `dictate --text … --reasoning <effort>`.
    public static let reasoningCaps: [String: OpenRouterReasoning.Effort] = [
        "z-ai/glm-5.3-flash": .low,
        "google/gemini-3.8-flash": .low,
        "google/gemini-3.7-flash": .minimal,
        "google/gemini-3.5-flash": .minimal,
        "google/gemini-3.5-flash-lite": .minimal,
    ]
    /// The slugs in `reasoningCaps`.
    public static var reasoningCappedModels: Set<String> { Set(reasoningCaps.keys) }
    /// Dictations shorter than this (whitespace-separated words) are pasted as
    /// Scribe returned them unless `Settings.dictationPolishAlways` is on — see
    /// `PolishGate`. ~10 s of speech; a casual one-liner is well under it, a
    /// structured prompt or a brainstorm well over. Messages into chat apps
    /// skip the pass regardless of length.
    public static let minimumWordsToPolish = 24
    public static let transcriptionModel = "scribe_v2"
    public static let hotkeyDescription = "fn + shift"
    /// A chord held shorter than this (with no double-tap) is discarded. Only
    /// has to outlast a reflex tap — the pill already acknowledges the press
    /// at key-down (`.armed`), so this is when the bars appear, not the pill.
    public static let minHold: TimeInterval = 0.20
    /// A second chord-down within this window after a short tap = hands-free.
    public static let doubleTapWindow: TimeInterval = 0.40
    /// Clips shorter than this never reach Scribe (no spend, no log row).
    public static let minimumUtterance: TimeInterval = 0.5
    /// The Scribe budget is per ATTEMPT and grows with the clip: Scribe holds
    /// the connection silent while it transcribes, and that takes longer the
    /// longer the audio. A flat 25 s lost long dictations even on a healthy
    /// day (three timeouts on 2026-09-22, on clips of roughly 40–80 s). See
    /// `scribeBudget(forAudioSeconds:)` and `DictationTranscription`.
    public static let scribeBaseBudget: TimeInterval = 25
    public static let scribeBudgetPerAudioSecond: Double = 0.5
    public static let scribeMaxBudget: TimeInterval = 120
    /// A transient first failure (timeout, network, 408/429/5xx) gets exactly
    /// one more try; anything else fails at once.
    public static let scribeAttempts = 2
    public static let scribeRetryDelay: TimeInterval = 1
    /// `<output>/dictations/audio/` — a dictation's audio lives here only while
    /// it waits to be transcribed (a failed or stopped run), never after.
    public static let keptAudioDirectoryName = "audio"
    /// Kept audio no row points at is moved to the Trash at launch once it is
    /// this old — never sooner, so a keep in flight is never raced.
    public static let orphanedAudioMaxAge: TimeInterval = 24 * 3600

    /// Wall-clock budget for one Scribe attempt on a clip `seconds` long:
    /// 25 s of fixed overhead plus half the clip, capped at 120 s
    /// (10 s → 30 s, 78 s → 64 s, 190 s and longer → 120 s).
    public static func scribeBudget(forAudioSeconds seconds: Double) -> TimeInterval {
        min(scribeMaxBudget, scribeBaseBudget + scribeBudgetPerAudioSecond * max(0, seconds))
    }

    /// Ceiling on the polish call — a safety net for a hung connection, NOT the expected wait.
    /// Was 8 s; that cut off a fifth of all polishes on an install stuck on the former default
    /// (see `retiredPolishModels`), and the user asked that a long dictation never lose its
    /// polish to a timer. Esc during `.polishing` pastes the raw transcript immediately, so the
    /// user, not this constant, decides how long is too long.
    public static let polishTimeout: TimeInterval = 30
    public static let pasteboardRestoreDelay: TimeInterval = 0.5
    /// Stored dictionary cap (API max). Only `Keyterms.maxTerms` (100) are SENT.
    public static let maxStoredDictionaryTerms = 1000
    /// ElevenLabs bills +20% on requests that carry keyterms.
    public static let keytermSurchargeMultiplier = 1.2
    public static let logDirectoryName = "dictations"
    /// Speech-only AAC; halves upload size vs the meeting path's 128 kbps. Used for BOTH the raw
    /// capture file and `prepareForUpload`'s output (`ChannelAudio.mixToMono(…, bitRate:)`) — the
    /// prep step re-encodes, so passing it there is what actually shrinks the upload.
    public static let captureBitRate = 64_000

    // MARK: - The text already in the field (design 2026-09-24-dictation-context §3.1–§3.7)

    /// Text read before the caret or selection, in UTF-16 units (as Accessibility counts): enough
    /// for the model to continue the sentence and reuse the field's spellings, and little enough
    /// to cost the polish nothing noticeable (with the 500 after it, ≤ ~2,000 characters per call).
    ///
    /// Used twice, in two units: as the read window (UTF-16 units, `DictationContextPolicy.readPlan`),
    /// and as a cap in Characters (`String.count`) on the text before the caret that an appended
    /// selection becomes in the prompt (`DictationFieldContext.promptContext`) — text already read
    /// (the window plus the selection), cut like a window but never read again.
    public static let contextBeforeCharacters = 1_500
    /// Text read after it: the model needs only where the sentence goes next.
    public static let contextAfterCharacters = 500
    /// The longest selection (characters) the model rewrites with the dictation. A merge writes
    /// the whole selection back, roughly +1 s per 300–400 words, so a longer one stays as it is and
    /// gets the dictation added after it.
    public static let maxMergeSelectionCharacters = 4_000
    /// The longest selection (characters) read at all. A longer one is replaced by the dictation,
    /// as before field context existed: its text would be read for nothing.
    public static let maxReadableSelectionCharacters = 20_000
    /// A terminal selection is a spelling reference (an error message, a function name), capped
    /// like the text before a caret. The cap applies after the read: a terminal selection without
    /// an `AXSelectedTextRange` (Ghostty's mouse selection) is copied whole first, bounded only by
    /// `contextElementTimeout` on that one message.
    public static let maxReferenceCharacters = 1_500
    /// The most characters of partial word a cut drops (R13). A window cut short at a read limit
    /// (or a cap) would otherwise start or end mid-word, so the cut goes back to the nearest
    /// whitespace — but text written without spaces (Chinese, Japanese, Thai) and long tokens have
    /// none nearby, and going to the first one could drop most of the window. Past this many
    /// characters the cut stays where the limit made it, at a Character, still marked "…".
    public static let maxDroppedPartialWordCharacters = 40
    /// When a field doesn't answer `AXStringForRange`, the windows are cut out of its whole
    /// `AXValue` — only while that value is at most this long, so a huge document isn't copied
    /// across processes for 2,000 characters of it.
    public static let maxValueCharactersWithoutRangeReads = 20_000
    /// The Accessibility messaging timeout (seconds) set on each element read — never on the
    /// system-wide element, which would change it for the whole process. A hung app then costs
    /// the reader a quarter of a second per message, not AX's default of several seconds.
    public static let contextElementTimeout: Float = 0.25
    /// The snapshot at release overlaps audio preparation and the Scribe upload (≥ 1 s), so up to
    /// this long it adds nothing; a read past it is abandoned and the dictation goes in as today.
    /// Abandoned, not stopped: the read runs out its messages on the reader's serial queue — up to
    /// about 8 × `contextElementTimeout` ≈ 2 s from its start, against an app that answers each
    /// message slowly but inside the timeout (a hung app fails the first message and stops early).
    /// A quick next dictation's wake and snapshot queue behind it, and that one gets no context either.
    public static let contextReadBudget: TimeInterval = 0.3
    /// The re-check just before ⌘V: two to four messages, and the paste waits for it.
    public static let contextRecheckBudget: TimeInterval = 0.15
    /// The echo guard's run, in letters and digits: about a sentence, well past a shared name or
    /// term (`DictationContextFit.echoesContext`).
    public static let contextEchoMinimumCharacters = 40
    /// Apps whose accessibility tree only builds once `AXManualAccessibility` is set at chord-down
    /// (Electron's switch for assistive tools). Bundle ids; empty by the user's decision to skip
    /// the spike (dictation-context design §10, which says when T3 Code would go on it).
    /// An app goes on the list only if its getter for the attribute answers, or reports it
    /// absent: the reader never sets a flag it couldn't read first. Before the first bundle id
    /// goes on either list, serialise the controller's `wake` and `endSession` calls into the
    /// reader, or give the reader a session token: each is a detached task today, so a double-tap
    /// can run one session's `endSession` after the next session's `wake` and clear its flag.
    public static let wakeWithManualAccessibility: Set<String> = []
    /// Apps woken with `AXEnhancedUserInterface`, VoiceOver's flag: while it is on, window
    /// managers animate and misplace windows. Stays empty unless the user says yes (§9 Q6).
    public static let wakeWithEnhancedUserInterface: Set<String> = []
}
