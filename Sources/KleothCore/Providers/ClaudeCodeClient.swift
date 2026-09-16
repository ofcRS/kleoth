import Foundation

/// Runs the user's own installed Claude Code binary in print mode as a chat
/// backend. Kleoth never sees a token: the binary signs in on its own.
///
/// Every call is isolated from the user's Claude Code setup — no settings, no
/// MCP servers, no tools, no session file — because those otherwise ride
/// along as ~150k cached input tokens per call (measured 2026-09-15: 7 s and
/// 154k tokens with the defaults vs 1.7 s and 1.1k tokens isolated).
public struct ClaudeCodeClient: ChatCompleting {
    public static let toolName = "Claude Code"

    public let executable: URL
    public let runner: any ProcessRunner
    public let environment: [String: String]
    /// Ceiling for one call. Summaries can take minutes on a long transcript;
    /// the dictation polisher wraps its call in its own 30 s budget anyway.
    public let timeout: TimeInterval

    public init(executable: URL, runner: any ProcessRunner, environment: [String: String], timeout: TimeInterval = 600) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    // MARK: - ChatCompleting

    public func complete(
        messages: [ChatMessage], model: String, responseFormat: OpenRouterResponseFormat,
        maxTokens: Int, temperature: Double?, reasoning: OpenRouterReasoning?
    ) async throws -> ChatCompletion {
        let flat = ChatMessage.flattenForSingleTurn(messages)
        let arguments = Self.arguments(model: model, responseFormat: responseFormat, systemPrompt: flat.system)
        let prompt = Self.prompt(for: flat.prompt, responseFormat: responseFormat)
        let result = try await runner.run(
            executable: executable, arguments: arguments, stdin: Data(prompt.utf8),
            environment: environment, timeout: timeout)
        if result.stdout.isEmpty {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.backend(stderr.isEmpty ? "\(Self.toolName) exited with status \(result.status)." : stderr)
        }
        return try Self.parse(result.stdout)
    }

    // MARK: - Request shaping

    /// The argument list. `--tools ""` disables every tool, `--setting-sources ""`
    /// skips the user's settings/CLAUDE.md, `--strict-mcp-config` with an empty
    /// config loads no MCP server, `--system-prompt` REPLACES Claude Code's own
    /// (coding-assistant) system prompt with ours.
    public static func arguments(model: String, responseFormat: OpenRouterResponseFormat, systemPrompt: String?) -> [String] {
        var args = [
            "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        ]
        if !model.isEmpty { args += ["--model", model] }
        if let systemPrompt, !systemPrompt.isEmpty { args += ["--system-prompt", systemPrompt] }
        if case let .jsonSchema(_, schemaJSON) = responseFormat { args += ["--json-schema", schemaJSON] }
        return args
    }

    /// The stdin prompt. A plain `json_object` request has no flag, so the
    /// instruction is appended in words.
    public static func prompt(for prompt: String, responseFormat: OpenRouterResponseFormat) -> String {
        if case .jsonObject = responseFormat {
            return prompt + "\n\nReturn only a JSON object, no prose."
        }
        return prompt
    }

    // MARK: - Response parsing

    private struct Output: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
        }
        let isError: Bool?
        let result: String?
        let stopReason: String?
        let usage: Usage?
    }

    /// `structured_output` (a schema was given) is re-serialized as the
    /// content; otherwise `result`. `is_error` becomes a `ProviderError`.
    public static func parse(_ stdout: Data) throws -> ChatCompletion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let output = try? decoder.decode(Output.self, from: stdout),
              let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            let text = String(decoding: stdout.prefix(300), as: UTF8.self)
            throw ProviderError.backend("\(toolName) returned unreadable output: \(text)")
        }
        if output.isError == true {
            let message = output.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(toolName) failed."
            if message.localizedCaseInsensitiveContains("not logged in") {
                throw ProviderError.notSignedIn(tool: toolName)
            }
            throw ProviderError.backend(message)
        }
        let content: String
        if let structured = object["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            content = String(decoding: data, as: UTF8.self)
        } else {
            content = output.result ?? ""
        }
        let finish = output.stopReason == "max_tokens" ? "length" : "stop"
        let usage = ChatUsage(promptTokens: output.usage?.inputTokens, completionTokens: output.usage?.outputTokens, cost: nil)
        return ChatCompletion(content: content, usage: usage, finishReason: finish)
    }
}
