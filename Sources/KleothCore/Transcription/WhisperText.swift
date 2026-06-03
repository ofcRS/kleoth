import Foundation

/// Strips Whisper/WhisperKit special tokens from transcript text.
///
/// WhisperKit segments can carry the model's control tokens inline —
/// `<|startoftranscript|>`, `<|en|>`, `<|transcribe|>`, timestamp tokens like
/// `<|0.00|>`, `<|endoftext|>`, etc. — which are not spoken words and must not
/// reach the rendered transcript. This removes every `<|…|>` token and tidies
/// the surrounding whitespace.
///
/// Pure and deterministic (no I/O): safe to call on arbitrary strings.
public enum WhisperText {
    /// Matches a single special token: `<|`, any run of non-`|` chars, then `|>`.
    /// Compiled once; the pattern is a literal, so construction never fails.
    private static let tokenRegex = try! NSRegularExpression(pattern: "<\\|[^|]*\\|>")

    /// Returns `s` with all `<|…|>` special tokens removed, internal whitespace
    /// runs collapsed to single spaces, and the result trimmed. Yields `""`
    /// when nothing meaningful remains.
    public static func clean(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let stripped = tokenRegex.stringByReplacingMatches(
            in: s, range: range, withTemplate: " "
        )
        return stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
