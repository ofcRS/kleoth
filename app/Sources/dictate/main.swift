import AppKit
import Foundation
import KleothCapture
import KleothCore
import KleothOnDevice

// Top-level code, not `@main`: with FocusProbe.swift beside it this target has
// two files, and SwiftPM passes `-parse-as-library` (which `@main` needs) only
// to single-file executables. `main()` keeps the main-actor isolation `@main`
// gave it.
await DictateMain.main()

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
///     dictate --text "<raw transcript>" [--language rus] [--runs N] [--model <slug>] [--provider <id>] [--no-polish]   // polish-only benchmark
///     dictate … [--before <text>] [--after <text>] [--selection <text> | --reference <text>] [--single-line]   // the three above with a synthetic focused field (FieldProbe)
///     dictate --list-devices                                                          // input device UIDs for --device
///     dictate --focus-probe [--delay 5] [--wake none|role|manual|enhanced] …          // Accessibility spike (FocusProbe.swift; needs the terminal's Accessibility grant)
///
/// A future `--transcriber realtime` slots in at `makeTranscriber` below first;
/// the rest of the pipeline is engine-agnostic.
struct DictateMain {
    @MainActor
    static func main() async {
        guard #available(macOS 14.4, *) else {
            fail("needs macOS 14.4+")
        }

        // The focus probe is its own tool: it loads no keys and no settings, so
        // it is dispatched before anything else reads the command line.
        let commandLine = Array(CommandLine.arguments.dropFirst())
        if commandLine.contains(FocusProbe.flag) {
            await FocusProbe.run(commandLine.filter { $0 != FocusProbe.flag })
            return
        }

        let arguments = parse(CommandLine.arguments.dropFirst())
        let credentials = Credentials.resolve()
        let settings = Settings.load()

