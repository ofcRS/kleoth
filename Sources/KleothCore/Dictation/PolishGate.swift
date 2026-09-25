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
///
/// With field context (design 2026-09-24-dictation-context §3.8) two more
/// dictations need the model whatever their length: a selection to merge, and
/// a short one continuing a sentence.
public enum PolishGate {
    public enum Decision: Equatable, Sendable {
        case polish
        /// `reason` is user-facing (Dictations detail pane), never on the pill.
        case skip(reason: String)
    }

    /// Where the dictation goes, as far as the gate cares — ``placement(for:)`` makes one from a
    /// field context.
    public enum Placement: Sendable, Equatable {
        /// No field context, or none that changes the rules (a replaced selection): today's gate.
        case none
        /// At a caret, or after an appended selection: mid-sentence, only the model can continue the
        /// sentence (a lowercase first word, no final period before the rest of it).
        case cursor(DictationContextFit.Boundary)
        /// A selection to merge: only the model can merge it with the dictation.
        case selection
        /// A terminal selection, a spelling reference: today's gate — it is no place in a sentence.
        case reference
    }

    /// In order: a selection to merge polishes (any app, any length, the toggle irrelevant); the
    /// "Also clean up short dictations" toggle polishes; a chat app skips; a caret mid-sentence
    /// polishes; under `DictationDefaults.minimumWordsToPolish` words skips; anything else polishes.
    /// The skip reasons are today's whatever the placement, and `.none` (the default) is today's gate.
    public static func decide(
        rawText: String, style: AppStyle, alwaysPolish: Bool, placement: Placement = .none
    ) -> Decision {
        if placement == .selection { return .polish }
        if alwaysPolish { return .polish }
        if style == .chat {
            return .skip(reason: "Pasted as heard — messages into chat apps skip the clean-up pass.")
        }
        if placement == .cursor(.midSentence) { return .polish }
        if wordCount(rawText) < DictationDefaults.minimumWordsToPolish {
            return .skip(reason: "Pasted as heard — dictations under \(DictationDefaults.minimumWordsToPolish) words skip the clean-up pass.")
        }
        return .polish
    }

    /// The gate's view of a field context: a merge is a selection; an appended selection is a caret
    /// at its end, since the model writes only the dictation, as if typed there; a replaced
    /// selection, which couldn't be read, and no context at all are `.none`; a caret keeps its
    /// boundary; a terminal's selection is a reference.
    ///
    /// Takes the policy's context, not the prompt's, which is nil for a provider without field
    /// context and for an append whose text would carry a fence delimiter: the selection is still
    /// there, and its verdict still decides the gate.
    public static func placement(for context: DictationFieldContext?) -> Placement {
        guard let context else { return .none }
        switch (context.placement, context.verdict) {
        case (.cursor, _):
            return .cursor(context.boundary)
        case (.reference, _):
            return .reference
        case (.selection, .merge):
            return .selection
        case (.selection, .append):
            // `boundary` is the selection's start; the caret is at its end.
            return .cursor(DictationContextFit.boundary(before: context.before + context.selection))
        case (.selection, .replace):
            return .none
        }
    }

    /// Whitespace-separated tokens. Cyrillic words are longer than Latin ones
    /// in characters but not in count, so a word threshold treats both alike.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
