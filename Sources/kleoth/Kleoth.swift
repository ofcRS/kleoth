import ArgumentParser
import Foundation
import KleothCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Root command

@main
struct Kleoth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kleoth",
        abstract: "Transcribe, summarize, and share meeting recordings.",
        subcommands: [
            Transcribe.self,
            Summarize.self,
            Rename.self,
            Render.self,
        ]
    )
}

// MARK: - Shared helpers

/// Prints a message to standard error.
private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Formats a cost breakdown as a short human-readable line.
private func formatCost(_ cost: CostBreakdown) -> String {
    func usd(_ value: Double) -> String { String(format: "$%.4f", value) }
    var line = "Cost: \(usd(cost.totalUSD)) total"
        + " (transcription \(usd(cost.transcriptionUSD)), summary \(usd(cost.summaryUSD)))"
    if let secs = cost.audioDurationSecs {
        line += String(format: " — %.1fs audio", secs)
    }
    return line
}

/// Errors surfaced directly to the user with a clean message + nonzero exit.
private func fail(_ message: String) -> Error {
    ValidationError(message)
}

/// The current working directory as a URL, used as the project dir for
/// credential resolution.
private func currentDirectoryURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// Resolves the output base directory: explicit `--out` wins, else Settings.
private func resolveOutputDir(_ out: String?) -> URL {
    if let out { return URL(fileURLWithPath: out) }
    return Settings.load().outputDir
}

/// Builds a `MeetingMetadata` for a fresh recording from an audio file.
private func metadataForAudio(_ fileURL: URL, model: String?, languageCode: String?) -> MeetingMetadata {
    let title = fileURL.deletingPathExtension().lastPathComponent
    let now = Date()
    let dayFormatter = ISO8601DateFormatter()
    dayFormatter.formatOptions = [.withFullDate]
    let dateTimeFormatter = ISO8601DateFormatter()
    dateTimeFormatter.formatOptions = [.withInternetDateTime]
    return MeetingMetadata(
        title: title,
        date: dayFormatter.string(from: now),
        startedAt: dateTimeFormatter.string(from: now),
        participants: [],
        consentAcknowledged: false,
        model: model,
        languageCode: languageCode,
        cost: nil,
        // The CLI transcribes via ElevenLabs Scribe (the on-device engine lives
        // in the app target); mark these meetings as the SOTA tier.
        transcriptTier: TranscriptTier.sotaScribe
    )
}

/// Returns true if `url` points at an existing directory.
private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

/// Prints up to `limit` speaker turns from a transcript.
private func printTurns(_ transcript: Transcript, limit: Int = 20) {
    if transcript.utterances.isEmpty {
        print("(no speaker turns)")
        return
    }
    for utterance in transcript.utterances.prefix(limit) {
        let name = utterance.speakerName ?? utterance.speakerId
        print("\(name): \(utterance.text)")
    }
    if transcript.utterances.count > limit {
        print("… (\(transcript.utterances.count - limit) more turns)")
    }
}