        // Polish-only benchmark: skip capture + STT and time the real polisher.
        if let text = arguments.text {
            // A field shows the app's gate first. --no-polish ends the run
            // before any provider is resolved, with or without a field.
            let field = FieldProbe(arguments)
            var gate = PolishGate.Decision.polish   // decided (and printed) for a field only
            if let field {
                gate = printGate(rawText: text, bundleId: field.bundleId,
                                 alwaysPolish: settings.dictationPolishAlways, field: field)
            }
            guard arguments.polish else {
                print("polish    : skipped (--no-polish)")
                field?.printPlanWithoutPolish(rawText: text)
                return
            }
            let terms = Keyterms.sanitize(PersonalDictionaryStore().load())
            var context = DictationContext(
                appBundleId: field?.bundleId ?? arguments.bundleId, appName: nil,
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
            context.field = field?.promptContext(for: selection.provider)
            let model = arguments.model ?? selection.model
            var polisher: DictationPolisher
            do {
                polisher = try factory.polisher(for: .init(provider: selection.provider, model: model, fellThroughFrom: nil))
            } catch {
                fail(error.localizedDescription)
            }
            polisher.reasoningOverride = reasoning     // benchmark site only
            print("provider  : \(selection.provider.displayName)")
            field?.printPrompt(for: selection.provider)
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
                if run == 1 {
                    field?.printPlan(polish: result, rawText: text, provider: selection.provider, gate: gate)
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
        let field = FieldProbe(arguments)
        let bundleId = field?.bundleId ?? arguments.bundleId
        guard arguments.polish else {
            // A field still gets the app's gate and paste, with no provider asked.
            if let field {
                printGate(rawText: rawText, bundleId: bundleId,
                          alwaysPolish: Settings.load().dictationPolishAlways, field: field)
            }
            print("polish    : skipped (--no-polish)")
            field?.printPlanWithoutPolish(rawText: rawText)
            return
        }
        var context = DictationContext(
            appBundleId: bundleId,
            appName: nil,
            languageCode: response.languageCode,
            dictionary: terms
        )
        // What the app would do with this transcript (the probe polishes
        // regardless, so the pipeline can still be timed).
        let gate = printGate(rawText: rawText, bundleId: bundleId,
                             alwaysPolish: Settings.load().dictationPolishAlways, field: field)
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
        context.field = field?.promptContext(for: selection.provider)
        let model = arguments.model ?? selection.model
        var polisher: DictationPolisher
        do {
            polisher = try factory.polisher(for: .init(provider: selection.provider, model: model, fellThroughFrom: nil))
        } catch {
            fail(error.localizedDescription)
        }
        print("provider  : \(selection.provider.displayName)")
        field?.printPrompt(for: selection.provider)
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
        field?.printPlan(polish: result, rawText: rawText, provider: selection.provider, gate: gate)
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

    // MARK: - Field context

    /// What the app's gate would do with this transcript, after the field and
    /// its placement when there is one. The gate takes the policy's context,
    /// before any provider is chosen, as the app's step 7 does (design
    /// 2026-09-24-dictation-context §4.4); without a field it is today's gate.
    /// Returns the decision, so a field run's paste line can say when the app
    /// wouldn't polish at all.
    @discardableResult
    static func printGate(rawText: String, bundleId: String?, alwaysPolish: Bool, field: FieldProbe?) -> PolishGate.Decision {
        field?.printPlacement()
        let gate = PolishGate.decide(
            rawText: rawText,
            style: AppStyle.classify(bundleId: bundleId),
            alwaysPolish: alwaysPolish,
            placement: PolishGate.placement(for: field?.context)
        )
        if case let .skip(reason) = gate {
            print("gate      : the app would paste as heard (\(PolishGate.wordCount(rawText)) words) — \(reason)")
        } else {
            print("gate      : the app would polish (\(PolishGate.wordCount(rawText)) words)")
        }
        return gate
    }

    /// `--before`, `--after`, `--selection`, `--reference`, `--single-line`: a
    /// focused field that exists only on the command line (design
    /// 2026-09-24-dictation-context §4.5). The flags become the facts the app's
    /// reader would return, and the run takes the app's steps from there: the
    /// policy's context gates, its prompt context goes to the polisher, and the
    /// paste plan, with the field unchanged at the re-check, says what ⌘V would
    /// paste. So the prompt benchmark (§6) sends what the app would, with no
    /// Accessibility and no app in front.
    struct FieldProbe {
        /// The app the field is in, and so the dictation's target for the gate
        /// and the prompt, as in the app, where the field read at release
        /// belongs to the press-time app: `--app`, else TextEdit; Ghostty for a
        /// `--reference`, which is a terminal's selection.
        let bundleId: String
        /// The `field` line: the role, the app, and where the caret or selection is.
        let summary: String
        /// The policy's class for the element; a skipped one says why it isn't read.
        let kind: DictationContextPolicy.ElementKind
        /// The policy's context, never built by hand: only the policy cleans and
        /// caps the text and drops it on a fence delimiter. nil = none to use.
        let context: DictationFieldContext?
        /// The field just before ⌘V: unchanged, the flags' text on either side.
        let recheck: DictationInsertionPlan.Recheck

        static let defaultBundleId = "com.apple.TextEdit"
        static let terminalBundleId = "com.mitchellh.ghostty"
        /// UTF-16 units the re-check reads on each side of the caret or selection,
        /// as `FocusedTextReader.recheckWindow` does in the app (R2).
        static let recheckUnits = 40

        /// nil when none of the five flags was given: the run is then today's.
        init?(_ arguments: Arguments) {
            guard arguments.fieldBefore != nil || arguments.fieldAfter != nil || arguments.fieldSelection != nil
                || arguments.fieldReference != nil || arguments.singleLine else { return nil }
            let before = arguments.fieldBefore ?? ""
            let after = arguments.fieldAfter ?? ""
            // `parse` refuses --reference with --selection: a field has one selection.
            let selected = arguments.fieldReference ?? arguments.fieldSelection ?? ""
            let app = arguments.fieldReference == nil ? (arguments.bundleId ?? Self.defaultBundleId) : Self.terminalBundleId
            let role = arguments.singleLine ? "AXTextField" : "AXTextArea"
            // UTF-16 units, as Accessibility counts; a caret is an empty range.
            let range = DictationTextRange(location: before.utf16.count, length: selected.utf16.count)
            let count = before.utf16.count + selected.utf16.count + after.utf16.count
            // The reader reads only the windows the policy plans around the range.
            let windows = DictationContextPolicy.readPlan(selection: range, characterCount: count)
            let facts = DictationFieldFacts(
                processIdentifier: 0,   // no process, so never Kleoth's own
                bundleId: app, role: role, subrole: nil, isEditable: true,
                characterCount: count, selection: range,
                selectedText: selected.isEmpty ? nil : selected,
                textBefore: String(decoding: before.utf16.suffix(windows.before.length), as: UTF16.self),
                textAfter: String(decoding: after.utf16.prefix(windows.after.length), as: UTF16.self),
                placeholder: nil
            )
            let kind = DictationContextPolicy.elementKind(
                bundleId: app, role: role, subrole: nil, isEditable: true, isKleoth: false
            )
            bundleId = app
            summary = "\(role) in \(app), "
                + (range.length == 0 ? "caret at \(range.location)" : "selection \(range.location)..<\(range.end)")
                + " of \(count) UTF-16 units"
            self.kind = kind
            context = DictationContextPolicy.context(from: facts, kind: kind)
            // Cut in UTF-16 units and cleaned, as the app's re-check reads and
            // cleans them: an edge that splits a surrogate pair decodes as
            // U+FFFD, which the cleaning removes.
            recheck = .unchanged(
                before: DictationContextPolicy.cleaned(
                    String(decoding: before.utf16.suffix(Self.recheckUnits), as: UTF16.self)
                ),
                after: DictationContextPolicy.cleaned(
                    String(decoding: after.utf16.prefix(Self.recheckUnits), as: UTF16.self)
                )
            )
        }

        /// The `field` and `placement` lines.
        func printPlacement() {
            print("field     : \(summary)")
            print("placement : \(Self.describe(context, kind: kind))")
        }

        /// The polisher's field: the policy's context as the prompt takes it —
        /// nil for a provider that takes none.
        func promptContext(for provider: AIProvider) -> DictationFieldContext? {
            context?.promptContext(providerSupportsContext: provider.supportsDictationContext)
        }

        /// The `prompt` line: whether the request carries the field. Without it
        /// the request is today's, byte for byte.
        func printPrompt(for provider: AIProvider) {
            if let sent = promptContext(for: provider) {
                print("prompt    : with the field (\(sent.placement))")
            } else if context != nil, !provider.supportsDictationContext {
                print("prompt    : today's — \(provider.displayName) takes no field context")
            } else {
                print("prompt    : today's — nothing of this field is sent")
            }
        }

        /// The `paste`, `outcome` and `warning` lines: what ⌘V would paste
        /// (quoted, so the fitted spaces show), the stored `field_context`, and
        /// the pill's warning when the plan has one. `provider` nil = none was
        /// asked (`--no-polish`).
        ///
        /// The probe polishes whatever the gate says, so when `gate` skips, the
        /// paste made from the polish is not what ⌘V would paste: its line reads
        /// `paste (if polished; the app would skip)`, and the app's own paste is
        /// the transcript as heard (`--no-polish` prints it). The outcome and the
        /// warning are the same either way, since the gate never skips a merge.
        func printPlan(
            polish: DictationPolishResult, rawText: String, provider: AIProvider?, gate: PolishGate.Decision = .polish
        ) {
            let plan = DictationInsertionPlan.decide(
                context: pasteContext(for: provider), polish: polish,
                rawText: rawText.trimmingCharacters(in: .whitespacesAndNewlines), recheck: recheck
            )
            var label = "paste     "
            if case .skip = gate { label = "paste (if polished; the app would skip)" }
            print("\(label): \(Self.quoted(plan.text))")
            print("outcome   : \(plan.outcome?.rawValue ?? "none (no field context)")")
            if let warning = plan.warning {
                print("warning   : \(warning)")
            }
        }

        /// `--no-polish`: no provider is resolved or asked, so the transcript goes
        /// in as heard, into the policy's own context — as after a gate skip.
        func printPlanWithoutPolish(rawText: String) {
            let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            printPlan(polish: .skipped(text: raw, reason: "--no-polish"), rawText: raw, provider: nil)
        }

        /// The paste's context: the policy's, with a merge turned into an append
        /// when `provider` can't merge; the policy's own when none was asked.
        private func pasteContext(for provider: AIProvider?) -> DictationFieldContext? {
            guard let provider, !provider.supportsDictationContext else { return context }
            return context?.appendingInstead(
                because: "\(provider.displayName) can't merge — added the dictation after the selection"
            )
        }

        /// The policy's verdict on the field, or why nothing of it is used.
        private static func describe(_ context: DictationFieldContext?, kind: DictationContextPolicy.ElementKind) -> String {
            guard let context else {
                if case let .skip(reason) = kind { return "none — never read (\(reason))" }
                return "none — nothing of this field is used (a fence delimiter in its text, or a terminal without selected text)"
            }
            switch (context.placement, context.verdict) {
            case (.cursor, _): return "cursor (\(describe(context.boundary)))"
            case (.reference, _): return "reference"
            case (.selection, .merge): return "selection, merge"
            case let (.selection, .append(reason)): return "selection, append: \(reason)"
            case let (.selection, .replace(reason)): return "selection, replace: \(reason)"
            }
        }

        private static func describe(_ boundary: DictationContextFit.Boundary) -> String {
            switch boundary {
            case .fieldStart: return "field start"
            case .lineStart: return "line start"
            case .sentenceStart: return "sentence start"
            case .midSentence: return "mid-sentence"
            }
        }

        /// `text` in double quotes on one line, with its backslashes, double
        /// quotes, line breaks and tabs escaped, so a paste holding quotes or a
        /// literal `\n` reads unambiguously. Apostrophes stay as they are
        /// (`debugDescription` would escape every one).
        private static func quoted(_ text: String) -> String {
            var result = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\\": result += "\\\\"
                case "\"": result += "\\\""
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\t": result += "\\t"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
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
        /// `--before`, `--after`, `--selection`, `--reference`, `--single-line`:
        /// the synthetic focused field of a mic, `--file` or `--text` run
        /// (`FieldProbe`). None given = no field, and today's output.
        var fieldBefore: String?
        var fieldAfter: String?
        var fieldSelection: String?
        var fieldReference: String?
        var singleLine = false
    }

    /// Every flag `parse` matches (`--focus-probe` never reaches it: it is
    /// dispatched first). A value flag refuses one of these as its value: with
    /// the value left out — `--before --no-polish`, or an empty variable in a
    /// benchmark script — the next flag would quietly become the value and stop
    /// doing its job (there, the run would polish for real). A value that only
    /// starts with `--` is fine: a terminal's text can.
    static let flagNames: Set<String> = [
        "--transcriber", "--model", "--provider", "--app", "--no-polish", "--text", "--language",
        "--reasoning", "--runs", "--device", "--file", "--fail-first", "--keep-on-failure",
        "--before", "--after", "--selection", "--reference", "--single-line", "--list-devices",
        "-h", "--help",
    ]

    static func parse(_ args: ArraySlice<String>) -> Arguments {
        var parsed = Arguments()
        var iterator = args.makeIterator()
        /// The argument after a value flag; none, or one of the flags, is a usage error.
        func value() -> String {
            guard let value = iterator.next(), !flagNames.contains(value) else { usage() }
            return value
        }
        while let arg = iterator.next() {
            switch arg {
            case "--transcriber":
                parsed.transcriber = value()
            case "--model":
                parsed.model = value()
            case "--provider":
                parsed.provider = value()
            case "--app":
                parsed.bundleId = value()
            case "--no-polish":
                parsed.polish = false
            case "--text":
                parsed.text = value()
            case "--language":
                parsed.language = value()
            case "--reasoning":
                guard let effort = OpenRouterReasoning.Effort(rawValue: value()) else { usage() }
                parsed.reasoning = effort
            case "--runs":
                guard let runs = Int(value()), runs > 0 else { usage() }
                parsed.runs = runs
            case "--device":
                parsed.device = value()
            case "--file":
                parsed.file = value()
            case "--fail-first":
                guard let count = Int(value()), count >= 0 else { usage() }
                parsed.failFirst = count
            case "--keep-on-failure":
                parsed.keepOnFailure = true
            case "--before":
                parsed.fieldBefore = value()
            case "--after":
                parsed.fieldAfter = value()
            case "--selection":
                parsed.fieldSelection = value()
            case "--reference":
                parsed.fieldReference = value()
            case "--single-line":
                parsed.singleLine = true
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
        // A terminal's selection is only a reference: a field can't have both.
        if parsed.fieldSelection != nil, parsed.fieldReference != nil { usage() }
        return parsed
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data(
            "usage: dictate [seconds] [--transcriber scribe] [--model <slug>] [--provider <id>] [--app <bundle-id>] [--no-polish] [--device <uid>]\n       dictate --file <audio> [--fail-first N] [--keep-on-failure] [--app <bundle-id>] [--no-polish] …   (a clip on disk; N injected transient failures; keep it as a pending History row)\n       dictate --text <raw transcript> [--language rus] [--runs N] [--model <slug>] [--provider <id>] [--reasoning minimal|low|medium|high] [--no-polish]   (polish-only benchmark)\n       dictate … [--before <text>] [--after <text>] [--selection <text> | --reference <text>] [--single-line]   (any of the three above, with a synthetic focused field in the --app target, else \(FieldProbe.defaultBundleId); a --reference is a terminal's selection, in \(FieldProbe.terminalBundleId). Adds the placement, the gate and the paste; with --no-polish no provider is asked)\n       dictate --list-devices\n       \(FocusProbe.synopsis)   (Accessibility spike: the focused field of the app in front; --focus-probe --help)\n".utf8
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
