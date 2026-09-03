import Foundation
import KleothCapture
import KleothCore

/// Headless dictation pipeline probe (design doc §5.10): record N seconds from
/// the default microphone → `DictationCapture.prepareForUpload` → the
/// `Transcriber` seam (ElevenLabs Scribe today) → `DictationPolisher`, then
/// print raw / polished / language / costs / fallback. No hotkey, no paste, no
/// Accessibility needed — this is the only way to exercise capture + network
/// without the UI. Keys come from `Credentials.resolve()` (env, `.env`,
/// `~/.config/kleoth/config.json`); the polish model from `Settings.load()`
/// unless `--model` overrides it. Key values are never printed.
///
///     dictate [seconds] [--transcriber scribe] [--model <slug>] [--no-polish]
///
/// A future `--transcriber realtime` slots in at `makeTranscriber` below first;
/// the rest of the pipeline is engine-agnostic.
@main
struct DictateMain {
    static func main() async {
        guard #available(macOS 14.4, *) else {
            fail("needs macOS 14.4+")
        }

        let arguments = parse(CommandLine.arguments.dropFirst())
        let credentials = Credentials.resolve()
        let settings = Settings.load()
        let model = arguments.model ?? settings.dictationModel

        guard let elevenLabsKey = credentials.elevenLabsKey, !elevenLabsKey.isEmpty else {
            fail("no ElevenLabs API key (set ELEVEN_API_KEY, a .env, or ~/.config/kleoth/config.json)")
        }
        let transcriber: any Transcriber
        do {
            transcriber = try makeTranscriber(named: arguments.transcriber, elevenLabsKey: elevenLabsKey)
        } catch {
            fail("\(error)")
        }

        // 1. Capture.
        let capture = DictationCapture()
        let rawURL: URL
        do {
            rawURL = try capture.start()
        } catch {
            fail("couldn't start the microphone: \(error.localizedDescription)")
        }
        print("recording \(format(arguments.seconds)) s → \(rawURL.lastPathComponent)  (speak now)")

