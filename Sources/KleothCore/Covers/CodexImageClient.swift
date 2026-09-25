import Foundation

/// Draws a cover with Codex's built-in `image_gen` tool (GPT Image over the
/// user's ChatGPT login; design doc 2026-09-24 §4.1). Free per image, but it
/// counts against the plan's limits and takes about 50 s.
///
/// Codex is an agent, not an image API, so it gets the /gpt-images wrapper on
/// stdin: call `image_gen` exactly once, touch no files, answer with the PNG's
/// path. `image_gen` saves the picture under
/// `<CODEX_HOME>/generated_images/<thread>/` and never deletes it, so the
/// client reads the newest PNG there and removes the thread folder, whatever
/// the outcome — a cover must never leave a copy in the user's Codex home (§5).
/// `-C` points the read-only sandbox at `scratchDirectory`, so nothing of the
/// user's is in scope.
///
/// Failures (§5): Codex's own `turn.failed` / `error` message (a usage limit,
/// say) is `ProviderError.backend`, verbatim; a run that ends without a PNG is
/// `CoverError.noImage`; the runner's `ProviderError.timedOut` and
/// cancellation pass through as is.
public struct CodexImageClient: CoverImageGenerating {
    /// Whether `--ephemeral` is passed. The PNG still lands in
    /// `generated_images/<thread>/` under it, and Codex then keeps no session
    /// transcript of the cover prompt; the thread folder is left behind either
    /// way, so `generate` removes it.
    public static let usesEphemeral = true   // .scratch/cover-spike/RESULTS.md §3: "PNG lands: yes", 0 session files

    public let executable: URL
    public let runner: any ProcessRunner
    public let environment: [String: String]
    public let scratchDirectory: URL
    /// Where Codex keeps `generated_images/`. Passed to the child as
    /// `CODEX_HOME`, so the client and Codex always agree on the folder.
    public let codexHome: URL
    public let timeout: TimeInterval

    public init(
        executable: URL, runner: any ProcessRunner, environment: [String: String],
        scratchDirectory: URL, codexHome: URL, timeout: TimeInterval = 240
    ) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.scratchDirectory = scratchDirectory
        self.codexHome = codexHome
        self.timeout = timeout
    }

    // MARK: - CoverImageGenerating

    /// Runs one `codex exec` and returns the PNG it drew; `cost` is always nil
    /// (the plan pays). `model` is ignored: Codex draws with its own
    /// `image_gen` tool and has no image model to pick.
    public func generate(prompt: String, model: String) async throws -> GeneratedImage {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        var env = environment
        env["CODEX_HOME"] = codexHome.path
        let result = try await runner.run(
            executable: executable,
            arguments: Self.arguments(workingDirectory: scratchDirectory),
            stdin: Data(Self.prompt(imagePrompt: prompt).utf8), environment: env, timeout: timeout)
        if result.stdout.isEmpty {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.backend(
                stderr.isEmpty ? "\(CodexClient.toolName) exited with status \(result.status)." : stderr)
        }

        let output = Output(result.stdout)
        let threadDir = output.thread.map { codexHome.appendingPathComponent("generated_images/\($0)", isDirectory: true) }
        // Before any failure is thrown: a turn can fail after image_gen already
        // saved into the folder, and it must not stay behind either (§5).
        defer { if let threadDir { try? FileManager.default.removeItem(at: threadDir) } }
        let parsed = try output.checked()

        var produced = threadDir.flatMap(Self.newestPNG(in:))
        // The fallback must name a regular file: a folder would surface as a
        // Foundation "couldn't be opened" error, and a FIFO or device would
        // block the read. Anything else is simply no image.
        if produced == nil, let path = parsed.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.hasPrefix("/"),
           (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            produced = URL(fileURLWithPath: path)
        }
        guard let produced else { throw CoverError.noImage }
        return GeneratedImage(data: try Data(contentsOf: produced), cost: nil)
    }

    // MARK: - Request shaping

    /// `exec --json --skip-git-repo-check -s read-only [--ephemeral] --color never -C <dir> -`:
    /// headless, JSONL events on stdout, a read-only sandbox rooted at `workingDirectory`, the
    /// prompt on stdin. No `-m`: `image_gen` is a tool of whatever model Codex runs.
    public static func arguments(workingDirectory: URL, ephemeral: Bool = CodexImageClient.usesEphemeral) -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "-s", "read-only"]
        if ephemeral { args.append("--ephemeral") }
        args += ["--color", "never", "-C", workingDirectory.path, "-"]
        return args
    }

    /// The /gpt-images wrapper (`gpt-images.ts` `wrap()`) for a square, opaque
    /// job with no reference images. The image prompt goes in verbatim — only
    /// trimmed, as `wrap()` trims — between the instructions that keep the
    /// agent to one `image_gen` call and a bare path as its answer.
    public static func prompt(imagePrompt: String) -> String {
        [
            "Use the built-in image_gen tool exactly once to generate one image, then stop.",
            "Do not read, create or edit any files. Do not run shell commands. Do not use any other tool.",
            "Do not ask questions; if something is ambiguous, follow the prompt as written.",
            "",
            "Requirements:",
            "- Output size: 1024x1024 (or the closest the tool supports).",
            "",
            "Image prompt (follow it verbatim; do not add subjects, text or props):",
            "",
            imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "As your final message output ONLY the absolute path of the generated PNG file, nothing else.",
        ].joined(separator: "\n")
    }

    // MARK: - Response parsing

    /// The newest `.png` directly in `directory` by modification date; nil
    /// when there is none or the folder does not exist.
    static func newestPNG(in directory: URL) -> URL? {
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [key], options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .map { (url: $0, date: (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast) }
            .max { $0.date < $1.date }?.url
    }

    /// The JSONL `codex exec --json` printed, walked once: the `thread.started`
    /// id (it names the `generated_images` folder), the last `agent_message`
    /// text (the path, the fallback) and the inner message of any
    /// `turn.failed` / `error` line. Failures are collected rather than thrown,
    /// so `generate` learns the thread folder even from a failed turn;
    /// `checked()` then throws `ProviderError.backend` with the message.
    ///
    /// This walk copies `CodexClient.parse` rather than sharing it: the
    /// provider types are read-only on this branch (design doc §4.1).
    private struct Output {
        var thread: String?
        var lastMessage: String?
        var failure: String?

        init(_ stdout: Data) {
            for line in stdout.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = object["type"] as? String else { continue }
                switch type {
                case "thread.started":
                    thread = (object["thread_id"] as? String).flatMap(Self.folderName) ?? thread
                case "item.completed":
                    if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                       let text = item["text"] as? String {
                        lastMessage = text
                    }
                case "turn.failed":
                    let error = object["error"] as? [String: Any]
                    failure = CodexClient.innerMessage(error?["message"] as? String) ?? failure
                case "error":
                    failure = CodexClient.innerMessage(object["message"] as? String) ?? failure
                default:
                    break
                }
            }
        }

        func checked() throws -> (thread: String?, lastMessage: String?) {
            if let failure { throw ProviderError.backend(failure) }
            return (thread, lastMessage)
        }

        /// A thread id is a UUID, and the folder it names gets deleted, so only
        /// letters, digits, `-` and `_` are let through. An allowlist, not a
        /// deny-list: `URL` silently drops a NUL, so `"\u{0}"` would otherwise
        /// name `generated_images/` itself, and `""`, `..` or a `/` would
        /// reach further still.
        private static func folderName(_ id: String) -> String? {
            let isSafe = !id.isEmpty && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
            return isSafe ? id : nil
        }
    }
}
