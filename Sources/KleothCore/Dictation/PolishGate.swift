import Foundation

/// Decides whether a dictation is worth the one polish call (design §10.3 item 8).
///
/// Scribe v2 with `no_verbatim` already returns punctuated, filler-light text,
/// so for a short utterance — or any message into a chat app — the LLM pass
/// mostly adds ~1 s of latency and a chance of an unwanted rewrite. The
/// polisher earns its keep on long, rambling, structure-hungry input (a
/// brainstorm spoken into an AI chat or an editor), so that is what still goes
/// through it. Pure and deterministic over stored fields, so the Dictations
/// detail pane can recompute the reason for an old row.
public enum PolishGate {
    public enum Decision: Equatable, Sendable {
        case polish
        /// `reason` is user-facing (Dictations detail pane), never on the pill.
        case skip(reason: String)
    }

    public static func decide(rawText: String, style: AppStyle, alwaysPolish: Bool) -> Decision {
        if alwaysPolish { return .polish }
        if style == .chat {
            return .skip(reason: "Pasted as heard — messages into chat apps skip the clean-up pass.")
        }
        if wordCount(rawText) < DictationDefaults.minimumWordsToPolish {
            return .skip(reason: "Pasted as heard — dictations under \(DictationDefaults.minimumWordsToPolish) words skip the clean-up pass.")
        }
        return .polish
    }

    /// Whitespace-separated tokens. Cyrillic words are longer than Latin ones
    /// in characters but not in count, so a word threshold treats both alike.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
