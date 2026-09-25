import Foundation
import Testing
@testable import KleothCore

/// Codex as the cover engine (design doc 2026-09-24 §4.1, §5): `codex exec`
/// headless with the /gpt-images wrapper on stdin, the PNG picked up from
/// `<CODEX_HOME>/generated_images/<thread>/` and that folder removed. Every
/// test gets its own temporary CODEX_HOME and scratch folder; no test spawns
/// a real `codex`.
@Suite struct CodexImageClientTests {
    static let started = #"{"type":"thread.started","thread_id":"t1"}"#
    static let completed = #"{"type":"turn.completed","usage":{}}"#
    /// `CodexClientTests.refusedModel`'s `turn.failed` line, wrapped the same way.
    static let failed = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"You've hit your usage limit.\"}}"}}"#

    /// An `item.completed` `agent_message` line whose text is `text`.
    static func message(_ text: String) throws -> String {
        let line: [String: Any] = [
            "type": "item.completed",
            "item": ["id": "item_0", "type": "agent_message", "text": text],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self)
    }

    /// A `thread.started` line for `id`, JSON-escaped (a raw NUL would make
    /// the line invalid JSON, which the walk skips, and prove nothing).
    static func started(_ id: String) throws -> String {
        let line: [String: Any] = ["type": "thread.started", "thread_id": id]
        return String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self)
    }

    static func jsonl(_ lines: String...) -> String { lines.joined(separator: "\n") }

    /// `<tmp>/kleoth-codex-image-tests-<uuid>` as CODEX_HOME, and a scratch folder beside it.
    let codexHome: URL
    let scratch: URL

    init() {
        let name = "kleoth-codex-image-tests-\(UUID().uuidString)"
        codexHome = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-scratch", isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: codexHome)
        try? FileManager.default.removeItem(at: scratch)
    }

    func client(_ runner: MockProcessRunner, timeout: TimeInterval = 240) -> CodexImageClient {
        CodexImageClient(executable: URL(fileURLWithPath: "/fake/codex"), runner: runner,
                         environment: ["HOME": "/Users/test"], scratchDirectory: scratch,
                         codexHome: codexHome, timeout: timeout)
    }

    /// `<codexHome>/generated_images/<thread>/`, created.
    func threadFolder(_ thread: String = "t1") throws -> URL {
        let dir = codexHome.appendingPathComponent("generated_images/\(thread)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func argumentsAreHeadlessReadOnlyAndEndWithStdin() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/w")
        #expect(CodexImageClient.arguments(workingDirectory: workingDirectory, ephemeral: false) == [
            "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "--color", "never", "-C", "/tmp/w", "-",
        ])
        let ephemeral = CodexImageClient.arguments(workingDirectory: workingDirectory, ephemeral: true)
        let readOnly = ephemeral.firstIndex(of: "read-only")
        #expect(readOnly != nil)
        #expect(readOnly.map { ephemeral[$0 + 1] } == "--ephemeral")
        #expect(ephemeral.last == "-")
        #expect(CodexImageClient.arguments(workingDirectory: workingDirectory)
            == CodexImageClient.arguments(workingDirectory: workingDirectory, ephemeral: CodexImageClient.usesEphemeral))
    }

    @Test func wrapperHoldsTheImagePromptVerbatim() {
        let text = CodexImageClient.prompt(imagePrompt: "An otter naps.")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("Use the built-in image_gen tool exactly once to generate one image, then stop."))
        #expect(lines.contains("Do not read, create or edit any files. Do not run shell commands. Do not use any other tool."))
        #expect(lines.contains("- Output size: 1024x1024 (or the closest the tool supports)."))
        #expect(text.contains("\n\nAn otter naps.\n\n"))
        #expect(text.hasSuffix("As your final message output ONLY the absolute path of the generated PNG file, nothing else."))
        #expect(!text.contains("transparent"))
        #expect(!text.contains("Image 1"))
    }

    @Test func newestPNGInTheThreadFolderIsReturnedAndTheFolderRemoved() async throws {
        defer { cleanUp() }
        let folder = try threadFolder()
        let old = folder.appendingPathComponent("a.png")
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: folder.appendingPathComponent("b.png"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: old.path)
        let runner = MockProcessRunner(stdout: Self.jsonl(Self.started, try Self.message("/nowhere"), Self.completed))

        let image = try await client(runner, timeout: 42).generate(prompt: "p", model: "")

        #expect(image.data == Data("new".utf8))
        #expect(image.cost == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let call = try #require(runner.calls.first)
        #expect(call.arguments == CodexImageClient.arguments(workingDirectory: scratch))
        #expect(call.stdinText == CodexImageClient.prompt(imagePrompt: "p"))
        #expect(call.timeout == 42)
        #expect(call.environment["CODEX_HOME"] == codexHome.path)
    }

    @Test func finalMessagePathIsTheFallback() async throws {
        defer { cleanUp() }
        let elsewhere = codexHome.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let png = elsewhere.appendingPathComponent("cover.png")
        try Data("fallback".utf8).write(to: png)
        let runner = MockProcessRunner(stdout: Self.jsonl(try Self.message(png.path), Self.completed))

        let image = try await client(runner).generate(prompt: "p", model: "")

        #expect(image.data == Data("fallback".utf8))
        #expect(image.cost == nil)
    }

    /// Only a regular file is a picture: a folder named in the last message
    /// is no image, not a Foundation "couldn't be opened" error.
    @Test func aFolderInTheLastMessageIsNoImage() async throws {
        defer { cleanUp() }
        let folder = codexHome.appendingPathComponent("elsewhere/cover.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let generator = client(MockProcessRunner(stdout: Self.jsonl(try Self.message(folder.path), Self.completed)))

        await #expect(throws: CoverError.noImage) {
            _ = try await generator.generate(prompt: "p", model: "")
        }
    }

    @Test func turnFailedIsABackendErrorWithTheInnerMessage() async throws {
        defer { cleanUp() }
        let generator = client(MockProcessRunner(stdout: Self.jsonl(Self.started, Self.failed)))

        await #expect(throws: ProviderError.backend("You've hit your usage limit.")) {
            _ = try await generator.generate(prompt: "p", model: "")
        }
    }

    @Test func noPNGIsNoImage() async throws {
        defer { cleanUp() }
        let folder = try threadFolder()
        let generator = client(MockProcessRunner(stdout: Self.jsonl(Self.started, try Self.message("done"), Self.completed)))

        await #expect(throws: CoverError.noImage) {
            _ = try await generator.generate(prompt: "p", model: "")
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func emptyStdoutIsABackendErrorFromStderr() async throws {
        defer { cleanUp() }
        let runner = MockProcessRunner(results: [.success(ProcessResult(stdout: Data(), stderr: Data("boom".utf8), status: 1))])
        let generator = client(runner)

        await #expect(throws: ProviderError.backend("boom")) {
            _ = try await generator.generate(prompt: "p", model: "")
        }
    }

    /// A turn can fail after image_gen already saved its picture; the thread
    /// folder still goes (§5: never leave one behind).
    @Test func aFailedTurnStillRemovesTheThreadFolder() async throws {
        defer { cleanUp() }
        let folder = try threadFolder()
        try Data("drawn".utf8).write(to: folder.appendingPathComponent("a.png"))
        let generator = client(MockProcessRunner(stdout: Self.jsonl(Self.started, Self.failed)))

        await #expect(throws: ProviderError.backend("You've hit your usage limit.")) {
            _ = try await generator.generate(prompt: "p", model: "")
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// The thread id names a folder that gets deleted, so an id that would
    /// reach outside `generated_images/<thread>/` deletes nothing. The ids are
    /// chosen so that even a broken guard stays inside this test's CODEX_HOME:
    /// `""` and `"\u{0}"` (URL drops the NUL) → `generated_images/`,
    /// `".."` → CODEX_HOME, `"other/"` → a sibling's folder.
    @Test func aThreadIDThatLeavesItsFolderDeletesNothing() async throws {
        defer { cleanUp() }
        for id in ["", "..", "other/", "\u{0}"] {
            let theirs = try threadFolder("other").appendingPathComponent("a.png")
            try Data("theirs".utf8).write(to: theirs)
            let generator = client(MockProcessRunner(stdout: Self.jsonl(
                try Self.started(id), try Self.message("done"), Self.completed)))

            await #expect(throws: CoverError.noImage, "thread_id \(id.debugDescription)") {
                _ = try await generator.generate(prompt: "p", model: "")
            }
            #expect(FileManager.default.fileExists(atPath: theirs.path), "thread_id \(id.debugDescription)")
        }
    }

    /// The allowlist still admits what Codex really sends: a UUID names the
    /// folder the picture is read from, and that folder is removed.
    @Test func aUUIDThreadIDNamesTheFolderThatIsReadAndRemoved() async throws {
        defer { cleanUp() }
        let id = "01a0d4d9-999e-7513-9e2d-1d000abdf49e"
        let folder = try threadFolder(id)
        try Data("drawn".utf8).write(to: folder.appendingPathComponent("exec-66dabb6f.png"))
        let generator = client(MockProcessRunner(stdout: Self.jsonl(
            try Self.started(id), try Self.message("/nowhere"), Self.completed)))

        let image = try await generator.generate(prompt: "p", model: "")

        #expect(image.data == Data("drawn".utf8))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("generated_images").path))
    }
}
