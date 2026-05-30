import Testing
import Foundation
@testable import KleothCore

@Suite struct CredentialsTests {
    /// Creates a throwaway project directory containing a `.env` file and
    /// returns its URL. Caller is responsible for removing it (via `defer`).
    private func makeProjectDir(envContents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-creds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let envURL = dir.appendingPathComponent(".env")
        try Data(envContents.utf8).write(to: envURL)
        return dir
    }

    private var processEnv: [String: String] { ProcessInfo.processInfo.environment }

    /// True when the running process already defines an ElevenLabs key, in
    /// which case `resolve()` honors it over any `.env` file. That value may be
    /// a real secret, so tests must not assert on it.
    private var envOverridesEleven: Bool {
        processEnv["ELEVEN_API_KEY"] != nil || processEnv["ELEVENLABS_API_KEY"] != nil
    }

    // MARK: - resolve() reads a project .env

    @Test func resolvePicksUpElevenKeyFromProjectDirDotEnv() throws {
        // A clearly-fake sentinel value, generated per-run. This is NOT a real
        // key, so asserting on its value is safe.
        let sentinel = "sk_test_eleven_\(UUID().uuidString)"
        let projectDir = try makeProjectDir(envContents: "ELEVEN_API_KEY=\(sentinel)\n")
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let creds = Credentials.resolve(projectDir: projectDir)

        // The process environment always wins over the file. When it defines a
        // key, that value is a real secret we must never assert on, so only do
        // the strict equality check when the environment does not define it.
        if envOverridesEleven {
            #expect(creds.elevenLabsKey != nil)
        } else {
            #expect(creds.elevenLabsKey == sentinel)
        }
    }

    @Test func resolveParsesQuotedAndExportedValues() throws {
        let sentinel = "sk_test_eleven_\(UUID().uuidString)"
        let contents = """
        # a comment line
        export ELEVEN_API_KEY="\(sentinel)"
        """
        let projectDir = try makeProjectDir(envContents: contents)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let creds = Credentials.resolve(projectDir: projectDir)

        if envOverridesEleven {
            #expect(creds.elevenLabsKey != nil)
        } else {
            // `export ` prefix is stripped and surrounding quotes are removed.
            #expect(creds.elevenLabsKey == sentinel)
        }
    }

    @Test func resolveAcceptsAlternateElevenKeyName() throws {
        let sentinel = "sk_test_alt_\(UUID().uuidString)"
        let projectDir = try makeProjectDir(envContents: "ELEVENLABS_API_KEY=\(sentinel)\n")
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let creds = Credentials.resolve(projectDir: projectDir)

        if envOverridesEleven {
            #expect(creds.elevenLabsKey != nil)
        } else {
            #expect(creds.elevenLabsKey == sentinel)
        }
    }

    // MARK: - parseDotenv helper (no environment interaction)

    @Test func parseDotenvIgnoresCommentsAndBlankLinesAndStripsQuotes() throws {
        let projectDir = try makeProjectDir(envContents: """

        # comment
        ELEVEN_API_KEY = 'quoted-value'

        OPENROUTER_API_KEY=plain-value
        """)
        defer { try? FileManager.default.removeItem(at: projectDir) }
        let envURL = projectDir.appendingPathComponent(".env")

        let parsed = try #require(Credentials.parseDotenv(at: envURL))
        #expect(parsed["ELEVEN_API_KEY"] == "quoted-value")
        #expect(parsed["OPENROUTER_API_KEY"] == "plain-value")
    }

    @Test func parseDotenvReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-nonexistent-\(UUID().uuidString)/.env")
        #expect(Credentials.parseDotenv(at: missing) == nil)
    }

    @Test func stripSurroundingQuotesHandlesBothQuoteStyles() {
        #expect(Credentials.stripSurroundingQuotes("\"abc\"") == "abc")
        #expect(Credentials.stripSurroundingQuotes("'abc'") == "abc")
        #expect(Credentials.stripSurroundingQuotes("abc") == "abc")
        // Mismatched quotes are left untouched.
        #expect(Credentials.stripSurroundingQuotes("\"abc'") == "\"abc'")
    }
}
