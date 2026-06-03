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

        // Resolve the transcription language ONCE up front. WhisperKit defaults
        // `detectLanguage` to false (it is `!usePrefillPrompt`, and prefill is on
        // by default), so passing only `language: nil` silently resolves to
        // English — the root cause of Russian meetings being transcribed in
        // English. When no language is pinned we run a single global detection
        // pass and force that one language across every VAD chunk, so detection
        // can't drift per chunk; only if that fails do we leave it to WhisperKit's
        // per-window auto-detect (`detectLanguage: true`).
        let resolvedLanguage = await Self.resolveLanguage(pinned: language, sources: sources, pipe: pipe)
        let decodeOptions = DecodingOptions(
            task: .transcribe,                          // transcribe, never translate
            language: resolvedLanguage,                 // concrete code → no per-chunk drift
            detectLanguage: resolvedLanguage == nil,    // last-resort auto-detect
            wordTimestamps: false,
            chunkingStrategy: .vad                       // robust long-form handling
        )

        // Single channel → single-channel `words[]` response.
        if sources.count == 1 {
            let channel = try await Self.transcribeFile(sources[0], pipe: pipe, options: decodeOptions)
            return ScribeResponse(
                text: channel.text,
                words: channel.words,
                transcripts: nil,
                audioDurationSecs: channel.duration,
                // Prefer the language resolved up front (it considered confidence
                // across the audio) so the summarizer always learns the real
                // language and summarizes in it — not English.
                languageCode: resolvedLanguage ?? channel.language,
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
            // Prefer the globally-resolved language over the first channel's tag:
            // a silent/late-speaking mic (channel 0) can yield no language, which
            // would otherwise leave this nil and make the summary default to
            // English even though the transcript is (e.g.) Russian.
            languageCode: resolvedLanguage ?? detectedLanguage,
            transcriptionId: nil
        )
    }

    /// Resolves the language to transcribe in. A pinned, non-empty `language`
    /// always wins (no detection passes). Otherwise a `detectLanguage` pass over a
    /// source's opening seconds yields a stable code to force across every chunk.
    ///
    /// With multiple channels it keeps the most *confident* detection so a
    /// quiet/silent mic channel never overrides the channel that actually carries
    /// speech — but it stops early once a channel is confident enough, so the
    /// common case (clear speech on the first channel) costs a single pass, not
    /// one per channel. Returns `nil` when detection fails for every source,
    /// leaving the caller to fall back to WhisperKit's per-window auto-detect.
    private static func resolveLanguage(
        pinned: String?,
        sources: [URL],
        pipe: WhisperKit
    ) async -> String? {
        if let pinned, !pinned.isEmpty { return pinned }

        var best: (language: String, confidence: Float)?
        for url in sources {
            guard let result = try? await pipe.detectLanguage(audioPath: url.path) else { continue }
            let confidence = result.langProbs[result.language] ?? 0
            if best == nil || confidence > best!.confidence {
                best = (result.language, confidence)
            }
            // Confident on this channel — no need to probe the rest.
            if confidence >= 0.85 { break }
        }
        return best?.language
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

    /// On-disk status of a WhisperKit model for UI (Settings): whether it is
    /// downloaded and, when present, its total size in bytes. Cheap — it only
    /// reads the cache directory listing.
    public static func cachedModelInfo(
        variant: String = LocalTranscriber.defaultModel
    ) -> (downloaded: Bool, sizeBytes: Int64) {
        guard let (folder, _) = cachedModel(variant: variant) else { return (false, 0) }
        return (true, directorySizeBytes(folder))
    }

    /// Total size (bytes) of all regular files under `url`, recursively.
    private static func directorySizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
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
                // Strip WhisperKit special tokens (<|startoftranscript|>,
                // <|en|>, <|transcribe|>, timestamp/<|endoftext|>, …) so the
                // written transcript.json is clean at the source.
                let text = WhisperText.clean(segment.text)
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
