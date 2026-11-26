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

    /// Line breaks and control/format characters (Unicode Cc and Cf: tab, NUL,
    /// zero-width and bidi-override characters). A hand-edited `dictionary.json`
    /// can carry them; inside a term they would break the one-line prompt
    /// layouts (polish, summary) and never match speech, so such a term is
    /// dropped. Leading and trailing ones are trimmed first, like spaces.
    static let lineBreaksAndControlCharacters = CharacterSet.newlines.union(.controlCharacters)

    /// Trims each term; drops empties, terms longer than ``maxCharacters``,
    /// terms of more than ``maxWords`` words, any term containing one of
    /// `< > { } [ ] \`, and any term containing a line break or a control or
    /// format character; de-dupes case-insensitively keeping the first-seen
    /// casing; and caps the result at ``maxTerms`` terms.
    public static func sanitize(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for term in raw {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= maxCharacters else { continue }
            guard trimmed.rangeOfCharacter(from: forbiddenCharacters) == nil else { continue }
            guard trimmed.rangeOfCharacter(from: lineBreaksAndControlCharacters) == nil else { continue }

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
