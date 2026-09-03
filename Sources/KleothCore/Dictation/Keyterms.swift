import Foundation

/// Wire-level sanitizer for Scribe `keyterms` (NOT the storage normalizer —
/// that is `PersonalDictionaryStore.normalize`).
///
/// The personal dictionary may hold up to `DictationDefaults.maxStoredDictionaryTerms`
/// entries; only what survives ``sanitize(_:)`` is ever put on the wire.
public enum Keyterms {
    /// Hard cap on terms SENT. >100 triggers ElevenLabs' 20-second minimum
    /// billable duration per request, which would 2.5× every short dictation.
    public static let maxTerms = 100

    /// Longest accepted term, in characters.
    public static let maxCharacters = 50

    /// Longest accepted term, in whitespace-separated words.
    public static let maxWords = 5

    /// Characters that would confuse the multipart/prompt layers; a term
    /// containing any of them is dropped rather than rewritten.
    static let forbiddenCharacters = CharacterSet(charactersIn: "<>{}[]\\")

    /// Trims each term; drops empties, terms longer than ``maxCharacters``,
    /// terms of more than ``maxWords`` words, and any term containing one of
    /// `< > { } [ ] \`; de-dupes case-insensitively keeping the first-seen
    /// casing; and caps the result at ``maxTerms`` terms.
    public static func sanitize(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for term in raw {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= maxCharacters else { continue }
            guard trimmed.rangeOfCharacter(from: forbiddenCharacters) == nil else { continue }

            let words = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard words.count <= maxWords else { continue }

            // Case-insensitive de-dupe, first-seen casing wins.
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }

            result.append(trimmed)
            if result.count == maxTerms { break }
        }

        return result
    }
}
