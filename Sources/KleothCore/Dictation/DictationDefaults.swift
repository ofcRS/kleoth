import Foundation

/// Single source of truth for every dictation constant. Nothing else may
/// redefine these numbers.
public enum DictationDefaults {
    /// Verified live 2026-09-03: 200 with strict `json_schema` + `temperature`, Russian preserved,
    /// fillers removed. Deliberately NOT `google/*` — this account's OpenRouter Zero-Data-Retention
    /// guardrail 404s every Google endpoint (`zdr-violation-by-account`); see CLAUDE.md.
    public static let polishModel = "z-ai/glm-5.3-flash"
    /// Models whose polish request carries `reasoning: {effort: "low"}`
    /// (`OpenRouterReasoning.low`). The cap is model-specific, NOT a general
    /// speed-up — measured live 2026-09-03 under `require_parameters: true`:
    /// on `z-ai/glm-5.3-flash` it drops ~100–360 reasoning tokens to 0 and
    /// mean latency 8.4 s → 3.4 s with identical output; on
    /// `meta-llama/llama-3.3-70b-instruct` the same body **404s** ("No
    /// endpoints found that can handle the requested parameters"); on
    /// `deepseek/deepseek-v4-flash` it *enables* reasoning (0 → 216 tokens,
    /// 4.9 s → 9.5 s). Add a slug here only after measuring it.
    public static let reasoningCappedModels: Set<String> = ["z-ai/glm-5.3-flash"]
    public static let transcriptionModel = "scribe_v2"
    public static let hotkeyDescription = "fn + shift"
    /// A chord held shorter than this (with no double-tap) is discarded.
    public static let minHold: TimeInterval = 0.30
    /// A second chord-down within this window after a short tap = hands-free.
    public static let doubleTapWindow: TimeInterval = 0.40
    /// Clips shorter than this never reach Scribe (no spend, no log row).
    public static let minimumUtterance: TimeInterval = 0.5
    public static let scribeTimeout: TimeInterval = 25
    public static let polishTimeout: TimeInterval = 8
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
