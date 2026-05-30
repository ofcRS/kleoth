import Foundation

/// Persists meeting artifacts (raw response, transcript, summary, markdown,
/// speaker map, metadata) to a per-meeting directory under `baseDir`.
public struct MeetingStore {
    public let baseDir: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    /// Saves all artifacts for a meeting and returns the meeting directory.
    ///
    /// Layout (under `baseDir/<slug>`):
    /// - `transcript.json` — raw `ScribeResponse` (only when non-nil)
    /// - `summary.json`    — `MeetingSummary` (only when non-nil)
    /// - `speakers.json`   — `SpeakerMap` (only when non-nil)
    /// - `meta.json`       — `MeetingMetadata` (always)
    /// - `transcript.md`   — the normalized transcript as "Name: text" lines
    /// - `summary.md`      — `summaryMarkdown` (only when non-nil)
    ///
    /// JSON is encoded pretty-printed, with sorted keys and snake_case keys so
    /// it round-trips with the read side and the rest of the toolchain.
    @discardableResult
    public func save(
        meetingName: String,
        raw: ScribeResponse?,
        transcript: Transcript,
        summary: MeetingSummary?,
        summaryMarkdown: String?,
        speakerMap: SpeakerMap?,
        metadata: MeetingMetadata
    ) throws -> URL {
        let fm = FileManager.default
        let dir = baseDir.appendingPathComponent(Self.slug(meetingName), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = Self.makeEncoder()

        // transcript.json holds the raw Scribe response (only when present).
        if let raw {
            let data = try encoder.encode(raw)
            try data.write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        }

        if let summary {
            let data = try encoder.encode(summary)
            try data.write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
        }

        if let speakerMap {
            let data = try encoder.encode(speakerMap)
            try data.write(to: dir.appendingPathComponent("speakers.json"), options: .atomic)
        }

        // meta.json is always written.
        let metaData = try encoder.encode(metadata)
        try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)

        // transcript.md is the human-readable rendering of the utterances.
        let transcriptText = Self.renderTranscriptLines(transcript)
        try Data(transcriptText.utf8).write(
            to: dir.appendingPathComponent("transcript.md"),
            options: .atomic
        )

        if let summaryMarkdown {
            try Data(summaryMarkdown.utf8).write(
                to: dir.appendingPathComponent("summary.md"),
                options: .atomic
            )
        }

        return dir
    }

    /// Loads the normalized transcript stored in `dir`.
    ///
    /// `transcript.json` is the raw `ScribeResponse`, so it is normalized back
    /// into a `Transcript`. There is no standalone normalized-transcript JSON.
    public func loadTranscript(in dir: URL) throws -> Transcript {
        let decoder = Self.makeDecoder()
        let rawURL = dir.appendingPathComponent("transcript.json")
        let data = try Data(contentsOf: rawURL)
        let raw = try decoder.decode(ScribeResponse.self, from: data)
        return TranscriptNormalizer.normalize(raw)
    }

    /// Loads the summary stored in `dir`, if any.
    public func loadSummary(in dir: URL) throws -> MeetingSummary? {
        let url = dir.appendingPathComponent("summary.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(MeetingSummary.self, from: data)
    }

    // MARK: - Helpers

    /// Converts a meeting name into a filesystem-friendly slug: lowercased,
    /// every run of non-alphanumeric characters collapsed to a single "-",
    /// with leading/trailing dashes trimmed.
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                if pendingDash, !result.isEmpty {
                    result.append("-")
                }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return result.isEmpty ? "meeting" : result
    }

    /// Renders transcript utterances as "Name: text" lines (one per line),
    /// preferring the resolved speaker name and falling back to the speaker id.
    static func renderTranscriptLines(_ transcript: Transcript) -> String {
        transcript.utterances.map { utterance in
            let name = utterance.speakerName ?? utterance.speakerId
            return "\(name): \(utterance.text)"
        }
        .joined(separator: "\n")
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
