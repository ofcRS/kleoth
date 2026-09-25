import ArgumentParser
import Foundation
import KleothCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - illustrate

/// Draws covers for meetings that already have a summary (design doc
/// 2026-09-24 §3.7). It is the backfill the app never does on its own, and the
/// live probe for the cover pipeline: the app package has no test target, so
/// the scene step, every image engine and the History wording are exercised
/// end to end here, through the same `CoverDrawing` the app uses.
struct Illustrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draw a cover picture for summarized meetings."
    )

    @Argument(help: "One or more meeting folders; each needs a summary.json.")
    var meetingDirs: [String]

    @Option(name: .long, help: "Image engine: local, codex or openrouter. Defaults to cover_engine in config.json.")
    var engine: String?

    @Option(name: .long, help: "Image model (defaults to cover_models, else the engine's own default). Codex takes none.")
    var model: String?

    @Option(name: .long, help: "Cover style: auto, animation, illustration, sketch or clay. Defaults to cover_style in config.json.")
    var style: String?

    @Option(name: .long, help: "Scene provider: openrouter, local, claude-code or codex. Defaults to settings / auto-detection.")
    var provider: String?

    @Flag(name: .long, help: "Replace an existing cover (the old picture goes to the Trash), or draw one that was skipped or removed.")
    var force: Bool = false

    @Flag(name: .long, help: "Run only the scene step: print the scene and the image prompt, write nothing. Runs on meetings that already have a cover too.")
    var dryRun: Bool = false

    func run() async throws {
        // Every choice that needs no provider is settled first, so a typo or
        // Covers → Off fails before anything is detected or called.
        let settings = Settings.load()
        let credentials = Credentials.resolve(projectDir: illustrateCurrentDirectoryURL())
        let coverSettings = settings.coverSettings

        let engine: CoverEngine
        if let raw = self.engine {
            guard let parsed = CoverEngine(rawValue: raw.lowercased()) else {
                throw illustrateFail("Unknown engine '\(raw)'. Use local, codex or openrouter.")
            }
            engine = parsed
        } else if let configured = coverSettings.engine {
            engine = configured
        } else {
            // A config state, not a bad argument: exit 1 with no usage line,
            // as `summarize` does for a missing key.
            illustratePrintError("Error: Covers are off in ~/.config/kleoth/config.json — pass --engine local|codex|openrouter.")
            throw ExitCode.failure
        }
        let model = self.model ?? coverSettings.model(for: engine)

        // An explicit `--style auto` means Automatic even when config.json
        // fixes a style; only an absent `--style` falls back to the config.
        let fixedStyle: CoverStyle?
        if let raw = self.style {
            let lowered = raw.lowercased()
            if lowered == "auto" {
                fixedStyle = nil
            } else if let parsed = CoverStyle(rawValue: lowered) {
                fixedStyle = parsed
            } else {
                throw illustrateFail("Unknown style '\(raw)'. Use auto, animation, illustration, sketch or clay.")
            }
        } else {
            fixedStyle = coverSettings.style
        }

        var pick: AIProvider?
        if let provider {
            guard let parsed = AIProvider.parse(provider), parsed != .appleOnDevice else {
                throw illustrateFail("Unknown provider '\(provider)'. Use openrouter, local, claude-code or codex.")
            }
            pick = parsed
        }

        // The per-folder skips need no provider either: a run whose folders
        // are all skipped never detects, builds or calls anything.
        let store = CoverStore()
        var pending: [(path: String, dir: URL)] = []
        for path in meetingDirs {
            let dir = URL(fileURLWithPath: path)
            if let skip = skipReason(for: dir, store: store) {
                print("\(path): skipped — \(skip)")
            } else {
                pending.append((path, dir))
            }
        }
        guard !pending.isEmpty else { return }

        let bootstrap = await ProviderBootstrap.select(task: .summary, pick: pick, settings: settings, credentials: credentials)
        var factory: ProviderFactory
        let selection: ProviderFactory.Selection
        switch bootstrap {
        case let .success(made):
            (factory, selection) = (made.factory, made.selection)
        case let .failure(error):
            illustratePrintError("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        // The scene call gets the fail-fast transport so offline reads "No internet connection" (spec §5); summaries keep the waiting one.
        factory.transport = CoverEngineFactory.cloudTransport
        let writer = CoverSceneWriter(client: try factory.client(for: selection.provider), model: selection.model)
        illustratePrintError("Scene via \(selection.provider.displayName) · \(selection.model.isEmpty ? "default model" : selection.model)")

        if dryRun {
            var failed = false
            for (path, dir) in pending {
                do {
                    try await printScene(for: dir, path: path, writer: writer, fixedStyle: fixedStyle)
                } catch {
                    illustratePrintError("\(path): failed — \(CoverDrawing.reason(for: error, engine: engine))")
                    failed = true
                }
            }
            if failed { throw ExitCode.failure }
            return
        }

        let generator: any CoverImageGenerating
        do {
            generator = try CoverEngineFactory(
                settings: settings, credentials: credentials, runner: FoundationProcessRunner(), locator: .standard,
                cloudTransport: CoverEngineFactory.cloudTransport, localTransport: CoverEngineFactory.localTransport
            ).generator(for: engine)
        } catch {
            illustratePrintError("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let drawing = CoverDrawing(
            sceneWriter: writer, sceneProvider: selection.provider, generator: generator, store: store,
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        )
        var failed = false
        for (path, dir) in pending {
            do {
                let outcome = try await drawing.draw(
                    CoverDrawing.Request(meetingDir: dir, engine: engine, model: model, fixedStyle: fixedStyle)
                )
                print("\(path): \(describe(outcome, in: dir, engine: engine, model: model, store: store))")
            } catch {
                illustratePrintError("\(path): failed — \(CoverDrawing.reason(for: error, engine: engine))")
                failed = true
            }
        }
        if failed { throw ExitCode.failure }
    }

    // MARK: - Private

    /// Why `dir` is left alone, or nil when it needs a cover. Without
    /// `--force`, a record of `skipped` or `removed` counts as a cover: both
    /// are a decision the app honours, and so does the CLI. `--dry-run` is
    /// exempt from that check: it writes nothing, and a meeting that already
    /// has a cover is the natural one to tune the prompts on.
    private func skipReason(for dir: URL, store: CoverStore) -> String? {
        guard illustrateIsDirectory(dir) else { return "not a directory" }
        guard store.hasSummary(in: dir) else { return "no summary" }
        if !force && !dryRun {
            let state = store.record(in: dir)?.state
            if store.imageURL(in: dir) != nil || state == .skipped || state == .removed {
                return "has a cover — use --force"
            }
        }
        return nil
    }

    /// `--dry-run`: one scene call, the inputs `draw` would use, nothing written.
    private func printScene(for dir: URL, path: String, writer: CoverSceneWriter, fixedStyle: CoverStyle?) async throws {
        let (title, summary) = try CoverDrawing.loadInputs(meetingDir: dir)
        // The drawing's own scene budget, so a hung scene call reads the same here.
        let (scene, _) = try await withTimeout(seconds: CoverDrawing.sceneBudget) {
            try await writer.write(title: title, summary: summary, fixedStyle: fixedStyle, previousScene: nil)
        }
        print("\(path):")
        print("  sensitive: \(scene.sensitive)")
        print("  style: \(scene.style.displayName)")
        print("  scene: \(scene.scene)")
        if !scene.sensitive {
            print("  prompt: \(CoverPrompt.imagePrompt(scene: scene.scene, style: scene.style))")
        }
    }

    /// The one line per meeting (§3.7), e.g. `drew cover.jpg — Illustration ·
    /// OpenRouter google/gemini-3.1-flash-lite-image · 7.4 s · $0.0341`.
    private func describe(
        _ outcome: CoverDrawing.Outcome, in dir: URL, engine: CoverEngine, model: String, store: CoverStore
    ) -> String {
        switch outcome {
        case let .drawn(record):
            let style = record.style.flatMap(CoverStyle.init(rawValue:))?.displayName ?? record.style ?? "?"
            let engineName = engine.takesModel && !model.isEmpty ? "\(engine.displayName) \(model)" : engine.displayName
            let seconds = String(format: "%.1f", record.seconds ?? 0)
            let cost = record.cost.map { String(format: "$%.4f", $0) } ?? "free"
            return "drew cover.jpg — \(style) · \(engineName) · \(seconds) s · \(cost)"
        case .skipped:
            // `draw`'s own rule: the skip is written only when there is no
            // picture. Under --force a meeting that had one keeps it, record
            // and all (§5).
            let written = store.imageURL(in: dir) == nil
            return "skipped — the meeting looked personal " + (written ? "(cover.json: skipped)" : "(the existing cover was kept)")
        }
    }
}

// MARK: - File-private helpers

// `Kleoth.swift`'s helpers are private to that file; these are this file's copies.

/// Prints a message to standard error.
private func illustratePrintError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Errors surfaced directly to the user with a clean message + nonzero exit.
private func illustrateFail(_ message: String) -> Error {
    ValidationError(message)
}

/// The current working directory as a URL, used as the project dir for
/// credential resolution.
private func illustrateCurrentDirectoryURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// Returns true if `url` points at an existing directory.
private func illustrateIsDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return exists && isDir.boolValue
}
