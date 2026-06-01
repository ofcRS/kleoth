import Foundation
import KleothCore
import KleothCapture

/// Headless recovery/dev utility: transcribe an existing meeting folder in place
/// so the app then shows it as processed. Defaults to the on-device WhisperKit
/// engine; pass `scribe` to use ElevenLabs Scribe (cloud, paid, diarized).
///
///     localtranscribe <meeting-dir> [scribe]
@main
struct LocalTranscribeMain {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: localtranscribe <meeting-dir> [scribe]\n".utf8))
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        let useScribe = args.dropFirst(2).contains { $0 == "scribe" || $0 == "--scribe" }
        let fm = FileManager.default

        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let channels = [mic, system].filter { fm.fileExists(atPath: $0.path) }
        let combined = ["meeting.m4a", "combined.m4a"]
            .map { dir.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.path) }
        guard channels.first != nil || combined != nil else {
            FileHandle.standardError.write(Data("no audio in \(dir.path)\n".utf8))
            exit(1)
        }

        do {
            let creds = Credentials.resolve()
            let transcriber: any Transcriber
            let tier: String
            var options = ScribeOptions()
            let primary: URL
            var twoSpeakers = false

            if useScribe {
                guard let key = creds.elevenLabsKey, !key.isEmpty else {
                    FileHandle.standardError.write(Data("no ElevenLabs API key (set ELEVEN_API_KEY, a .env, or ~/.config/kleoth/config.json)\n".utf8))
                    exit(1)
                }
                let scribe = ScribeClient(apiKey: key, transport: URLSessionTransport())
                if fm.fileExists(atPath: mic.path), fm.fileExists(atPath: system.path) {
                    // Validated path (mirrors the app's "Fully transcribe"): mix the
                    // two channels to mono (1× cost, correct duration) and attribute
                    // You/Them by channel energy. Scribe diarization is NOT used.
                    transcriber = ChannelAttributedScribeTranscriber(scribe: scribe, micURL: mic, systemURL: system)
                    primary = combined ?? mic            // for AudioProbe duration only
                    options.useMultiChannel = false
                    twoSpeakers = true
                    print("Transcribing via ElevenLabs Scribe (mono mixdown + channel attribution)…")
                } else if let combined {
                    // Only a combined file (no separate channels) → Scribe multi-channel.
                    transcriber = scribe
                    primary = combined
                    options.useMultiChannel = true
                    twoSpeakers = true
                    print("Transcribing via ElevenLabs Scribe (multi-channel)…")
                } else {
                    transcriber = scribe
                    primary = channels.first ?? mic
                    print("Transcribing via ElevenLabs Scribe…")
                }
                tier = TranscriptTier.sotaScribe
            } else {
                // Only hit the network when the model is genuinely missing. When
                // it is already cached, skip the (foreground, hang-prone) Hub
                // precheck and let `LocalTranscriber` load it straight from disk.
                if LocalTranscriber.cachedModel(variant: LocalTranscriber.defaultModel) == nil {
                    print("Downloading model (one-time, ~600 MB)…")
                    var attempt = 0
                    while true {
                        attempt += 1
                        do {
                            try await LocalTranscriber.downloadModel(useBackgroundSession: false) { frac in
                                print("  model \(Int(frac * 100))%")
                            }
                            break
                        } catch {
                            if attempt >= 3 { throw error }
                            print("  download attempt \(attempt) failed (\(error)); retrying…")
                        }
                    }
                    print("Model ready. Transcribing locally (free, on-device)…")
                } else {
                    print("Model already on disk — loading offline. Transcribing locally (free, on-device)…")
                }
                transcriber = LocalTranscriber(channelFiles: channels)
                primary = channels.first ?? combined ?? mic
                tier = TranscriptTier.local
                twoSpeakers = (channels.count == 2)
            }

            let store = MeetingStore(baseDir: dir.deletingLastPathComponent())

            // Summarize too, if an OpenRouter key is configured — forcing a model
            // that works under a strict data policy (Haiku via Bedrock).
            var summarizer: Summarizer?
            if let openRouterKey = creds.openRouterKey, !openRouterKey.isEmpty {
                summarizer = Summarizer(
                    client: OpenRouterClient(apiKey: openRouterKey, transport: URLSessionTransport()),
                    model: Settings.load().defaultModel
                )
            }
            let pipeline = MeetingPipeline(transcriber: transcriber, summarizer: summarizer, store: store)

            // Default You/Them labels for the 2-channel case (mirrors the app).
            if twoSpeakers {
                let spk = dir.appendingPathComponent("speakers.json")
                if !fm.fileExists(atPath: spk.path) {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    if let data = try? encoder.encode(SpeakerMap(names: ["speaker_0": "You", "speaker_1": "Them"])) {
                        try? data.write(to: spk)
                    }
                }
            }

            let started = Self.folderDate(dir) ?? Date()
            let meta = MeetingMetadata(
                title: "Recording \(Self.day(started))",
                date: Self.day(started),
                startedAt: Self.iso(started),
                participants: [],
                consentAcknowledged: true,
                model: summarizer != nil ? Settings.load().defaultModel : nil,
                transcriptTier: tier
            )

            let result = try await pipeline.run(
                audioFile: primary,
                metadata: meta,
                options: options,
                summarize: summarizer != nil,
                meetingDir: dir
            )

            print("---")
            print("Saved to: \(result.meetingDir.path)")
            let dur = Int(result.transcript.durationSecs ?? 0)
            let engine = useScribe ? "ElevenLabs Scribe" : "WhisperKit (local)"
            print("Engine: \(engine)  Language: \(result.transcript.languageCode ?? "?")  Duration: \(dur)s  Cost: $\(String(format: "%.4f", result.cost.totalUSD))")
            if let summaryError = result.summaryError { print("Summary skipped: \(summaryError)") }
            print("--- transcript preview (first 16 turns) ---")
            for utterance in result.transcript.utterances.prefix(16) {
                print("\(utterance.speakerName ?? utterance.speakerId): \(utterance.text)")
            }
        } catch {
            FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func folderDate(_ dir: URL) -> Date? {
        let name = dir.lastPathComponent
        guard name.hasPrefix("meeting-") else { return nil }
        let stamp = String(name.dropFirst("meeting-".count).prefix(17))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
