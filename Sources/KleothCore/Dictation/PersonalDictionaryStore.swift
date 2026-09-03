import Foundation

/// The personal dictionary — `~/.config/kleoth/dictionary.json`, a plain JSON
/// array of strings — that biases speech recognition toward the user's names,
/// products and jargon.
///
/// Storage normalization (this type) is deliberately looser than the wire-level
/// sanitizer: up to `DictationDefaults.maxStoredDictionaryTerms` entries are
/// kept here, while only the first `Keyterms.maxTerms` survive
/// `Keyterms.sanitize` and are actually sent with a request (ElevenLabs applies
/// a 20-second minimum billable duration above 100 keyterms).
public struct PersonalDictionaryStore: Sendable {
    /// `~/.config/kleoth/dictionary.json`, next to `config.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("kleoth", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    public let url: URL

    public init(url: URL = PersonalDictionaryStore.defaultURL) {
        self.url = url
    }

    /// The stored terms, normalized. Fail-soft: a missing, unreadable or
    /// malformed file reads as empty, and a mixed array keeps only its strings
    /// (a hand-edited file with a stray number still works).
    public func load() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let terms = try? JSONDecoder().decode([String].self, from: data) {
            return Self.normalize(terms)
        }
        // Lenient second pass: skip non-string elements rather than losing the
        // whole file to one bad entry.
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let elements = any as? [Any] else { return [] }
        return Self.normalize(elements.compactMap { $0 as? String })
    }

    /// Normalizes and writes the terms, creating `~/.config/kleoth/` if needed.
    public func save(_ terms: [String]) throws {
        let normalized = Self.normalize(terms)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(normalized)
        try data.write(to: url, options: .atomic)
    }

    /// Trims each term, drops empties, de-dupes case-insensitively (the first
    /// spelling wins, so "Kleoth" beats a later "kleoth"), and caps the list at
    /// `DictationDefaults.maxStoredDictionaryTerms`.
    public static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == DictationDefaults.maxStoredDictionaryTerms { break }
        }
        return result
    }

    /// Parses the Settings text editor's contents: one term per line,
    /// tolerating CRLF line endings and blank lines.
    public static func parse(text: String) -> [String] {
        normalize(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Renders terms back into the editor's one-per-line form.
    public static func render(_ terms: [String]) -> String {
        terms.joined(separator: "\n")
    }
}
