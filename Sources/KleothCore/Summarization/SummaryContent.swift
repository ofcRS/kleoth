import Foundation

/// Placeholder text in a summary answer (2026-11-26): what
/// ``Summarizer/assess(_:transcriptLetters:)`` retries, rejects or cleans away,
/// and what a title must be for ``MeetingNaming/titleToAdopt(generated:replacing:)``.
///
/// The principle: a failed summary is worse than a mediocre one. So only the
/// TL;DR and the overview can cost a retry, only a true placeholder in them can
/// fail the summary, and everything else is cleaned rather than retried:
///
/// - **A true placeholder** (``isPlaceholder(_:)``; TL;DR, overview, title): no
///   letter or digit (`...`, `—`), fewer than three (`x`, `ok`, `N/A`), one
///   letter repeated (`xxx`), a short `<…>` / `{…}` slot, or — as a whole value,
///   case and outer punctuation aside — an echo of the prompt (`string`, a key,
///   `TBD`). Structural first, so it holds in any script; the word list is the
///   second check.
/// - **Terse** (first answer only): real text, but less than the transcript's
///   length leads us to expect (``minimumTLDRLetters(transcriptLetters:)``,
///   ``minimumOverviewLetters(transcriptLetters:)``). It triggers the one retry;
///   it is never a reason to fail, and a terse answer is kept if the retry is
///   worse. A blank overview is never terse: it passes at any length.
/// - **List entries** (``cleaned(_:)``): a task or highlight with no letter or
///   digit, a schema or type echo (`string`, `N/A`, `none`), or a `<…>` / `{…}`
///   slot is dropped, then any speaker left with no highlights; an owner that is
///   a type echo or a slot becomes `unassigned`. "Да", "QA", "1:1", "[смех]" stay.
enum SummaryContent {
    // MARK: - One value

    /// Letters and digits in `text`, in any script — what counts as content.
    static func letterCount<S: StringProtocol>(_ text: S) -> Int {
        text.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }

    /// Fewer letters or digits than this is a placeholder in a TL;DR, an
    /// overview or a title (not in a list entry or a name).
    static let stubLimit = 3

