import AppKit
import Foundation
import KleothCapture
import KleothCore
import KleothOnDevice

/// Headless dictation pipeline probe (design doc §5.10): record N seconds from
/// the default microphone → `DictationCapture.prepareForUpload` → the
/// `Transcriber` seam (ElevenLabs Scribe today) → `DictationPolisher`, then
/// print raw / polished / language / costs / fallback. No hotkey, no paste, no
/// Accessibility needed — this is the only way to exercise capture + network
/// without the UI. Keys come from `Credentials.resolve()` (env, `.env`,
/// `~/.config/kleoth/config.json`); the polish model from `Settings.load()`
/// unless `--model` overrides it. Key values are never printed.
///
///     dictate [seconds] [--transcriber scribe] [--model <slug>] [--provider <id>] [--no-polish] [--device <uid>]
///     dictate --file <audio> [--fail-first N] [--keep-on-failure] [--no-polish] …    // a clip on disk instead of the mic
///     dictate --text "<raw transcript>" [--language rus] [--runs N] [--model <slug>] [--provider <id>]   // polish-only benchmark
///     dictate --list-devices                                                          // input device UIDs for --device
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

        // Polish-only benchmark: skip capture + STT and time the real polisher.
        if let text = arguments.text {
            let terms = Keyterms.sanitize(PersonalDictionaryStore().load())
            let context = DictationContext(
                appBundleId: arguments.bundleId, appName: nil,
                languageCode: arguments.language, dictionary: terms
            )
            let reasoning = arguments.reasoning.map { OpenRouterReasoning(effort: $0) }
            let pick = arguments.provider.flatMap(AIProvider.parse)
            let appleAvailability = AppleOnDeviceClient.availability()
            let apple: (any ChatCompleting)? = appleAvailability.isAvailable ? AppleOnDeviceClient() : nil
            let bootstrap = await ProviderBootstrap.select(task: .dictation, pick: pick, settings: settings,
                                                          credentials: credentials, appleClient: apple,
                                                          appleAvailability: appleAvailability)
            let factory: ProviderFactory
            let selection: ProviderFactory.Selection
            switch bootstrap {
            case let .success(made): (factory, selection) = (made.factory, made.selection)
            case let .failure(error): fail(error.localizedDescription)
            }
            let model = arguments.model ?? selection.model
            var polisher: DictationPolisher
            do {
                polisher = try factory.polisher(for: .init(provider: selection.provider, model: model, fellThroughFrom: nil))
            } catch {
                fail(error.localizedDescription)
            }
            polisher.reasoningOverride = reasoning     // benchmark site only
            print("provider  : \(selection.provider.displayName)")
            print("model     : \(model)  reasoning \(arguments.reasoning?.rawValue ?? "<allowlist>")  (\(arguments.runs) run(s), \(text.count) chars, language \(arguments.language ?? "<nil>"))")
            var times: [Double] = []
            for run in 1...arguments.runs {
                let started = Date()
                let result = await polisher.polish(rawText: text, context: context)
                let seconds = Date().timeIntervalSince(started)
                times.append(seconds)
                switch result {
                case .polished(let out, let language, let cost):
                    print("run \(run)     : ok \(format(seconds)) s, lang \(language ?? "<nil>"), $\(String(format: "%.6f", cost))")
                    if run == 1 { print("polished  : \(out)") }
                case .raw(_, let reason, _):
                    print("run \(run)     : FELL BACK after \(format(seconds)) s — \(reason)")
                case .skipped:
                    break   // the polisher never returns this; only the app's gate does
                }
            }
            let sorted = times.sorted()
            print("summary   : min \(format(sorted.first!)) s, median \(format(sorted[sorted.count / 2])) s, max \(format(sorted.last!)) s")
            return
        }

        guard let elevenLabsKey = credentials.elevenLabsKey, !elevenLabsKey.isEmpty else {
            fail("no ElevenLabs API key (set ELEVEN_API_KEY, a .env, or ~/.config/kleoth/config.json)")
        }
        var transcriber: any Transcriber
        do {
            transcriber = try makeTranscriber(named: arguments.transcriber, elevenLabsKey: elevenLabsKey)
        } catch {
            fail("\(error)")
        }
        if arguments.failFirst > 0 {
            transcriber = FlakyTranscriber(wrapping: transcriber, failures: arguments.failFirst)
            print("injecting \(arguments.failFirst) transient failure(s) before the real engine answers")
        }

        // 1. Capture — or `--file`: a copy of a clip on disk stands in for the
        // mic (the copy, never the original, is what the cleanup deletes).
        let clip: DictationCaptureResult
        if let file = arguments.file {
            clip = clipFromFile(file)
        } else {
            clip = await record(arguments)
        }
        await transcribeAndPolish(clip: clip, transcriber: transcriber, arguments: arguments,
                                  settings: settings, credentials: credentials)
    }

    /// `--file`: copies the clip into the dictation temp folder, as if the
    /// mic had just written it.
    static func clipFromFile(_ path: String) -> DictationCaptureResult {
        let source = URL(fileURLWithPath: path)
        guard let seconds = AudioProbe.durationSeconds(of: source) else {
            fail("can't read audio from \(path)")
        }
        let directory = DictationCapture.tempDirectory()
        let copy = directory.appendingPathComponent("dictation-\(UUID().uuidString).\(source.pathExtension.isEmpty ? "m4a" : source.pathExtension)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            fail("can't copy \(path): \(error.localizedDescription)")
        }
        print("clip \(source.lastPathComponent): \(format(seconds)) s")
        return DictationCaptureResult(fileURL: copy, durationSeconds: seconds, sampleRate: 0)
    }

    /// Records `arguments.seconds` from the mic. `--device` is the app-wide
    /// microphone pick (`Settings.inputDeviceId`), applied the way every
    /// capture does.
    static func record(_ arguments: Arguments) async -> DictationCaptureResult {
        let capture = DictationCapture()
        capture.inputDeviceId = arguments.device
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
        return clip
    }

    /// Steps 2–4 of the app's pipeline on one clip: prepare, transcribe under
    /// the app's Scribe policy (`DictationTranscription`), polish.
    static func transcribeAndPolish(
        clip: DictationCaptureResult,
        transcriber: any Transcriber,
        arguments: Arguments,
        settings: Settings,
        credentials: Credentials
    ) async {

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

        // 3. Transcribe through the seam, under the app's Scribe policy.
        let terms = Keyterms.sanitize(PersonalDictionaryStore().load())
        let policy = DictationTranscription.Policy.scribe(audioSeconds: clip.durationSeconds)
        print("transcribing via \(arguments.transcriber) (\(DictationDefaults.transcriptionModel), no_verbatim, \(terms.count) keyterms), budget \(format(policy.budget ?? 0)) s × \(policy.attempts) attempts…")
        let response: ScribeResponse
        let sttSeconds: Double
        do {
            let result = try await DictationTranscription.run(
                transcriber,
                fileURL: uploadURL,
                options: .dictation(keyterms: terms),
                policy: policy,
                onAttemptFailed: { attempt, error, seconds in
                    print("attempt \(attempt) : failed after \(format(seconds)) s — \(error)")
                }
            )
            response = result.response
            sttSeconds = result.seconds
            print("attempts  : \(result.attempts)")
        } catch let failure as DictationTranscription.Failure {
            let summary = DictationTranscription.summary(of: failure, attempts: failure.attempts)
            print("pill      : \(summary.cause) — saved to History")
            print("history   : \(summary.detail)")
            if arguments.keepOnFailure {
                await keepAsPending(uploadURL, durationSeconds: clip.durationSeconds, reason: summary.detail,
                                    bundleId: arguments.bundleId, settings: settings)
            }
            // `fail` exits without running the `defer` above.
            DictationCapture.discard(clip.fileURL)
            DictationCapture.discard(uploadURL)
            fail("transcription failed: \(failure)")
        } catch {
            DictationCapture.discard(clip.fileURL)
            DictationCapture.discard(uploadURL)
            fail("transcription cancelled: \(error)")
        }
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
        let context = DictationContext(
            appBundleId: arguments.bundleId,
            appName: nil,
            languageCode: response.languageCode,
            dictionary: terms
        )
        // What the app would do with this transcript (the probe polishes
        // regardless, so the pipeline can still be timed).
        let gate = PolishGate.decide(
            rawText: rawText,
            style: AppStyle.classify(bundleId: arguments.bundleId),
            alwaysPolish: Settings.load().dictationPolishAlways
        )
        if case let .skip(reason) = gate {
            print("gate      : the app would paste as heard (\(PolishGate.wordCount(rawText)) words) — \(reason)")
        } else {
            print("gate      : the app would polish (\(PolishGate.wordCount(rawText)) words)")
        }
        let pick = arguments.provider.flatMap(AIProvider.parse)
        let appleAvailability = AppleOnDeviceClient.availability()
        let apple: (any ChatCompleting)? = appleAvailability.isAvailable ? AppleOnDeviceClient() : nil
        let bootstrap = await ProviderBootstrap.select(task: .dictation, pick: pick, settings: settings,
                                                      credentials: credentials, appleClient: apple,
                                                      appleAvailability: appleAvailability)
        let factory: ProviderFactory
        let selection: ProviderFactory.Selection
        switch bootstrap {
        case let .success(made): (factory, selection) = (made.factory, made.selection)
        case let .failure(error): fail(error.localizedDescription)
        }
        let model = arguments.model ?? selection.model
        var polisher: DictationPolisher
        do {
            polisher = try factory.polisher(for: .init(provider: selection.provider, model: model, fellThroughFrom: nil))
        } catch {
            fail(error.localizedDescription)
        }
        print("provider  : \(selection.provider.displayName)")
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
        case .skipped:
            break   // the polisher never returns this; only the app's gate does
        }
    }

    /// `--keep-on-failure`: what the app does with a clip Scribe could not
    /// transcribe — move it into `<output>/dictations/audio/` and log a pending
    /// row in the REAL history (`Settings.outputDir`), so History → Dictations
    /// has a "Not transcribed" row to try again. Dev tool only: this process
    /// writes the day file outside the app's store actor, so a dictation the
    /// app logs at the same instant could lose one of the two rows.
    static func keepAsPending(
        _ audio: URL, durationSeconds: Double, reason: String, bundleId: String?, settings: Settings
    ) async {
        let store = DictationLogStore(outputDir: settings.outputDir)
        let kept = DictationAudioStore(dictationsDirectory: store.baseDir)
        let id = UUID().uuidString
        do {
            let name = try kept.keep(audio, id: id)
            let appName = bundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            try await store.append(.pending(
                id: id,
                timestamp: DictationLogEntry.isoTimestamp(Date()),
                appBundleId: bundleId,
                appName: appName,
                durationSeconds: durationSeconds,
                audioFileName: name,
                transcriptionError: reason
            ))
            print("kept      : \(kept.directory.path)/\(name) — pending row \(id)")
        } catch {
            print("kept      : FAILED — \(error.localizedDescription)")
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
        var provider: String?
        var bundleId: String?
        var polish = true
        var text: String?
        var language: String?
        var runs = 1
        var reasoning: OpenRouterReasoning.Effort?
        /// A CoreAudio device UID (see `--list-devices`); nil = the system input.
        var device: String?
        /// `--file`: transcribe this clip instead of recording.
        var file: String?
        /// `--fail-first N`: the first N engine calls fail with a transient
        /// network error, so the retry runs against the real API.
        var failFirst = 0
        /// `--keep-on-failure`: a final failure keeps the clip and logs a
        /// pending row in the real dictation history, as the app does.
        var keepOnFailure = false
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
            case "--provider":
                guard let value = iterator.next() else { usage() }
                parsed.provider = value
            case "--app":
                guard let value = iterator.next() else { usage() }
                parsed.bundleId = value
            case "--no-polish":
                parsed.polish = false
            case "--text":
                guard let value = iterator.next() else { usage() }
                parsed.text = value
            case "--language":
                guard let value = iterator.next() else { usage() }
                parsed.language = value
            case "--reasoning":
                guard let value = iterator.next(), let effort = OpenRouterReasoning.Effort(rawValue: value) else { usage() }
                parsed.reasoning = effort
            case "--runs":
                guard let value = iterator.next(), let runs = Int(value), runs > 0 else { usage() }
                parsed.runs = runs
            case "--device":
                guard let value = iterator.next() else { usage() }
                parsed.device = value
            case "--file":
                guard let value = iterator.next() else { usage() }
                parsed.file = value
            case "--fail-first":
                guard let value = iterator.next(), let count = Int(value), count >= 0 else { usage() }
                parsed.failFirst = count
            case "--keep-on-failure":
                parsed.keepOnFailure = true
            case "--list-devices":
                let fallback = InputDevices.defaultInputName() ?? "none"
                for device in InputDevices.list() {
                    print("\(device.id)\t\(device.name)")
                }
                print("system input: \(fallback)")
                exit(0)
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
            "usage: dictate [seconds] [--transcriber scribe] [--model <slug>] [--provider <id>] [--app <bundle-id>] [--no-polish] [--device <uid>]\n       dictate --file <audio> [--fail-first N] [--keep-on-failure] [--app <bundle-id>] [--no-polish] …   (a clip on disk; N injected transient failures; keep it as a pending History row)\n       dictate --text <raw transcript> [--language rus] [--runs N] [--model <slug>] [--provider <id>] [--reasoning minimal|low|medium|high]   (polish-only benchmark)\n       dictate --list-devices\n".utf8
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

/// `--fail-first N`: the first N calls fail with a transient network error,
/// then the wrapped engine answers — the app's retry path against the live
/// API without waiting out a real timeout.
final class FlakyTranscriber: Transcriber, @unchecked Sendable {
    private let wrapped: any Transcriber
    private let lock = NSLock()
    private var remainingFailures: Int

    init(wrapping wrapped: any Transcriber, failures: Int) {
        self.wrapped = wrapped
        self.remainingFailures = failures
    }

    var usdPerHour: Double { wrapped.usdPerHour }

    func modelIdentifier(for options: ScribeOptions) -> String {
        wrapped.modelIdentifier(for: options)
    }

    func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
        if takeFailure() {
            throw URLError(.networkConnectionLost)
        }
        return try await wrapped.transcribe(fileURL: fileURL, options: options)
    }

    private func takeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
    }
}