// MARK: - transcribe

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe an audio file with ElevenLabs Scribe."
    )

    @Argument(help: "Path to the audio file to transcribe.")
    var file: String

    @Option(name: .long, help: "Hint for the number of distinct speakers.")
    var numSpeakers: Int?

    @Option(name: .long, help: "Language code (e.g. \"en\"). Auto-detected when omitted.")
    var language: String?

    @Option(name: .long, help: "Output directory for the meeting (defaults to settings).")
    var out: String?

    @Flag(name: .long, help: "Treat the input as multi-channel (one speaker per channel).")
    var multiChannel: Bool = false

    func run() async throws {
        let credentials = Credentials.resolve(projectDir: currentDirectoryURL())
        guard let elevenLabsKey = credentials.elevenLabsKey, !elevenLabsKey.isEmpty else {
            printError("Error: missing ElevenLabs API key. Set ELEVEN_API_KEY (or ELEVENLABS_API_KEY) in the environment, a .env file, or ~/.config/kleoth/config.json.")
            throw ExitCode.failure
        }

        let fileURL = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw fail("Audio file not found: \(file)")
        }

        let scribe = ScribeClient(apiKey: elevenLabsKey, transport: URLSessionTransport())
        let store = MeetingStore(baseDir: resolveOutputDir(out))
        let pipeline = MeetingPipeline(transcriber: scribe, summarizer: nil, store: store)

        let metadata = metadataForAudio(fileURL, model: nil, languageCode: language)
        let options = ScribeOptions(
            numSpeakers: numSpeakers,
            languageCode: language,
            useMultiChannel: multiChannel
        )

        let result = try await pipeline.run(
            audioFile: fileURL,
            metadata: metadata,
            options: options,
            summarize: false
        )

        printTurns(result.transcript)
        print("")
        print(formatCost(result.cost))
        print("Meeting saved to: \(result.meetingDir.path)")
    }
}

// MARK: - summarize

struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe (if needed) and summarize a meeting."
    )

    @Argument(help: "Path to an audio file, or an existing meeting directory.")
    var input: String

    @Option(name: .long, help: "Summarization model (defaults to settings).")
    var model: String?

    @Option(name: .long, help: "Output directory for the meeting (defaults to settings).")
    var out: String?

    @Flag(name: .long, help: "Exclude the full transcript from summary.md.")
    var noTranscript: Bool = false

    func run() async throws {
        let credentials = Credentials.resolve(projectDir: currentDirectoryURL())
        guard let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty else {
            printError("Error: missing OpenRouter API key. Set OPENROUTER_API_KEY in the environment, a .env file, or ~/.config/kleoth/config.json.")
            throw ExitCode.failure
        }

        let settings = Settings.load()
        let resolvedModel = model ?? settings.defaultModel
        let baseDir = resolveOutputDir(out)
        let store = MeetingStore(baseDir: baseDir)

        let openRouter = OpenRouterClient(apiKey: openRouterKey, transport: URLSessionTransport())
        let summarizer = Summarizer(client: openRouter, model: resolvedModel)

        let inputURL = URL(fileURLWithPath: input)

        if isDirectory(inputURL) {
            // Summarize an already-transcribed meeting in place.
            try await summarizeExistingMeeting(
                dir: inputURL,
                summarizer: summarizer,
                model: resolvedModel
            )
            return
        }

        // Fresh audio: both keys are required.
        guard let elevenLabsKey = credentials.elevenLabsKey, !elevenLabsKey.isEmpty else {
            printError("Error: missing ElevenLabs API key. Set ELEVEN_API_KEY (or ELEVENLABS_API_KEY) in the environment, a .env file, or ~/.config/kleoth/config.json.")
            throw ExitCode.failure
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw fail("Input is neither an existing directory nor a readable file: \(input)")
        }

        let scribe = ScribeClient(apiKey: elevenLabsKey, transport: URLSessionTransport())
        let pipeline = MeetingPipeline(transcriber: scribe, summarizer: summarizer, store: store)

        let metadata = metadataForAudio(inputURL, model: resolvedModel, languageCode: nil)
        let options = ScribeOptions()

        let result = try await pipeline.run(
            audioFile: inputURL,
            metadata: metadata,
            options: options,
            summarize: true
        )

        let summaryPath = result.meetingDir.appendingPathComponent("summary.md").path
        if result.summary != nil {
            print("Summary written to: \(summaryPath)")
        } else if let summaryError = result.summaryError {
            printError("Summary step failed (transcript was saved): \(summaryError)")
            print("Meeting saved to: \(result.meetingDir.path)")
        } else {
            print("Meeting saved to: \(result.meetingDir.path) (no summary produced)")
        }
        print(formatCost(result.cost))
    }

    /// Loads a saved meeting's transcript, summarizes it, re-renders Markdown,
    /// and re-saves alongside the existing raw response.
    private func summarizeExistingMeeting(
        dir: URL,
        summarizer: Summarizer,
        model: String
    ) async throws {
        let transcript = try store(forBase: dir).loadTranscript(in: dir)

        var metadata = try loadMetadata(in: dir)
        metadata.model = model

        let (summary, summaryUSD) = try await summarizer.summarize(
            transcript: transcript,
            metadata: metadata
        )

        // A model-generated title only upgrades a placeholder name (calendar /
        // user titles are kept), so the re-rendered summary.md H1 + meta.json
        // gain a meaningful title for previously auto-named meetings.
        if let generated = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !generated.isEmpty,
           MeetingMetadata.isPlaceholderTitle(metadata.title) {
            metadata.title = generated
        }

        // Per-engine cost: free local meetings cost $0; only SOTA (Scribe) is
        // billed. Duration comes from the actual audio file when present
        // (Scribe's multichannel response over-reports it), falling back to the
        // transcript's reported duration.
        let usdPerHour = TranscriptTier.usdPerHour(metadata.transcriptTier)
        let durationSecs = audioDurationSeconds(in: dir) ?? transcript.durationSecs
        let transcriptionUSD = usdPerHour * (durationSecs ?? 0) / 3600
        let cost = CostBreakdown(
            transcriptionUSD: transcriptionUSD,
            summaryUSD: summaryUSD,
            audioDurationSecs: durationSecs
        )
        metadata.cost = cost

        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: metadata,
            includeTranscript: !noTranscript
        )

        // Preserve the existing raw response if present (so transcript.json
        // stays intact); save everything else freshly.
        let raw = loadRawResponse(in: dir)
        let speakerMap = loadSpeakerMap(in: dir)

        // Re-save in place: the meeting already lives in `dir`.
        let savedDir = try MeetingStore(baseDir: dir.deletingLastPathComponent()).save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: markdown,
            speakerMap: speakerMap,
            metadata: metadata
        )

        let summaryPath = savedDir.appendingPathComponent("summary.md").path
        print("Summary written to: \(summaryPath)")
        print(formatCost(cost))
    }

    private func store(forBase dir: URL) -> MeetingStore {
        MeetingStore(baseDir: dir.deletingLastPathComponent())
    }

    private func loadMetadata(in dir: URL) throws -> MeetingMetadata {
        let url = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else {
            // Fall back to a minimal metadata derived from the directory name.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return MeetingMetadata(title: dir.lastPathComponent, date: formatter.string(from: Date()))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MeetingMetadata.self, from: data)
    }

    private func loadRawResponse(in dir: URL) -> ScribeResponse? {
        let url = dir.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ScribeResponse.self, from: data)
    }

    private func loadSpeakerMap(in dir: URL) -> SpeakerMap? {
        let url = dir.appendingPathComponent("speakers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SpeakerMap.self, from: data)
    }

    /// Wall-clock duration probed from the meeting's audio file (the robust
    /// source — Scribe's multichannel duration is summed across channels), or
    /// `nil` if no readable audio is present. Prefers the combined 2-channel
    /// file, then any single-source recording.
    private func audioDurationSeconds(in dir: URL) -> Double? {
        for name in ["meeting.m4a", "combined.m4a", "mic.m4a"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path),
               let secs = AudioProbe.durationSeconds(of: url) {
                return secs
            }
        }
        return nil
    }
}

// MARK: - rename

