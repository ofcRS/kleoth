import Testing
import Foundation
@testable import KleothCore

@Suite struct CodexClientTests {
    static let ok = """
    {"type":"thread.started","thread_id":"01a0"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"word\\":\\"ok\\"}"}}
    {"type":"turn.completed","usage":{"input_tokens":13760,"cached_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":0}}
    """
    static let refusedModel = """
    {"type":"thread.started","thread_id":"01a0"}
    {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `gpt-5-mini` not found."}}
    {"type":"turn.started"}
    {"type":"error","message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account.\\"}}"}
    {"type":"turn.failed","error":{"message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account.\\"}}"}}
    """

    static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kleoth-codex-tests", isDirectory: true)

    func client(_ runner: MockProcessRunner) -> CodexClient {
        CodexClient(executable: URL(fileURLWithPath: "/fake/codex"), runner: runner,
                    environment: ["HOME": "/Users/test"], scratchDirectory: Self.scratch, timeout: 42)
    }

    @Test func argumentsAreHeadlessAndSandboxed() {
        let schema = URL(fileURLWithPath: "/tmp/s.json")
        let args = CodexClient.arguments(model: "o3", schemaFile: schema, workingDirectory: URL(fileURLWithPath: "/tmp/w"))
        #expect(args == [
            "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "--ephemeral", "--color", "never",
            "-C", "/tmp/w", "-m", "o3", "--output-schema", "/tmp/s.json", "-",
        ])
        let noModel = CodexClient.arguments(model: "", schemaFile: nil, workingDirectory: URL(fileURLWithPath: "/tmp/w"))
        #expect(!noModel.contains("-m"))
        #expect(!noModel.contains("--output-schema"))
        #expect(noModel.last == "-")
    }

    @Test func promptLeadsWithTheSystemText() {
        let text = CodexClient.prompt(system: "Be terse.", prompt: "Summarize.", responseFormat: .none)
        #expect(text == "Be terse.\n\n---\n\nSummarize.")
        let json = CodexClient.prompt(system: nil, prompt: "Hi", responseFormat: .jsonObject)
        #expect(json == "Hi\n\nReturn only a JSON object, no prose.")
    }

    @Test func lastAgentMessageIsTheContent() throws {
        let completion = try CodexClient.parse(Data(Self.ok.utf8))
        #expect(completion.content == #"{"word":"ok"}"#)
        #expect(completion.usage?.promptTokens == 13760)
        #expect(completion.usage?.completionTokens == 15)
        #expect(completion.finishReason == "stop")
    }

    @Test func turnFailedIsABackendErrorWithTheInnerMessage() {
        #expect(throws: ProviderError.backend("The 'gpt-5-mini' model is not supported when using Codex with a ChatGPT account.")) {
            _ = try CodexClient.parse(Data(Self.refusedModel.utf8))
        }
    }

    @Test func noAgentMessageIsAnError() {
        let body = #"{"type":"thread.started","thread_id":"x"}"# + "\n" + #"{"type":"turn.completed","usage":{}}"#
        #expect(throws: ProviderError.self) { _ = try CodexClient.parse(Data(body.utf8)) }
    }

    @Test func completeWritesTheSchemaFileAndCleansUp() async throws {
        let runner = MockProcessRunner(stdout: Self.ok)
        let completion = try await client(runner).complete(
            messages: [ChatMessage(role: "system", content: "Sys"), ChatMessage(role: "user", content: "Say ok")],
            model: "", responseFormat: .jsonSchema(name: "w", schemaJSON: #"{"type":"object"}"#),
            maxTokens: 10, temperature: nil, reasoning: nil)
        #expect(completion.content == #"{"word":"ok"}"#)
        let call = try #require(runner.calls.first)
        #expect(call.stdinText == "Sys\n\n---\n\nSay ok")
        let schemaIndex = try #require(call.arguments.firstIndex(of: "--output-schema"))
        let schemaPath = call.arguments[schemaIndex + 1]
        #expect(schemaPath.hasPrefix(Self.scratch.path))
        #expect(!FileManager.default.fileExists(atPath: schemaPath))   // deleted after the call
        #expect(call.arguments[call.arguments.firstIndex(of: "-C")! + 1] == Self.scratch.path)
    }
}
