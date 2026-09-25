import Foundation

/// How a dictation fits the text already in the field: where the caret sits, the spaces and the
/// capital letter at the edges of the paste, the paste that keeps a selection, and the check that
/// the polish model did not copy the text around the caret (design 2026-09-24-dictation-context
/// §3.3, §3.4, §3.7).
///
/// Pure, so tests pin the rules and every consumer applies the same ones: the policy classifies the
/// caret with ``boundary(before:)``, `PolishGate` polishes mid-sentence dictations, the insertion
/// plan pastes ``fitted(_:before:after:singleLine:)``, ``insideSelectionWhitespace(_:selection:)``
/// or ``appended(_:to:)``, and the polisher falls back when ``echoesContext(_:before:after:transcript:)``.
///
/// The paste is fitted here rather than left to the model because most dictations reach it
/// without one (short ones and chat messages skip the polish; a failed or cancelled polish pastes
/// the raw transcript), and because the caret may move between the snapshot the model saw and
/// the ⌘V, so even a polished text is fitted again to the live neighbours.
public enum DictationContextFit {
    /// Where the caret sits, judged from the text before it alone.
    public enum Boundary: Sendable, Equatable {
        /// Nothing before the caret, or only spaces.
        case fieldStart
        /// Right after a line break.
        case lineStart
        /// After `.` `!` `?` `…`, optionally followed by closing quotes or brackets.
        case sentenceStart
        /// Anything else: a letter, a digit, a comma, a colon, a dash, an opening quote or bracket.
        case midSentence
    }

    /// Classifies the caret from the text before it (§3.4).
    ///
    /// Trailing spaces are skipped, so the caret after "Done. " still starts a sentence, but a line
    /// break is not a space: a caret on a fresh line starts one. Closing quotes and brackets are
    /// looked through, so `He said "stop."` ends a sentence while `He said "` does not. `“` and `‘`
    /// are looked through too: they close a German or Russian quote (`„Готово.“`), and looking
    /// through one only matters when a sentence end precedes it, where it can only be closing (R11).
    public static func boundary(before: String) -> Boundary {
        var rest = before[...]
        while let last = rest.last, isSpace(last) { rest.removeLast() }
        guard let last = rest.last else { return .fieldStart }
        if last.isNewline { return .lineStart }
        while let last = rest.last, closers.contains(last) { rest.removeLast() }
        if let last = rest.last, sentenceEnds.contains(last) { return .sentenceStart }
        return .midSentence
    }

