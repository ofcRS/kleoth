import Foundation

/// API credentials resolved from the environment / project configuration.
public struct Credentials: Sendable {
    public var elevenLabsKey: String?
    public var openRouterKey: String?

    public init(elevenLabsKey: String? = nil, openRouterKey: String? = nil) {
        self.elevenLabsKey = elevenLabsKey
        self.openRouterKey = openRouterKey
    }

    /// Resolves credentials, in order of precedence:
    ///
    /// 1. Process environment (`ELEVEN_API_KEY` / `ELEVENLABS_API_KEY`,
    ///    `OPENROUTER_API_KEY`).
    /// 2. A dotenv file at `projectDir/.env`, then at the current working
    ///    directory's `.env` — filling only keys still missing.
    /// 3. `~/.config/kleoth/config.json` — filling only keys still missing.
    ///
    /// Key *values* are never logged or printed.
    public static func resolve(
        projectDir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Credentials {
        let env = ProcessInfo.processInfo.environment

        var elevenLabsKey = env["ELEVEN_API_KEY"] ?? env["ELEVENLABS_API_KEY"]
        var openRouterKey = env["OPENROUTER_API_KEY"]

        // 2. dotenv files (env always wins; only fill what's missing).
        if elevenLabsKey == nil || openRouterKey == nil {
            var dotenvPaths = [projectDir.appendingPathComponent(".env")]
            let cwdEnv = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env")
            if cwdEnv.standardizedFileURL != dotenvPaths[0].standardizedFileURL {
                dotenvPaths.append(cwdEnv)
            }

            for path in dotenvPaths {
                guard elevenLabsKey == nil || openRouterKey == nil else { break }
                guard let parsed = parseDotenv(at: path) else { continue }
                if elevenLabsKey == nil {
                    elevenLabsKey = parsed["ELEVEN_API_KEY"] ?? parsed["ELEVENLABS_API_KEY"]
                }
                if openRouterKey == nil {
                    openRouterKey = parsed["OPENROUTER_API_KEY"]
                }
            }
        }

        // 3. config.json (only fill what's still missing).
        if elevenLabsKey == nil || openRouterKey == nil {
            let config = loadConfigJSON()
            if elevenLabsKey == nil {
                elevenLabsKey = config["eleven_api_key"] ?? config["elevenlabs_api_key"]
            }
            if openRouterKey == nil {
                openRouterKey = config["openrouter_api_key"]
            }
        }

        return Credentials(elevenLabsKey: elevenLabsKey, openRouterKey: openRouterKey)
    }

    // MARK: - dotenv parsing

    /// Parses a dotenv file into a key/value dictionary. Lines may have an
    /// optional leading `export `, blank lines and `#` comments are ignored,
    /// and surrounding single or double quotes are stripped from values.
    /// Returns `nil` only when the file cannot be read.
    static func parseDotenv(at url: URL) -> [String: String]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            value = stripSurroundingQuotes(value)
            result[key] = value
        }
        return result
    }

    /// Removes a single matched pair of surrounding single or double quotes.
    static func stripSurroundingQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else {
            return value
        }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - config.json

    /// Loads `~/.config/kleoth/config.json` as a flat `[String: String]` of the
    /// string-valued entries; non-string values are ignored.
    static func loadConfigJSON() -> [String: String] {
        let url = configURL()
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                result[key] = string
            }
        }
        return result
    }

    static func configURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("kleoth", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}
