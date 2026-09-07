import Foundation

/// A mic + system level pair, 0…1 linear RMS of the most recent audio buffer
/// on each lane. Raw — the pill maps it to a meter with
/// `PillGeometry.normalizedLevel` / `smoothLevel`, the way dictation does.
public struct AudioLevels: Sendable, Equatable {
    public var mic: Double
    public var system: Double

    public init(mic: Double, system: Double) {
        self.mic = mic
        self.system = system
    }

    public static let zero = AudioLevels(mic: 0, system: 0)
}

/// One transcribed word of a screen recording, with its position in the
/// movie's timeline (seconds from the start of the file).
public struct RecordingWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The sidecar written next to a recording's `.mp4` (same stem, `.json`).
///
/// A recording without a sidecar is *untranscribed*; one whose sidecar carries
/// `transcriptError` and no words *failed* and can be retried. Word edits made
/// in the viewer are written straight back into `words` — the movie file is
/// never touched, so the file the user shares stays as recorded.
///
/// Stored snake_case through `ScreenRecordingStore` (acronym-free keys —
/// see the CLAUDE.md round-trip rule).
public struct ScreenRecordingRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// User-visible name; `nil` → the list derives one from the file stem.
    public var title: String?
    public var durationSecs: Double?
    /// ISO 639 code as the engine reported it (`ru`, `rus`, `en`, …).
    public var languageCode: String?
    /// `TranscriptTier.local` / `.sotaScribe`, `nil` until transcribed.
    public var transcriptTier: String?
    public var transcriptModel: String?
    public var transcribedAt: Date?
    /// Set (with `words` empty) when the last transcription attempt failed.
    public var transcriptError: String?
    public var words: [RecordingWord]

    public init(
        schemaVersion: Int = ScreenRecordingRecord.currentSchemaVersion,
        title: String? = nil,
        durationSecs: Double? = nil,
        languageCode: String? = nil,
        transcriptTier: String? = nil,
        transcriptModel: String? = nil,
        transcribedAt: Date? = nil,
        transcriptError: String? = nil,
        words: [RecordingWord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.durationSecs = durationSecs
        self.languageCode = languageCode
        self.transcriptTier = transcriptTier
        self.transcriptModel = transcriptModel
        self.transcribedAt = transcribedAt
        self.transcriptError = transcriptError
        self.words = words
    }

    /// True once a transcription produced at least one word.
    public var hasTranscript: Bool { !words.isEmpty }

    /// The transcript as plain text, words joined by single spaces.
    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Index of the word being spoken at `time`: the last word whose `start`
    /// is ≤ `time`, or `nil` before the first word. Binary search — the viewer
    /// calls this at playback-observer rate.
    public func wordIndex(at time: Double) -> Int? {
        guard !words.isEmpty, time >= words[0].start else { return nil }
        var low = 0
        var high = words.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if words[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A copy with word `index` replaced by `text` (trimmed). An empty
    /// replacement removes the word; an out-of-range index is a no-op.
    public func replacingWord(at index: Int, with text: String) -> ScreenRecordingRecord {
        guard words.indices.contains(index) else { return self }
        var copy = self
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            copy.words.remove(at: index)
        } else {
            copy.words[index].text = trimmed
        }
        return copy
    }

    /// Words from an engine response. Keeps entries of type `word` (or untyped)
    /// that carry both timestamps; spacing and audio-event entries are dropped.
    /// Multi-channel responses are flattened and sorted by start.
    public static func words(from response: ScribeResponse) -> [RecordingWord] {
        var source: [ScribeWord] = response.words ?? []
        if source.isEmpty, let transcripts = response.transcripts {
            source = transcripts.flatMap { $0.words ?? [] }
        }
        let words: [RecordingWord] = source.compactMap { word in
            if let type = word.type, type != "word" { return nil }
            guard let start = word.start, let end = word.end else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecordingWord(text: text, start: start, end: max(start, end))
        }
        return words.sorted { $0.start < $1.start }
    }
}

/// One row of the Recordings list: the movie plus whatever the sidecar says.
public struct ScreenRecordingItem: Identifiable, Sendable, Equatable {
    /// The movie's standardized path.
    public var id: String { url.standardizedFileURL.path }
    public var url: URL
    /// From the file stem when it parses, else the file's creation date.
    public var recordedAt: Date
    public var sizeBytes: Int64
    /// `nil` when no sidecar exists yet.
    public var record: ScreenRecordingRecord?

    public init(url: URL, recordedAt: Date, sizeBytes: Int64, record: ScreenRecordingRecord?) {
        self.url = url
        self.recordedAt = recordedAt
        self.sizeBytes = sizeBytes
        self.record = record
    }

    /// `record.title` when set, else a stable name from the file.
    public var displayTitle: String {
        if let title = record?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return url.deletingPathExtension().lastPathComponent
    }

    public enum TranscriptState: Sendable, Equatable {
        case untranscribed
        case transcribed
        case failed(String)
    }

    public var transcriptState: TranscriptState {
        guard let record else { return .untranscribed }
        if record.hasTranscript { return .transcribed }
        if let error = record.transcriptError { return .failed(error) }
        return .untranscribed
    }
}
