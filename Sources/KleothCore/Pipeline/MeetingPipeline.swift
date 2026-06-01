import Foundation

/// End-to-end pipeline: transcribe an audio file, optionally summarize it,
/// and persist the results.
public struct MeetingPipeline {
    public let transcriber: any Transcriber
    public let summarizer: Summarizer?
    public let store: MeetingStore

    public init(transcriber: any Transcriber, summarizer: Summarizer?, store: MeetingStore) {
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.store = store
    }

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
        summarize: Bool,
        meetingDir: URL? = nil
    ) async throws -> (transcript: Transcript, summary: MeetingSummary?, meetingDir: URL, cost: CostBreakdown, summaryError: String?) {
        // Resolve the destination folder up front. For a live recording the
        // caller passes the folder the audio was captured into, so transcript and
        // audio stay together; otherwise derive a fresh, collision-free folder.
        let dir = meetingDir ?? MeetingStore.uniqueMeetingDirectory(in: store.baseDir)

        // 1. Transcribe with the configured engine (Scribe, or on-device local).
        let raw = try await transcriber.transcribe(fileURL: audioFile, options: options)

        // 2. Normalize.
        var transcript = TranscriptNormalizer.normalize(raw)

        // 3. Apply an existing speaker map, if one was saved for this meeting.
        let speakerMap = loadExistingSpeakerMap(in: dir)
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
        // Prefer the audio file's wall-clock duration: Scribe's multichannel
        // response reports `audio_duration_secs` summed across channels (≈2×),
        // so the file is the reliable source. Fall back to the response when the
        // file can't be probed (e.g. imported/synthesized transcripts).
        let durationSecs = AudioProbe.durationSeconds(of: audioFile) ?? transcript.durationSecs
        let transcriptionUSD = transcriber.usdPerHour * (durationSecs ?? 0) / 3600
        let cost = CostBreakdown(
            transcriptionUSD: transcriptionUSD,
            summaryUSD: summaryUSD,
            audioDurationSecs: durationSecs
        )

        var finalMetadata = metadata
        finalMetadata.cost = cost

        // Adopt the model's title only when the current one is an auto-generated
        // placeholder — a calendar- or user-supplied title is always kept. Done
        // before rendering, since the renderer uses `finalMetadata.title`.
        if let title = summary?.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           MeetingMetadata.isPlaceholderTitle(finalMetadata.title) {
            finalMetadata.title = title
        }

        // 6. Render Markdown and persist.
        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: finalMetadata,
            includeTranscript: true
        )

        let savedDir = try store.save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: summary == nil ? nil : markdown,
            speakerMap: speakerMap,
            metadata: finalMetadata
        )

        return (transcript, summary, savedDir, cost, summaryError)
    }

    // MARK: - Helpers

    /// Loads a `SpeakerMap` previously saved into this meeting's folder, if any,
    /// so a `rename` done before (re-)processing carries real names through
    /// summarization and rendering.
    private func loadExistingSpeakerMap(in dir: URL) -> SpeakerMap? {
        let url = dir.appendingPathComponent("speakers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SpeakerMap.self, from: data)
    }
}