    /// Whitespace for text going between `before` and `after`; capitalizes at a start; never lowercases.
    ///
    /// The paste would otherwise glue a word to its neighbours or double a space. A space goes
    /// before the text unless the field starts there, the caret already follows whitespace or an
    /// opening bracket or quote, or the text opens with punctuation that attaches to the word before
    /// it (`,` `.` `)` `%`…); a space goes after it only when a word, or a bracket or quote that
    /// only ever opens, follows at once (`word big (see above)`, R10). The first letter is
    /// capitalized at a field, line or sentence start. Nothing is ever lowercased: only a model can
    /// tell a name from the word Scribe capitalized at the start of every dictation. A single-line
    /// field has no lines, so its line breaks become spaces.
    public static func fitted(_ text: String, before: String, after: String, singleLine: Bool) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine { body = collapsingLineBreaks(body) }
        guard let first = body.first else { return "" }
        if boundary(before: before) != .midSentence, first.isLetter, first.isLowercase {
            body = first.uppercased() + body.dropFirst()
        }
        let leading = needsLeadingSpace(first, after: before) ? " " : ""
        let trailing = after.first.map { $0.isLetter || $0.isNumber || openers.contains($0) } == true ? " " : ""
        return leading + body + trailing
    }

    /// The merged text inside the selection's own leading and trailing whitespace (§3.3).
    ///
    /// A selection often has a space or a line break at an edge (a drag past a word, a
    /// triple-clicked line) while the model returns none, so without this the merge would glue
    /// itself to the next word or pull the next line up. A selection that is only whitespace was
    /// separating two things, so the text keeps it on both sides.
    public static func insideSelectionWhitespace(_ text: String, selection: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(selection.prefix(while: \.isWhitespace)) + trimmed + trailingWhitespace(of: selection)
    }

    /// The no-merge paste: the selection unchanged, then the dictation, separated once.
    ///
    /// For a selection that isn't merged (too long, holding a fence delimiter, a provider without
    /// field context, a failed or cancelled polish): ⌘V replaces the selection, so it goes back
    /// first and nothing the user selected is lost. A selection whose text spans lines, like a
    /// list, gets the dictation on a line of its own, ended the way its own lines are (`"\r\n"` or
    /// `"\n"`); anything else gets one space; a dictation opening with punctuation that attaches
    /// to the word before it (`, and more`) gets none. A line break at the selection's edges is not
    /// its text spanning lines: a selection dragged from the end of the previous line is still one
    /// line. The selection's trailing whitespace stays last, so the text after the selection keeps
    /// its separation (R3).
    public static func appended(_ dictation: String, to selection: String) -> String {
        let words = dictation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = words.first else { return selection }
        let trailing = trailingWhitespace(of: selection)
        let core = selection[..<trailing.startIndex]
        guard !core.isEmpty else { return insideSelectionWhitespace(dictation, selection: selection) }
        return String(core) + separator(appending: first, to: core.drop(while: \.isWhitespace)) + words + trailing
    }

    /// A ≥ 40-character run of `before`/`after` in `text` that `transcript` does not hold.
    ///
    /// The echo guard (§3.7): a model shown the text around the caret can copy a sentence of it
    /// into its answer, and the paste would then put that sentence in the field twice. A repeat
    /// the speaker said too is left alone: those are the speaker's words, not the model's. Runs
    /// are compared on lowercased letters and digits only, so a changed case, punctuation or
    /// spacing still counts as a repeat; `DictationDefaults.contextEchoMinimumCharacters` (40) of
    /// them is about a sentence, well past a shared name or term.
    ///
    /// A 40-character run is inside a string exactly when it is one of that string's 40-character
    /// runs, so the check is set lookups: a milliseconds-long pass even for a long merge, where a
    /// substring search per run of the context took most of a second.
    public static func echoesContext(_ text: String, before: String, after: String, transcript: String) -> Bool {
        var alphabet = EchoAlphabet()
        let context = Set(echoRuns(of: alphabet.key(before)) + echoRuns(of: alphabet.key(after)))
        guard !context.isEmpty else { return false }
        let spoken = Set(echoRuns(of: alphabet.key(transcript)))
        return echoRuns(of: alphabet.key(text)).contains { context.contains($0) && !spoken.contains($0) }
    }

    // MARK: - Rules

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    /// Looked through after a sentence end: `"stop."`, `(see above.)`, `«Готово.»`, `„Готово.“` (R11).
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", "“", "‘"]
    /// Brackets and quotes that only ever open (R10, R11).
    private static let openers: Set<Character> = ["(", "[", "{", "«", "„", "‚"]
    /// Quotes that open or close depending on where they stand: the straight ones, and `“` `‘`,
    /// which open an English quote and close a German or Russian one (R4, R11).
    private static let ambiguousQuotes: Set<Character> = ["\"", "'", "“", "‘"]
    /// Closing and terminal punctuation: text starting with one attaches to the word before it.
    /// An opening quote or a dash does not, so it gets its space (R4).
    private static let attachingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”", "’", "%",
    ]

    /// A space, a tab, an NBSP: whitespace that is not a line break.
    private static func isSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    /// Whether text starting with `first` needs a space after `before`.
    private static func needsLeadingSpace(_ first: Character, after before: String) -> Bool {
        guard let last = before.last, !last.isWhitespace else { return false }
        return !endsInOpener(before) && !attachingPunctuation.contains(first)
    }

    /// Whether `text` ends in an opening bracket or quote. An ambiguous quote can go either way
    /// (`He said "` opens, `She said "hi"` closes; `He said “` opens, `„Готово“` closes), so it
    /// opens only after whitespace, another opener, or nothing at all (R4, R11).
    private static func endsInOpener(_ text: String) -> Bool {
        var rest = text[...]
        while let last = rest.last {
            if openers.contains(last) { return true }
            guard ambiguousQuotes.contains(last) else { return false }
            rest.removeLast()
            guard let previous = rest.last else { return true }
            if previous.isWhitespace { return true }
        }
        return false
    }

    /// What goes between a selection's text and the dictation appended to it (R3): nothing before
    /// attaching punctuation, the text's own line ending when it spans lines, else one space.
    private static func separator(appending first: Character, to content: Substring) -> String {
        if attachingPunctuation.contains(first) { return "" }
        // "\r\n" is one Character in Swift, so this finds CRLF line endings and nothing else.
        if content.contains("\r\n" as Character) { return "\r\n" }
        return content.contains(where: \.isNewline) ? "\n" : " "
    }

    /// Every run of whitespace holding a line break becomes one space; other runs stay as they are.
    private static func collapsingLineBreaks(_ text: String) -> String {
        var result = ""
        var run = ""
        for character in text {
            if character.isWhitespace {
                run.append(character)
                continue
            }
            result += run.contains(where: \.isNewline) ? " " : run
            run = ""
            result.append(character)
        }
        return result + (run.contains(where: \.isNewline) ? " " : run)
    }

    /// The whitespace `text` ends with: all of it when `text` is only whitespace.
    private static func trailingWhitespace(of text: String) -> Substring {
        guard let lastVisible = text.lastIndex(where: { !$0.isWhitespace }) else { return text[...] }
        return text[text.index(after: lastVisible)...]
    }

    /// Every run of `DictationDefaults.contextEchoMinimumCharacters` consecutive characters in `key`.
    private static func echoRuns(of key: [Int32]) -> [ArraySlice<Int32>] {
        let length = DictationDefaults.contextEchoMinimumCharacters
        guard key.count >= length else { return [] }
        return (0...(key.count - length)).map { key[$0..<($0 + length)] }
    }

    /// Numbers each distinct character across one echo check, so a run hashes as 40 small
    /// integers rather than 40 `Character`s. Equal characters (canonical equivalence included)
    /// share a number.
    private struct EchoAlphabet {
        private var codes: [Character: Int32] = [:]

        /// `text` as the numbers of its lowercased letters and digits; everything else is dropped.
        mutating func key(_ text: String) -> [Int32] {
            text.lowercased().compactMap { character in
                guard character.isLetter || character.isNumber else { return nil }
                if let code = codes[character] { return code }
                let code = Int32(codes.count)
                codes[character] = code
                return code
            }
        }
    }
}
