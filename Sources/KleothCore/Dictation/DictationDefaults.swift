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
    /// The key tapped WHILE the chord is held to keep that dictation going
    /// hands-free (2026-09-24). A modifier on purpose: the hotkey monitor is
    /// listen-only, so a character key would also be typed into the target app.
    public static let handsFreeLatchDescription = "⌘"
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
}