    /// Whether a TL;DR, overview or title is a true placeholder: blank, no
    /// letter or digit, fewer than ``stubLimit``, one letter repeated, a slot,
    /// or an echo of the prompt (``echoes``).
    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.filter { $0.isLetter || $0.isNumber }.lowercased()
        if letters.count < stubLimit { return true }
        if Set(letters).count == 1 { return true }  // "xxx", "ааа", "000"
        return isSlot(trimmed) || isEcho(trimmed, words: echoes)
    }

    /// A short value wrapped whole in `<…>` or `{…}`: a template's slot.
    /// Square brackets are left alone — "[смех]" is how a transcript marks laughter.
    static func isSlot(_ trimmed: String, brackets: [(Character, Character)] = [("<", ">"), ("{", "}")]) -> Bool {
        guard trimmed.count <= 40, let first = trimmed.first, let last = trimmed.last else { return false }
        return brackets.contains { $0.0 == first && $0.1 == last }
    }

    /// Whether `text`, case and outer punctuation aside, is one of `words`.
    static func isEcho(_ text: String, words: Set<String>) -> Bool {
        let core = text.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        return words.contains(core)
    }

    /// The schema's keys, as a whole value.
    static let keys: Set<String> = [
        "title", "tldr", "tl;dr", "overview", "action_items", "per_speaker_highlights",
        "owner", "task", "due", "speaker", "highlights",
    ]

    /// The schema's type words and their null-like kin, as written and as a
    /// model writing Russian may translate them.
    static let typeWords: Set<String> = ["string", "str", "null", "nil", "none", "undefined", "n/a", "н/д", "строка", "placeholder"]

    /// What a TL;DR, overview or title may not be as a whole value: the schema's
    /// words and keys, plus the stock fillers.
    static let echoes: Set<String> = typeWords.union(keys).union(["text", "текст", "summary", "tbd", "todo", "lorem ipsum"])

    /// What an owner may not be: a type word. "None" or "Ян" is an answer.
    static let ownerEchoes: Set<String> = ["string", "str", "null", "nil", "undefined", "строка"]

    /// Whether a task or a highlight is no entry: no letter or digit, a schema
    /// or type echo, or a slot. Short honest entries ("Да", "QA") are entries.
    static func isEmptyEntry(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return letterCount(trimmed) == 0 || isSlot(trimmed) || isEcho(trimmed, words: typeWords.union(keys))
    }

    /// Whether an owner names nobody: no letter or digit, a type word, or a slot
    /// (`[…]` included — names never come in brackets).
    static func isNoOwner(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return letterCount(trimmed) == 0
            || isSlot(trimmed, brackets: [("<", ">"), ("{", "}"), ("[", "]")])
            || isEcho(trimmed, words: ownerEchoes)
    }

    // MARK: - What a meeting leads us to expect

    /// Letters and digits the transcript's speech holds: what the expectations
    /// scale with. About 650–700 a minute of talk in English or Russian.
    static func letters(in transcript: Transcript) -> Int {
        transcript.utterances.reduce(0) { $0 + letterCount($1.text) }
    }

    /// The fewest letters a TL;DR needs before it is terse: one per 2,000
    /// transcript letters, between ``stubLimit`` and 12 (two words, ~35 minutes).
    static func minimumTLDRLetters(transcriptLetters: Int) -> Int {
        min(12, max(stubLimit, transcriptLetters / 2_000))
    }

    /// The fewest letters a non-blank overview needs before it is terse: one per
    /// 300 transcript letters, between ``stubLimit`` and 120 (a sentence or
    /// two, ~50 minutes). An honest overview holds ten times that or more.
    static func minimumOverviewLetters(transcriptLetters: Int) -> Int {
        min(120, max(stubLimit, transcriptLetters / 300))
    }

    // MARK: - A whole answer

    /// How the TL;DR and overview of an answer read.
    struct Judgement: Equatable {
        /// The parts to name in the retry, spelled and ordered as the prompt has
        /// them: true placeholders and terse parts, and `title` when it is a
        /// placeholder beside another part. Empty when the answer is fine.
        var parts: [String] = []
        /// Whether any of them is a true placeholder (not just terse): such an
        /// answer can never be saved.
        var hasPlaceholder = false
    }

    /// Judges the TL;DR and overview — the only parts that can cost a retry. A
    /// nil TL;DR or overview is a missing part, not judged here; a blank
    /// overview passes. `transcriptLetters` 0 judges true placeholders only
    /// (every floor is then ``stubLimit``).
    static func judge(title: String?, tldr: String?, overview: String?, transcriptLetters: Int) -> Judgement {
        var judgement = Judgement()
        func check(_ name: String, _ text: String, minimum: Int) {
            if isPlaceholder(text) {
                judgement.parts.append(name)
                judgement.hasPlaceholder = true
            } else if letterCount(text) < minimum {
                judgement.parts.append(name)
            }
        }
        if let tldr { check("tldr", tldr, minimum: minimumTLDRLetters(transcriptLetters: transcriptLetters)) }
        if let overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            check("overview", overview, minimum: minimumOverviewLetters(transcriptLetters: transcriptLetters))
        }
        if !judgement.parts.isEmpty, let title, isPlaceholder(title) {
            judgement.parts.insert("title", at: 0)
        }
        return judgement
    }

    /// `summary` with what is no content cleaned away: a placeholder title
    /// dropped, empty entries dropped (``isEmptyEntry(_:)``) and then any
    /// speaker left with no highlights, and an owner naming nobody
    /// (``isNoOwner(_:)``) replaced with `unassigned`, the prompt's own word.
    static func cleaned(_ summary: MeetingSummary) -> MeetingSummary {
        var summary = summary
        if let title = summary.title, isPlaceholder(title) { summary.title = nil }
        summary.actionItems = summary.actionItems
            .filter { !isEmptyEntry($0.task) }
            .map { item in
                var item = item
                if isNoOwner(item.owner) { item.owner = "unassigned" }
                return item
            }
        summary.perSpeakerHighlights = summary.perSpeakerHighlights
            .map { SpeakerHighlight(speaker: $0.speaker, highlights: $0.highlights.filter { !isEmptyEntry($0) }) }
            .filter { !$0.highlights.isEmpty }
        return summary
    }
}
