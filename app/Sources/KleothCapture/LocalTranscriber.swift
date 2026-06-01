import Foundation
import AVFoundation
import WhisperKit
import KleothCore

/// On-device transcriber backed by WhisperKit (Whisper on Core ML / the Apple
/// Neural Engine). Free, private (audio never leaves the machine), and
/// multilingual with **automatic language detection** — so it handles Russian
/// (which Apple's first-party `SpeechTranscriber` does not), English, and ~90
/// other languages with one engine.
///
/// It returns a `ScribeResponse` so the rest of `MeetingPipeline`
/// (normalize → summarize → render → store) is unchanged:
/// - With `channelFiles` set, each file becomes one channel/speaker via the
///   multi-channel `transcripts[]` shape (`speaker_0`, `speaker_1`, …) — e.g.
///   mic = "You", system = "Them" — so You-vs-Them attribution is free.
/// - With `channelFiles` empty, the single `fileURL` passed to `transcribe` is
///   transcribed as one channel (imported audio).
///
/// The Whisper model is downloaded once on first use (~600 MB for the default)
/// and cached on-device; subsequent runs are offline.
public struct LocalTranscriber: Transcriber {
    /// Per-channel audio files, in speaker order. Empty → transcribe the
    /// `fileURL` argument as a single channel.
    public let channelFiles: [URL]
    /// WhisperKit model identifier (multilingual large-v3 turbo by default).
    public let model: String
    /// Forced language code (e.g. `"ru"`). `nil` → automatic detection.
    public let language: String?

    /// Default model: multilingual large-v3 turbo (~626 MB), strong on Russian.
    public static let defaultModel = "large-v3-v20240930_626MB"

    public init(
        channelFiles: [URL] = [],
        model: String = LocalTranscriber.defaultModel,
        language: String? = nil
    ) {
        self.channelFiles = channelFiles
        self.model = model
        self.language = language
    }

    /// On-device transcription is free.
    public var usdPerHour: Double { 0 }

    /// Pre-downloads the Whisper model using a background URLSession (so a large
    /// or slow first-run download is not killed by the 60-second request
    /// timeout), reporting fractional progress (0…1). Cheap once the model is
    /// already cached on disk.
    public static func downloadModel(
        model: String = LocalTranscriber.defaultModel,
        useBackgroundSession: Bool = true,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: model,
            useBackgroundSession: useBackgroundSession,
            progressCallback: { progress($0.fractionCompleted) }
        )
    }

    public func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        let sources = channelFiles.isEmpty ? [fileURL] : channelFiles

        // Load the model once and reuse it across channels. Prefer loading the
        // already-downloaded model straight from disk (zero network); only fall
        // back to a background download on a genuine first run. See `modelConfig`.
        let pipe = try await WhisperKit(Self.modelConfig(for: model))
        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language,          // nil → auto-detect
            wordTimestamps: false,
            chunkingStrategy: .vad       // robust long-form handling
        )

        // Single channel → single-channel `words[]` response.
        if sources.count == 1 {
            let channel = try await Self.transcribeFile(sources[0], pipe: pipe, options: decodeOptions)
            return ScribeResponse(
                text: channel.text,
                words: channel.words,
                transcripts: nil,
                audioDurationSecs: channel.duration,
                languageCode: channel.language,
                transcriptionId: nil
            )
        }

        // Multiple channels → multi-channel `transcripts[]` (one speaker each).
        var transcripts: [ScribeChannelTranscript] = []
        var maxDuration = 0.0
        var detectedLanguage: String?
        for (index, url) in sources.enumerated() {
            let channel = try await Self.transcribeFile(url, pipe: pipe, options: decodeOptions)
            transcripts.append(ScribeChannelTranscript(
                text: channel.text,
                words: channel.words,
                channelIndex: index
            ))
            maxDuration = max(maxDuration, channel.duration)
            if detectedLanguage == nil { detectedLanguage = channel.language }
        }
        return ScribeResponse(
            text: nil,
            words: nil,
            transcripts: transcripts,
            audioDurationSecs: maxDuration,
            languageCode: detectedLanguage,
            transcriptionId: nil
        )
    }

    // MARK: - WhisperKit plumbing

    /// Builds a `WhisperKitConfig` that loads the model **from disk with no
    /// network** when it is already cached, falling back to a background
    /// (timeout-resilient) download only on a genuine first run.
    ///
    /// WhisperKit's default resolution calls the HuggingFace Hub on *every* load
    /// (`getFilenames`/`snapshot`) even when the model is fully cached — a
    /// round-trip that, on poor or no connectivity, hangs the supposedly
    /// "offline" local path indefinitely (observed: a multi-minute stall with the
    /// model already on disk). Pointing `modelFolder` at the cached model skips
    /// the Hub entirely; a non-nil `modelFolder` also flips WhisperKit's `load`
    /// default to `true`, so the model is actually loaded. `downloadBase` lets
    /// the tokenizer (cached under the same root) resolve locally too.
    static func modelConfig(for variant: String) -> WhisperKitConfig {
        if let cached = cachedModel(variant: variant) {
            return WhisperKitConfig(
                downloadBase: cached.downloadBase,
                modelFolder: cached.modelFolder.path,
                useBackgroundDownloadSession: true
            )
        }
        return WhisperKitConfig(model: variant, useBackgroundDownloadSession: true)
    }

    /// Locates an already-downloaded WhisperKit model in the default HuggingFace
    /// cache (`<Documents>/huggingface/models/argmaxinc/whisperkit-coreml/…`).
    /// Returns the model folder plus the cache base (used for tokenizer
    /// resolution), or `nil` when the model must still be downloaded.
    public static func cachedModel(variant: String) -> (modelFolder: URL, downloadBase: URL)? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let downloadBase = documents.appendingPathComponent("huggingface", isDirectory: true)
        let folderName = variant.hasPrefix("openai_whisper-") ? variant : "openai_whisper-\(variant)"
        let modelFolder = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        // Require the CoreML model to actually be present, not merely the folder.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: modelFolder.path)) ?? []
        let hasModel = entries.contains { $0.hasPrefix("AudioEncoder") }
        return hasModel ? (modelFolder, downloadBase) : nil
    }

    /// Transcribes one audio file with an already-loaded pipeline, returning
    /// segment-timed words, the audio duration (seconds), the joined text, and
    /// the detected language.
    private static func transcribeFile(
        _ url: URL,
        pipe: WhisperKit,
        options: DecodingOptions
    ) async throws -> (words: [ScribeWord], duration: Double, text: String, language: String?) {
        let audioFile = try AVAudioFile(forReading: url)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
        guard audioFile.length > 0 else { return ([], duration, "", nil) }

        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)

        var words: [ScribeWord] = []
        var language: String?
        for result in results {
            if language == nil { language = result.language }
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(ScribeWord(
                    text: text,
                    start: Double(segment.start),
                    end: Double(segment.end),
                    type: "word",
                    speakerId: nil,
                    logprob: nil
                ))
            }
        }
        let text = words.map(\.text).joined(separator: " ")
        return (words, duration, text, language)
    }
}
