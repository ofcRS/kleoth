import Foundation

/// Placeholder text in a summary answer: what ``Summarizer/assess(_:transcriptLetters:)``
/// rejects as no content, and what a model's title must not be to name a meeting
/// (``MeetingNaming/titleToAdopt(generated:replacing:)``).
///
/// The test is structural first, so it holds in any script: a value with no
/// letter or digit (`...`, `…`, `—`), one with fewer than three (`x`, `ok`,
/// `N/A`), one letter repeated (`xxx`), or a short value wrapped in template
/// brackets (`<tldr>`, `{{title}}`, `[overview]`). A short list of echoes is
/// checked on top, only ever against the whole value: the schema's own words
/// (`string`, also as a model writing Russian may translate it), its keys, and
/// stock fillers (`TBD`, `none`).
///
/// What the TL;DR and overview must hold grows with the transcript: a three-letter
/// overview of a 48-minute meeting is a stub, of a twenty-second one it may be all
/// there is (see ``minimumTLDRLetters(transcriptLetters:)``,
/// ``minimumOverviewLetters(transcriptLetters:)``, ``blankOverviewLimit``).
enum SummaryContent {
    // MARK: - One value

    /// Letters and digits in `text`, in any script — what counts as content.
    static func letterCount<S: StringProtocol>(_ text: S) -> Int {
        text.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }

    /// Fewer letters or digits than this is a stub, whatever else the value holds.
    static let stubLimit = 3

    /// Whether `text` is a placeholder rather than content: blank, no letter or
    /// digit, fewer than ``stubLimit``, one character repeated, or an echo
    /// (``isEcho(_:)``). Not for names (an owner or a speaker may be "Ян").
    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.filter { $0.isLetter || $0.isNumber }.lowercased()
        if letters.count < stubLimit { return true }
        if Set(letters).count == 1 { return true }  // "xxx", "ааа", "000"
        return isEcho(trimmed)
    }

    /// Whether `text`, as a whole, is a template slot or an echo of the prompt:
    /// a short value in `<…>`, `{…}` or `[…]`, or — case and surrounding
    /// punctuation aside — one of `words`.
    static func isEcho(_ text: String, words: Set<String> = echoes) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 40, let first = trimmed.first, let last = trimmed.last,
           [("<", ">"), ("{", "}"), ("[", "]")].contains(where: { $0.0 == first && $0.1 == last }) {
            return true
        }
        let core = trimmed.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        return words.contains(core)
    }

    /// Whole values that are an echo of the prompt rather than content.
    static let echoes: Set<String> = [
        // The schema's own words, as written and as translated into Russian.
        "string", "str", "text", "null", "nil", "none", "undefined", "строка", "текст",
        // Its keys.
        "title", "tldr", "tl;dr", "overview", "summary", "action_items", "per_speaker_highlights",
        // Stock fillers.
        "tbd", "todo", "placeholder", "lorem ipsum",
    ]

    /// The echoes a NAME may not be (an owner, a speaker): only the schema's
    /// type words. "None" or "unassigned" for an owner is an honest answer.
    static let nameEchoes: Set<String> = ["string", "str", "null", "nil", "undefined", "строка"]

    // MARK: - What a meeting needs

    /// Letters and digits the transcript's speech holds: what the expectations
    /// scale with. About 700 a minute of talk in English or Russian.
    static func letters(in transcript: Transcript) -> Int {
        transcript.utterances.reduce(0) { $0 + letterCount($1.text) }
    }

    /// Below this many transcript letters — about two minutes of talk — the
    /// overview may be blank (the 2026-09-24 rule's ten-second recording).
    static let blankOverviewLimit = 1_500

    /// The fewest letters a TL;DR needs: one per 2,000 transcript letters,
    /// between ``stubLimit`` and 12 (about two words, reached near 35 minutes).
    static func minimumTLDRLetters(transcriptLetters: Int) -> Int {
        min(12, max(stubLimit, transcriptLetters / 2_000))
    }

    /// The fewest letters a non-blank overview needs: one per 300 transcript
    /// letters, between ``stubLimit`` and 120 (a sentence or two, reached near
    /// 50 minutes). An honest overview holds ten times that or more.
    static func minimumOverviewLetters(transcriptLetters: Int) -> Int {
        min(120, max(stubLimit, transcriptLetters / 300))
    }

    // MARK: - A whole summary

    /// The parts of `summary` holding placeholder text, spelled and ordered as
    /// the prompt has them. `title` is optional, so it is named only beside
    /// another part (the answer is asked for again anyway); a placeholder title
    /// alone is dropped, not retried.
    static func placeholderParts(in summary: MeetingSummary, transcriptLetters: Int) -> [String] {
        var parts: [String] = []

        let tldr = summary.tldr.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPlaceholder(tldr) || letterCount(tldr) < minimumTLDRLetters(transcriptLetters: transcriptLetters) {
            parts.append("tldr")
        }

        let overview = summary.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if overview.isEmpty {
            if transcriptLetters >= blankOverviewLimit { parts.append("overview") }
        } else if isPlaceholder(overview)
                    || letterCount(overview) < minimumOverviewLetters(transcriptLetters: transcriptLetters) {
            parts.append("overview")
        }

        if summary.actionItems.contains(where: { isPlaceholder($0.task) || isEcho($0.owner, words: nameEchoes) }) {
            parts.append("action_items")
        }
        if summary.perSpeakerHighlights.contains(where: { entry in
            isEcho(entry.speaker, words: nameEchoes) || entry.highlights.contains(where: isPlaceholder)
        }) {
            parts.append("per_speaker_highlights")
        }

        if !parts.isEmpty, let title = summary.title, isPlaceholder(title) {
            parts.insert("title", at: 0)
        }
        return parts
    }
}
