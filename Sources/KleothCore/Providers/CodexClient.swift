import Foundation

/// Runs the user's installed Codex CLI headlessly as a chat backend. Summaries
/// only: a trivial call takes ~12 s and ~14k input tokens (measured
/// 2026-09-15), far outside the dictation budget.
///
/// Codex has no system-prompt flag, so the system text leads the stdin
/// prompt; the JSON schema goes through `--output-schema <file>`, written to
/// `scratchDirectory` for the call and deleted afterwards. `-C` points the
/// sandbox at that same scratch directory so nothing of the user's is in scope.
public struct CodexClient: ChatCompleting {
    public static let toolName = "Codex"

    public let executable: URL
    public let runner: any ProcessRunner
    public let environment: [String: String]
    public let scratchDirectory: URL
    public let timeout: TimeInterval

    public init(executable: URL, runner: any ProcessRunner, environment: [String: String], scratchDirectory: URL, timeout: TimeInterval = 600) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.scratchDirectory = scratchDirectory
        self.timeout = timeout
    }

    // MARK: - ChatCompleting

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        var schemaFile: URL?
        if case let .jsonSchema(_, schemaJSON) = responseFormat {
            let file = scratchDirectory.appendingPathComponent("schema-\(UUID().uuidString).json")
            try Data(schemaJSON.utf8).write(to: file)
            schemaFile = file
        }
        defer { if let schemaFile { try? FileManager.default.removeItem(at: schemaFile) } }

        let flat = ChatMessage.flattenForSingleTurn(messages)
        let prompt = Self.prompt(system: flat.system, prompt: flat.prompt, responseFormat: responseFormat)
        let result = try await runner.run(
            executable: executable,
            arguments: Self.arguments(model: model, schemaFile: schemaFile, workingDirectory: scratchDirectory),
            stdin: Data(prompt.utf8), environment: environment, timeout: timeout)
        if result.stdout.isEmpty {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.backend(stderr.isEmpty ? "\(Self.toolName) exited with status \(result.status)." : stderr)
        }
        return try Self.parse(result.stdout)
    }

    // MARK: - Request shaping

    public static func arguments(model: String, schemaFile: URL?, workingDirectory: URL) -> [String] {
        var args = [
            "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "--ephemeral", "--color", "never",
            "-C", workingDirectory.path,
        ]
        if !model.isEmpty { args += ["-m", model] }
        if let schemaFile { args += ["--output-schema", schemaFile.path] }
        args.append("-")
        return args
    }

    public static func prompt(system: String?, prompt: String, responseFormat: OpenRouterResponseFormat) -> String {
        var text = prompt
        if let system, !system.isEmpty { text = system + "\n\n---\n\n" + text }
        if case .jsonObject = responseFormat { text += "\n\nReturn only a JSON object, no prose." }
        return text
    }

    // MARK: - Response parsing

    /// JSONL: the last `item.completed` whose item is an `agent_message` is the
    /// answer; `turn.failed` / `error` lines are failures (their message is
    /// itself a JSON envelope — the inner `error.message` is extracted).
    public static func parse(_ stdout: Data) throws -> ChatCompletion {
        var content: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var failure: String?
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "item.completed":
                if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let text = item["text"] as? String {
                    content = text
                }
            case "turn.completed":
                let usage = object["usage"] as? [String: Any]
                promptTokens = usage?["input_tokens"] as? Int
                completionTokens = usage?["output_tokens"] as? Int
            case "turn.failed":
                let error = object["error"] as? [String: Any]
                failure = innerMessage(error?["message"] as? String) ?? failure
            case "error":
                failure = innerMessage(object["message"] as? String) ?? failure
            default:
                break
            }
        }
        if let failure { throw ProviderError.backend(failure) }
        guard let content else {
            throw ProviderError.backend("\(toolName) returned no answer.")
        }
        return ChatCompletion(
            content: content,
            usage: ChatUsage(promptTokens: promptTokens, completionTokens: completionTokens, cost: nil),
            finishReason: "stop")
    }

    /// `{"type":"error","status":400,"error":{"message":"…"}}` → the inner message;
    /// a plain string is returned as is.
    static func innerMessage(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        return raw
    }
}
