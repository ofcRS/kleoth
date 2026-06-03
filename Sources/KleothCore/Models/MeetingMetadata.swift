import Foundation

/// Metadata describing a recorded meeting and its processing.
public struct MeetingMetadata: Codable, Sendable {
    public var title: String
    public var date: String
    /// ISO-8601 datetime (with time) the recording/processing started. `nil` for
    /// legacy meetings saved before this field existed. Used to sort history and
    /// disambiguate multiple meetings recorded on the same calendar day.
    public var startedAt: String?
    public var participants: [String]
    public var consentAcknowledged: Bool
    public var model: String?
    public var languageCode: String?
    public var cost: CostBreakdown?
    /// Which transcription engine / quality tier produced this transcript:
    /// ``TranscriptTier/local`` (free, on-device) or
    /// ``TranscriptTier/sotaScribe`` (ElevenLabs, paid, diarized). `nil` for
    /// legacy meetings — treat as local/unknown. Acronym-free, so it round-trips
    /// under MeetingStore's snake_case strategies as `transcript_tier`.
    public var transcriptTier: String?

    public init(
        title: String,
        date: String,
        startedAt: String? = nil,
        participants: [String] = [],
        consentAcknowledged: Bool = false,
        model: String? = nil,
        languageCode: String? = nil,
        cost: CostBreakdown? = nil,
        transcriptTier: String? = nil
    ) {
        self.title = title
        self.date = date
        self.startedAt = startedAt
        self.participants = participants
        self.consentAcknowledged = consentAcknowledged
        self.model = model
        self.languageCode = languageCode
        self.cost = cost
        self.transcriptTier = transcriptTier
    }

    /// Whether `title` is an auto-generated placeholder rather than a meaningful,
    /// user- or calendar-supplied title — so a model-produced title may replace
    /// it. A genuine title that merely *starts with* "Meeting"/"Recording" (e.g. a
    /// calendar event "Meeting with Acme", or "Recording studio sync") is NOT a
    /// placeholder and is kept.
    ///
    /// Recognized placeholders: empty/whitespace; `"Meeting <yyyy-MM-dd>"` and
    /// `"Recording <yyyy-MM-dd>"` (the app/CLI auto-titles); and `"Recording · …"`
    /// (the recovered audio-only title).
    public static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("Recording · ") { return true }
        for prefix in ["Meeting ", "Recording "] where trimmed.hasPrefix(prefix) {
            if startsWithISODate(trimmed.dropFirst(prefix.count)) { return true }
        }
        return false
    }

    /// True when `text` begins with a `yyyy-MM-dd` date (e.g. "2026-06-01").
    private static func startsWithISODate<S: StringProtocol>(_ text: S) -> Bool {
        let c = Array(text.prefix(10))
        guard c.count == 10 else { return false }
        func digit(_ i: Int) -> Bool { c[i].isNumber }
        return digit(0) && digit(1) && digit(2) && digit(3) && c[4] == "-"
            && digit(5) && digit(6) && c[7] == "-" && digit(8) && digit(9)
    }
}

/// Canonical `MeetingMetadata/transcriptTier` values and helpers.
public enum TranscriptTier {
    /// Free, on-device transcription (WhisperKit / Whisper on Apple Silicon).
    public static let local = "local-whisper"
    /// Paid, SOTA diarized transcription (ElevenLabs Scribe v2).
    public static let sotaScribe = "sota-scribe"

    /// Whether `tier` denotes a paid SOTA transcript (vs. a free local one).
    public static func isSOTA(_ tier: String?) -> Bool {
        tier?.hasPrefix("sota") ?? false
    }

    /// A short, human-facing label for a tier value (for badges). Worded by
    /// where the audio went — "On-device" (never left the Mac) vs "Cloud"
    /// (ElevenLabs Scribe) — rather than the old "Local"/"SOTA" jargon.
    public static func label(_ tier: String?) -> String {
        isSOTA(tier) ? "Cloud" : "On-device"
    }
}

/// USD cost breakdown for processing a single meeting.
public struct CostBreakdown: Codable, Sendable {
    public var transcriptionUSD: Double
    public var summaryUSD: Double
    public var audioDurationSecs: Double?

    public var totalUSD: Double {
        transcriptionUSD + summaryUSD
    }

    // Explicit, acronym-free coding keys. Under MeetingStore's snake_case key
    // strategies an all-caps suffix does NOT round-trip: `transcriptionUSD`
    // encodes (convertToSnakeCase) to `transcription_usd` but decodes
    // (convertFromSnakeCase) back to `transcriptionUsd`, which no longer matches
    // — so a saved `cost` could not be re-read. Mapping to acronym-free names
    // keeps encode/decode symmetric; on disk the keys are `transcription_cost` /
    // `summary_cost` / `audio_duration_secs`.
    // NOTE: any new stored property must be added to this enum too.
    enum CodingKeys: String, CodingKey {
        case transcriptionUSD = "transcriptionCost"
        case summaryUSD = "summaryCost"
        case audioDurationSecs
    }

    public init(
        transcriptionUSD: Double = 0,
        summaryUSD: Double = 0,
        audioDurationSecs: Double? = nil
    ) {
        self.transcriptionUSD = transcriptionUSD
        self.summaryUSD = summaryUSD
        self.audioDurationSecs = audioDurationSecs
    }
}