struct Rename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Assign real names to diarized speakers in a saved meeting."
    )

    @Argument(help: "Path to an existing meeting directory.")
    var meetingDir: String

    func run() async throws {
        let dir = URL(fileURLWithPath: meetingDir)
        guard isDirectory(dir) else {
            throw fail("Meeting directory not found: \(meetingDir)")
        }

        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        let transcript = try store.loadTranscript(in: dir)

        let samples = SpeakerMapper.samples(from: transcript, perSpeaker: 3)
        guard !samples.isEmpty else {
            print("No speakers found in this transcript.")
            return
        }

        // Show speakers in order of first appearance for a predictable prompt.
        let orderedSpeakerIds = orderedSpeakerIDs(in: transcript)

        var names: [String: String] = [:]
        for speakerId in orderedSpeakerIds {
            print("")
            print("Speaker \"\(speakerId)\" — sample turns:")
            for sample in samples[speakerId] ?? [] {
                print("  • \(sample)")
            }
            print("Enter a name for \"\(speakerId)\" (blank to keep as-is): ", terminator: "")
            let entered = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !entered.isEmpty {
                names[speakerId] = entered
            }
        }

        let speakerMap = SpeakerMap(names: names)
        let named = SpeakerMapper.apply(speakerMap, to: transcript)

        // Re-render Markdown with applied names. The summary's name-bearing
        // fields (action-item owners, highlight speakers) follow the rename too;
        // `transcript` still carries the previous names, which is the old→new
        // link the remap needs.
        let metadata = loadMetadata(in: dir, fallbackTitle: dir.lastPathComponent)
        let summary = ((try? store.loadSummary(in: dir)) ?? nil).map {
            SpeakerMapper.apply(speakerMap, toSummary: $0, previousTranscript: transcript)
        }
        let raw = loadRawResponse(in: dir)

        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: named,
            metadata: metadata,
            includeTranscript: true
        )

        // Re-save in place: reuse the meeting's existing directory.
        let savedDir = try store.save(
            in: dir,
            raw: raw,
            transcript: named,
            summary: summary,
            summaryMarkdown: summary == nil ? nil : markdown,
            speakerMap: speakerMap,
            metadata: metadata
        )

        print("")
        print("Saved speaker map and re-rendered transcript in: \(savedDir.path)")
    }

    private func orderedSpeakerIDs(in transcript: Transcript) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for utterance in transcript.utterances where seen.insert(utterance.speakerId).inserted {
            ordered.append(utterance.speakerId)
        }
        return ordered
    }

    private func loadMetadata(in dir: URL, fallbackTitle: String) -> MeetingMetadata {
        let url = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let metadata = try? decoder.decode(MeetingMetadata.self, from: data) {
                return metadata
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return MeetingMetadata(title: fallbackTitle, date: formatter.string(from: Date()))
    }

    private func loadRawResponse(in dir: URL) -> ScribeResponse? {
        let url = dir.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ScribeResponse.self, from: data)
    }
}

// MARK: - render

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-render summary.md from a meeting's summary.json + transcript (no API calls)."
    )

    @Argument(help: "Path to an existing meeting directory.")
    var meetingDir: String

    @Flag(name: .long, help: "Exclude the full transcript from summary.md.")
    var noTranscript: Bool = false

    func run() async throws {
        let dir = URL(fileURLWithPath: meetingDir)
        guard isDirectory(dir) else {
            throw fail("Meeting directory not found: \(meetingDir)")
        }

        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        guard let summary = try store.loadSummary(in: dir) else {
            throw fail("No summary.json found in \(meetingDir). Create one with `kleoth summarize` or the summarize-meeting Claude Code skill first.")
        }
        let transcript = try store.loadTranscript(in: dir)
        let metadata = loadMetadata(in: dir, fallbackTitle: dir.lastPathComponent)

        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: metadata,
            includeTranscript: !noTranscript
        )

        let summaryURL = dir.appendingPathComponent("summary.md")
        try Data(markdown.utf8).write(to: summaryURL, options: .atomic)
        print("Rendered summary written to: \(summaryURL.path)")
    }

    private func loadMetadata(in dir: URL, fallbackTitle: String) -> MeetingMetadata {
        let url = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let metadata = try? decoder.decode(MeetingMetadata.self, from: data) {
                return metadata
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return MeetingMetadata(title: fallbackTitle, date: formatter.string(from: Date()))
    }
}

