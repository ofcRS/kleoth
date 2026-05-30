import Foundation

/// End-to-end pipeline: transcribe an audio file, optionally summarize it,
/// and persist the results.
public struct MeetingPipeline {
    public let scribe: ScribeClient
    public let summarizer: Summarizer?
    public let store: MeetingStore

    public init(scribe: ScribeClient, summarizer: Summarizer?, store: MeetingStore) {
        self.scribe = scribe
        self.summarizer = summarizer
        self.store = store
    }

    /// ElevenLabs Scribe pricing: USD per hour of audio.
    private static let transcriptionUSDPerHour = 0.22

    /// Runs the full pipeline for one meeting.
    ///
    /// 1. Transcribe the audio with Scribe.
    /// 2. Normalize the raw response into a `Transcript`.
    /// 3. If a `speakers.json` already exists for this meeting, apply it so the
    ///    transcript carries real names through summarization and rendering.
    /// 4. If `summarize` is requested and a summarizer is configured, produce a
    ///    `MeetingSummary`.
    /// 5. Render Markdown and persist all artifacts.
    public func run(
        audioFile: URL,
        metadata: MeetingMetadata,
        options: ScribeOptions,
        summarize: Bool
    ) async throws -> (transcript: Transcript, summary: MeetingSummary?, meetingDir: URL, cost: CostBreakdown, summaryError: String?) {
        // 1. Transcribe.
        let raw = try await scribe.transcribe(fileURL: audioFile, options: options)

        // 2. Normalize.
        var transcript = TranscriptNormalizer.normalize(raw)

        // 3. Apply an existing speaker map, if one was saved for this meeting.
        let speakerMap = loadExistingSpeakerMap(for: metadata.title)
        if let speakerMap {
            transcript = SpeakerMapper.apply(speakerMap, to: transcript)
        }

        // 4. Summarize (optional).
        var summary: MeetingSummary?
        var summaryUSD = 0.0
        var summaryError: String?
        if summarize, let summarizer {
            do {
                let result = try await summarizer.summarize(transcript: transcript, metadata: metadata)
                summary = result.summary
                summaryUSD = result.costUSD
            } catch {
                // Best-effort: a summary failure (e.g. a provider/data-policy
                // error) must never discard a good transcript. Record the reason
                // and persist the transcript anyway.
                summaryError = "\(error)"
            }
        }

        // 5. Compute cost and stamp it onto the metadata before persisting.
        let durationSecs = transcript.durationSecs
        let transcriptionUSD = Self.transcriptionUSDPerHour * (durationSecs ?? 0) / 3600
        let cost = CostBreakdown(
            transcriptionUSD: transcriptionUSD,
            summaryUSD: summaryUSD,
            audioDurationSecs: durationSecs
        )

        var finalMetadata = metadata
        finalMetadata.cost = cost

        // 6. Render Markdown and persist.
        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: finalMetadata,
            includeTranscript: true
        )

        let meetingDir = try store.save(
            meetingName: finalMetadata.title,
            raw: raw,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: summary == nil ? nil : markdown,
            speakerMap: speakerMap,
            metadata: finalMetadata
        )

        return (transcript, summary, meetingDir, cost, summaryError)
    }

    // MARK: - Helpers

    /// Loads a previously-saved `SpeakerMap` for this meeting, if one exists.
    ///
    /// The meeting directory is derived from `store.baseDir` plus the same slug
    /// the store uses, so this finds a `speakers.json` written by a prior
    /// `rename` step even though the directory is not created until `save`.
    private func loadExistingSpeakerMap(for title: String) -> SpeakerMap? {
        let dir = store.baseDir.appendingPathComponent(MeetingStore.slug(title), isDirectory: true)
        let url = dir.appendingPathComponent("speakers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SpeakerMap.self, from: data)
    }
}
