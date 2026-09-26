import Foundation

/// How the dictated text reached the user's app.
public enum DictationInsertMethod: String, Codable, Sendable {
    /// A synthetic ⌘V was posted into the frontmost app.
    case paste
    /// The text was left on the clipboard (Accessibility / secure-input refusal).
    case clipboard
    /// Nothing went into an app: a pending row (the audio is kept, the text is
    /// not there yet), or one transcribed later from History, where the text is
    /// copied on request. `"none"` on disk; an older build reads it as `paste`.
    case notInserted = "none"
}

/// One dictation, as stored in `~/Kleoth/dictations/<yyyy-MM-dd>.json`.
///
/// ⚠️ Every property name is ACRONYM-FREE on purpose: the store round-trips
/// through `.convertToSnakeCase` / `.convertFromSnakeCase`, and an all-caps
/// acronym suffix does NOT round-trip (`appBundleID` → `app_bundle_id` →
/// decodes to `appBundleId` ✗). Keep new keys acronym-free too.
///
/// A dictation that pasted keeps no audio — only this text record. A
/// dictation whose transcription failed (or was stopped) is a PENDING row:
/// empty text, and `audioFileName` naming its clip in `dictations/audio/`
/// until a retry fills the text in and deletes the clip (dictation-retry
/// design §3.2). Costs are stored (like `meta.json`) but never displayed:
/// Settings → Usage stays the only money surface in the app.
public struct DictationLogEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    /// ISO-8601 `.withInternetDateTime`, e.g. `2026-09-03T15:14:09Z`.
    public var timestamp: String
    public var appBundleId: String?
    public var appName: String?
    /// The transcription engine's language code — Scribe's `language_code`
    /// (ISO-639-3, e.g. `"rus"`), or WhisperKit's ISO-639-1 (`"ru"`) for a row
    /// transcribed on device from History — never the polisher's BCP-47
    /// guess, so there is exactly one language source of truth on disk.
    public var language: String?
    public var rawText: String
    /// Equal to `rawText` when `usedRawFallback` is true.
    public var polishedText: String
    public var usedRawFallback: Bool
    public var fallbackReason: String?
    public var transcriptionModel: String?
    public var polishModel: String?
    /// The ``AIProvider`` raw value that ran the polish; nil = OpenRouter or no polish.
    public var polishProvider: String?
    public var durationSeconds: Double?
    public var insertMethod: DictationInsertMethod
    public var transcriptionCost: Double?
    public var polishCost: Double?
    /// Wall-clock seconds the polish call took (nil when no model was called).
    /// Diagnostic: a run of slow rows points at the model, not the text.
    public var polishSeconds: Double?
    /// The kept clip in `<dictations>/audio/` — set exactly while the row is
    /// pending (``isPending``), cleared when a retry transcribes it.
    public var audioFileName: String?
    /// Why the row is pending, as a sentence for History ("Scribe didn't
    /// answer within 46 s. Tried twice."). nil once transcribed.
    public var transcriptionError: String?
    /// Wall-clock seconds of the transcription attempt that produced the text.
    /// Diagnostic, like `polishSeconds`: it calibrates the Scribe budget.
    public var transcriptionSeconds: Double?
    /// How the text already in the focused field shaped this dictation — a
    /// ``DictationInsertionPlan/Outcome`` raw value (`"cursor"`, `"merged"`,
    /// …); nil when it ran without field context (the setting off, nothing
    /// readable, a Retry or History run). A `String`, not the enum, so a value
    /// a newer build writes still decodes (the `insert_method` lesson);
    /// History shows no badge for a value it doesn't know.
    public var fieldContext: String?
    /// The selection a merge replaced, as it was — recovery once the app's own
    /// undo history is gone. Set on `merged` rows only, nil otherwise; the text
    /// around the caret is never stored.
    public var replacedText: String?
    /// Wall-clock seconds the focused field's read at release took (the read
    /// budget when it timed out); nil when no read was attempted. Diagnostic,
    /// like `polishSeconds`: it calibrates the read budget against real apps.
    public var contextSeconds: Double?

    public init(
        id: String = UUID().uuidString,
        timestamp: String,
        appBundleId: String? = nil,
        appName: String? = nil,
        language: String? = nil,
        rawText: String,
        polishedText: String,
        usedRawFallback: Bool = false,
        fallbackReason: String? = nil,
        transcriptionModel: String? = nil,
        polishModel: String? = nil,
        polishProvider: String? = nil,
        durationSeconds: Double? = nil,
        insertMethod: DictationInsertMethod = .paste,
        transcriptionCost: Double? = nil,
        polishCost: Double? = nil,
        polishSeconds: Double? = nil,
        audioFileName: String? = nil,
        transcriptionError: String? = nil,
        transcriptionSeconds: Double? = nil,
        fieldContext: String? = nil,
        replacedText: String? = nil,
        contextSeconds: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appBundleId = appBundleId
        self.appName = appName
        self.language = language
        self.rawText = rawText
        self.polishedText = polishedText
        self.usedRawFallback = usedRawFallback
        self.fallbackReason = fallbackReason
        self.transcriptionModel = transcriptionModel
        self.polishModel = polishModel
        self.polishProvider = polishProvider
        self.durationSeconds = durationSeconds
        self.insertMethod = insertMethod
        self.transcriptionCost = transcriptionCost
        self.polishCost = polishCost
        self.polishSeconds = polishSeconds
        self.audioFileName = audioFileName
        self.transcriptionError = transcriptionError
        self.transcriptionSeconds = transcriptionSeconds
        self.fieldContext = fieldContext
        self.replacedText = replacedText
        self.contextSeconds = contextSeconds
    }

    /// A dictation waiting to be transcribed: its audio is kept, its text is
    /// not there yet.
    public var isPending: Bool { audioFileName != nil }

    /// The row a failed or stopped dictation leaves behind: no text, nothing
    /// inserted, the kept clip and the reason.
    public static func pending(
        id: String = UUID().uuidString,
        timestamp: String,
        appBundleId: String?,
        appName: String?,
        durationSeconds: Double?,
        audioFileName: String,
        transcriptionError: String
    ) -> DictationLogEntry {
        DictationLogEntry(
            id: id,
            timestamp: timestamp,
            appBundleId: appBundleId,
            appName: appName,
            rawText: "",
            polishedText: "",
            durationSeconds: durationSeconds,
            insertMethod: .notInserted,
            audioFileName: audioFileName,
            transcriptionError: transcriptionError
        )
    }

    // MARK: - Coding

    /// Raw values stay camelCase: the store's encoder/decoder apply the
    /// snake_case conversion strategy (the same one `MeetingStore` uses).
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, appBundleId, appName, language
        case rawText, polishedText, usedRawFallback, fallbackReason
        case transcriptionModel, polishModel, polishProvider, durationSeconds
        case insertMethod, transcriptionCost, polishCost, polishSeconds
        case audioFileName, transcriptionError, transcriptionSeconds
        case fieldContext, replacedText, contextSeconds
    }

    /// Lenient decode: only `id` / `timestamp` / `raw_text` / `polished_text`
    /// are required; every other key may be absent.
    ///
    /// `insert_method` is deliberately decoded as a plain `String` and mapped
    /// through `DictationInsertMethod(rawValue:) ?? .paste`: a `Codable` enum
    /// throws on an unknown string, which would make not just this entry but
    /// the entire day file (a bare JSON array) undecodable the first time an
    /// older build reads a value written by a newer one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        rawText = try container.decode(String.self, forKey: .rawText)
        polishedText = try container.decode(String.self, forKey: .polishedText)
        appBundleId = try container.decodeIfPresent(String.self, forKey: .appBundleId)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        usedRawFallback = try container.decodeIfPresent(Bool.self, forKey: .usedRawFallback) ?? false
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
        polishModel = try container.decodeIfPresent(String.self, forKey: .polishModel)
        polishProvider = try container.decodeIfPresent(String.self, forKey: .polishProvider)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        let method = try container.decodeIfPresent(String.self, forKey: .insertMethod)
        insertMethod = method.flatMap(DictationInsertMethod.init(rawValue:)) ?? .paste
        transcriptionCost = try container.decodeIfPresent(Double.self, forKey: .transcriptionCost)
        polishCost = try container.decodeIfPresent(Double.self, forKey: .polishCost)
        polishSeconds = try container.decodeIfPresent(Double.self, forKey: .polishSeconds)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        transcriptionError = try container.decodeIfPresent(String.self, forKey: .transcriptionError)
        transcriptionSeconds = try container.decodeIfPresent(Double.self, forKey: .transcriptionSeconds)
        fieldContext = try container.decodeIfPresent(String.self, forKey: .fieldContext)
        replacedText = try container.decodeIfPresent(String.self, forKey: .replacedText)
        contextSeconds = try container.decodeIfPresent(Double.self, forKey: .contextSeconds)
    }

    /// Explicit (rather than synthesized) so every key is always present —
    /// nil optionals are written as `null` instead of vanishing. A stable key
    /// set makes the day file diff-able and matches the documented format
    /// (design §6.3).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(appBundleId, forKey: .appBundleId)
        try container.encode(appName, forKey: .appName)
        try container.encode(language, forKey: .language)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(polishedText, forKey: .polishedText)
        try container.encode(usedRawFallback, forKey: .usedRawFallback)
        try container.encode(fallbackReason, forKey: .fallbackReason)
        try container.encode(transcriptionModel, forKey: .transcriptionModel)
        try container.encode(polishModel, forKey: .polishModel)
        try container.encode(polishProvider, forKey: .polishProvider)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(insertMethod, forKey: .insertMethod)
        try container.encode(transcriptionCost, forKey: .transcriptionCost)
        try container.encode(polishCost, forKey: .polishCost)
        try container.encode(polishSeconds, forKey: .polishSeconds)
        try container.encode(audioFileName, forKey: .audioFileName)
        try container.encode(transcriptionError, forKey: .transcriptionError)
        try container.encode(transcriptionSeconds, forKey: .transcriptionSeconds)
        try container.encode(fieldContext, forKey: .fieldContext)
        try container.encode(replacedText, forKey: .replacedText)
        try container.encode(contextSeconds, forKey: .contextSeconds)
    }

    // MARK: - Time

    /// The parsed `timestamp`, or nil when it isn't ISO-8601. Tolerates
    /// fractional seconds so a hand-edited or future-written file still shows a
    /// time in the UI.
    public var date: Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: timestamp) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp)
    }

    /// The canonical way to stamp a new entry.
    public static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
