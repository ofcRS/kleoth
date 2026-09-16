import Testing
import Foundation
@testable import KleothCore

@Suite struct ClaudeCodeClientTests {
    static let ok = #"{"duration_api_ms":1500,"stop_reason":"end_turn","session_id":"x","total_cost_usd":0.0027,"usage":{"input_tokens":1111,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9},"is_error":false,"num_turns":1,"subtype":"success","result":"{\"word\":\"ok\"}","structured_output":{"word":"ok"},"type":"result"}"#
    static let notLoggedIn = #"{"duration_api_ms":0,"stop_reason":"stop_sequence","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"is_error":true,"num_turns":1,"subtype":"success","result":"Not logged in · Please run /login","type":"result"}"#
    static let plainText = #"{"stop_reason":"end_turn","is_error":false,"subtype":"success","result":"Hello there","usage":{"input_tokens":5,"output_tokens":2},"type":"result"}"#
    static let truncated = #"{"stop_reason":"max_tokens","is_error":false,"subtype":"success","result":"{\"tldr\":\"cut","usage":{"input_tokens":5,"output_tokens":2},"type":"result"}"#

    static let schema = #"{"type":"object","properties":{"word":{"type":"string"}},"required":["word"]}"#

    func client(_ runner: MockProcessRunner) -> ClaudeCodeClient {
        ClaudeCodeClient(executable: URL(fileURLWithPath: "/fake/claude"), runner: runner,
                         environment: ["HOME": "/Users/test"], timeout: 42)
    }

    @Test func argumentsIsolateTheSessionAndPassSchema() {
        let args = ClaudeCodeClient.arguments(
            model: "haiku", responseFormat: .jsonSchema(name: "w", schemaJSON: Self.schema), systemPrompt: "Be terse.")
        #expect(args == [
            "-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--model", "haiku", "--system-prompt", "Be terse.", "--json-schema", Self.schema,
        ])
    }

    @Test func argumentsOmitEmptyModelAndSystem() {
        let args = ClaudeCodeClient.arguments(model: "", responseFormat: .none, systemPrompt: nil)
        #expect(!args.contains("--model"))
        #expect(!args.contains("--system-prompt"))
        #expect(!args.contains("--json-schema"))
    }

    @Test func jsonObjectFormatAppendsAnInstructionToThePrompt() {
        let prompt = ClaudeCodeClient.prompt(for: "Summarize.", responseFormat: .jsonObject)
        #expect(prompt == "Summarize.\n\nReturn only a JSON object, no prose.")
        #expect(ClaudeCodeClient.prompt(for: "Hi", responseFormat: .none) == "Hi")
    }

    @Test func structuredOutputIsReserializedAsContent() throws {
        let completion = try ClaudeCodeClient.parse(Data(Self.ok.utf8))
        #expect(completion.content == #"{"word":"ok"}"#)
        #expect(completion.finishReason == "stop")
        #expect(completion.usage?.promptTokens == 1111)
        #expect(completion.usage?.completionTokens == 9)
        #expect(completion.usage?.cost == nil)
    }

    @Test func resultTextIsContentWithoutASchema() throws {
        let completion = try ClaudeCodeClient.parse(Data(Self.plainText.utf8))
        #expect(completion.content == "Hello there")
    }

    @Test func maxTokensBecomesLength() throws {
        #expect(try ClaudeCodeClient.parse(Data(Self.truncated.utf8)).finishReason == "length")
    }

    @Test func notLoggedInIsNotSignedIn() {
        #expect(throws: ProviderError.notSignedIn(tool: "Claude Code")) {
            _ = try ClaudeCodeClient.parse(Data(Self.notLoggedIn.utf8))
        }
    }

    @Test func otherErrorsCarryTheResultText() {
        let body = #"{"is_error":true,"result":"Rate limit reached","type":"result"}"#
        #expect(throws: ProviderError.backend("Rate limit reached")) {
            _ = try ClaudeCodeClient.parse(Data(body.utf8))
        }
    }

    @Test func garbageIsABackendError() {
        #expect(throws: ProviderError.self) { _ = try ClaudeCodeClient.parse(Data("not json".utf8)) }
    }

    @Test func completeSpawnsWithPromptOnStdin() async throws {
        let runner = MockProcessRunner(stdout: Self.ok)
        let completion = try await client(runner).complete(
            messages: [ChatMessage(role: "system", content: "Sys"), ChatMessage(role: "user", content: "Say ok")],
            model: "haiku", responseFormat: .jsonSchema(name: "w", schemaJSON: Self.schema),
            maxTokens: 100, temperature: 0.2, reasoning: nil)
        #expect(completion.content == #"{"word":"ok"}"#)
        let call = try #require(runner.calls.first)
        #expect(call.executable.path == "/fake/claude")
        #expect(call.stdinText == "Say ok")
        #expect(call.arguments.contains("--system-prompt"))
        #expect(call.environment["HOME"] == "/Users/test")
        #expect(call.timeout == 42)
    }

    @Test func nonZeroExitWithEmptyStdoutReportsStderr() async {
        let runner = MockProcessRunner(results: [.success(ProcessResult(
            stdout: Data(), stderr: Data("boom\n".utf8), status: 1))])
        await #expect(throws: ProviderError.backend("boom")) {
            _ = try await client(runner).complete(
                messages: [ChatMessage(role: "user", content: "x")], model: "haiku",
                responseFormat: .none, maxTokens: 10, temperature: nil, reasoning: nil)
        }
    }
}