        // RMS at 20 Hz, the same poll the app's pill meter uses.
        let ticks = Int(arguments.seconds * 20)
        var peakLevel: Double = 0
        for tick in 0..<ticks {
            try? await Task.sleep(for: .milliseconds(50))
            let level = PillGeometry.normalizedLevel(rms: capture.currentLevel)
            peakLevel = max(peakLevel, level)
            let bar = String(repeating: "█", count: Int(level * 30))
            let padded = bar.padding(toLength: 30, withPad: " ", startingAt: 0)
            let stamp = format(Double(tick + 1) / 20)
            FileHandle.standardError.write(Data("\r  \(stamp) s  |\(padded)| \(String(format: "%.3f", level))".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))

        let clip: DictationCaptureResult
        do {
            guard let result = try capture.stop(minimumSeconds: DictationDefaults.minimumUtterance) else {
                fail("clip shorter than \(DictationDefaults.minimumUtterance) s — discarded (nothing sent)")
            }
            clip = result
        } catch {
            fail("capture failed: \(error.localizedDescription)")
        }
        print("captured \(format(clip.durationSeconds)) s @ \(Int(clip.sampleRate)) Hz, peak meter level \(String(format: "%.2f", peakLevel))")

        // 2. Prepare (mono downmix + loudness/peak normalize, 64 kbps).
        var prepared: URL?
        defer {
            DictationCapture.discard(clip.fileURL)
            prepared.map(DictationCapture.discard)
        }
        let uploadURL: URL
        do {
            let raw = clip.fileURL
            uploadURL = try await Task.detached(priority: .userInitiated) {
                try DictationCapture.prepareForUpload(raw)
            }.value
            prepared = uploadURL
        } catch {
            fail("couldn't prepare the audio: \(error.localizedDescription)")
        }
        let uploadBytes = (try? FileManager.default.attributesOfItem(atPath: uploadURL.path)[.size] as? Int) ?? 0
        print("prepared \(uploadURL.lastPathComponent) (\(uploadBytes / 1024) KB)")

        // 3. Transcribe through the seam.
        let terms = Keyterms.sanitize(PersonalDictionaryStore().load())
        print("transcribing via \(arguments.transcriber) (\(DictationDefaults.transcriptionModel), no_verbatim, \(terms.count) keyterms)…")
        let started = Date()
        let response: ScribeResponse
        do {
            response = try await withTimeout(seconds: DictationDefaults.scribeTimeout) {
                try await transcriber.transcribe(fileURL: uploadURL, options: .dictation(keyterms: terms))
            }
        } catch let scribe as ScribeError {
            fail("transcription failed: \(scribe.description)")
        } catch {
            fail("transcription failed: \(error.localizedDescription)")
        }
        let sttSeconds = Date().timeIntervalSince(started)
        let rawText = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surcharge = terms.isEmpty ? 1 : DictationDefaults.keytermSurchargeMultiplier
        let transcriptionCost = transcriber.usdPerHour * clip.durationSeconds / 3600 * surcharge

        print("")
        print("raw       : \(rawText.isEmpty ? "<empty>" : rawText)")
        print("language  : \(response.languageCode ?? "<nil>")")
        print("stt       : \(format(sttSeconds)) s, billed duration \(response.audioDurationSecs.map(format) ?? "<nil>") s, est. $\(String(format: "%.6f", transcriptionCost))")

        guard !rawText.isEmpty else {
            print("polish    : skipped (nothing was heard)")
            return
        }

        // 4. Polish.
        guard arguments.polish else {
            print("polish    : skipped (--no-polish)")
            return
        }
        guard let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty else {
            print("polish    : skipped (no OpenRouter key) — the app would paste the raw transcript")
            return
        }
        let context = DictationContext(
            appBundleId: arguments.bundleId,
            appName: nil,
            languageCode: response.languageCode,
            dictionary: terms
        )
        let polisher = DictationPolisher(
            client: OpenRouterClient(apiKey: openRouterKey, transport: URLSessionTransport()),
            model: model
        )
        let polishStarted = Date()
        let result = await polisher.polish(rawText: rawText, context: context)
        let polishSeconds = Date().timeIntervalSince(polishStarted)

        print("model     : \(model)")
        switch result {
        case .polished(let text, let language, let cost):
            print("polished  : \(text)")
            print("polish    : ok in \(format(polishSeconds)) s, model language \(language ?? "<nil>"), $\(String(format: "%.6f", cost))")
        case .raw(_, let reason, let cost):
            print("polished  : <raw fallback>")
            print("polish    : FELL BACK after \(format(polishSeconds)) s — \(reason) (billed $\(String(format: "%.6f", cost)))")
        }
    }

    // MARK: - Engines

    /// The one place an engine is named. `scribe` today; `realtime` later.
    static func makeTranscriber(named name: String, elevenLabsKey: String) throws -> any Transcriber {
        switch name.lowercased() {
        case "scribe":
            return ScribeClient(apiKey: elevenLabsKey, transport: URLSessionTransport())
        default:
            throw ProbeError.unknownTranscriber(name)
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case unknownTranscriber(String)

        var description: String {
            switch self {
            case .unknownTranscriber(let name):
                return "unknown transcriber '\(name)' (supported: scribe)"
            }
        }
    }

    // MARK: - Arguments

    struct Arguments {
        var seconds: Double = 4
        var transcriber = "scribe"
        var model: String?
        var bundleId: String?
        var polish = true
    }

    static func parse(_ args: ArraySlice<String>) -> Arguments {
        var parsed = Arguments()
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--transcriber":
                guard let value = iterator.next() else { usage() }
                parsed.transcriber = value
            case "--model":
                guard let value = iterator.next() else { usage() }
                parsed.model = value
            case "--app":
                guard let value = iterator.next() else { usage() }
                parsed.bundleId = value
            case "--no-polish":
                parsed.polish = false
            case "-h", "--help":
                usage()
            default:
                guard let seconds = Double(arg), seconds > 0 else { usage() }
                parsed.seconds = seconds
            }
        }
        return parsed
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data(
            "usage: dictate [seconds] [--transcriber scribe] [--model <openrouter-slug>] [--app <bundle-id>] [--no-polish]\n".utf8
        ))
        exit(2)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("dictate: \(message)\n".utf8))
        exit(1)
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }
}
