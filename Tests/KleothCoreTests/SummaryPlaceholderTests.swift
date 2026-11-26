import Testing
import Foundation
@testable import KleothCore

/// Placeholder text is not a summary (2026-11-26). Two summaries were saved as
/// finished: a 48-minute meeting whose overview was `...` (the rest was real),
/// and one whose title, TL;DR and overview were all `x` — and the `x` then
/// replaced the meeting's title. `assess` asked only for a non-blank TL;DR and
/// a non-null overview.
///
/// The principle of the fix: a failed summary is worse than a mediocre one.
/// Only the TL;DR and the overview can cost a retry; only a true placeholder
/// in them can fail the summary; list entries and the title are cleaned, never
/// retried. Every transcript and answer here is invented.
@Suite struct SummaryPlaceholderTests {
    // MARK: - Fixtures

    /// About 48 minutes of invented Russian talk: 480 turns, ~31,000 letters.
    static func longRussianTranscript() -> Transcript {
        let lines = [
            "Давайте пройдёмся по плану запуска и посмотрим, что осталось сделать до релиза.",
            "Мне кажется, тестирование займёт ещё неделю, если ничего не сломается по дороге.",
            "Хорошо, тогда я возьму на себя документацию и обновлю раздел про установку.",
        ]
        let utterances = (0..<480).map { i in
            Utterance(speakerId: "speaker_\(i % 2)", speakerName: i % 2 == 0 ? "Анна" : "Борис",
                      start: Double(i) * 6, end: Double(i) * 6 + 5.5, text: lines[i % lines.count])
        }
        return Transcript(utterances: utterances, languageCode: "ru", durationSecs: 2880)
    }

    /// Twenty minutes of one channel's silence written out by the speech
    /// model as the same phrase again and again: many letters, nothing said.
    static func fillerTranscript() -> Transcript {
        let utterances = (0..<400).map { i in
            Utterance(speakerId: "speaker_1", speakerName: "Them", start: Double(i) * 3, end: Double(i) * 3 + 2,
                      text: "Продолжение следует...")
        }
        return Transcript(utterances: utterances, languageCode: "ru", durationSecs: 1200)
    }

    /// About twenty seconds of invented English talk.
    static func shortEnglishTranscript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 0, end: 3, text: "Can you hear me?"),
                Utterance(speakerId: "speaker_1", speakerName: "Bob", start: 3.5, end: 6, text: "Yes, loud and clear."),
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 7, end: 12, text: "Great, then we do the demo tomorrow at ten."),
            ],
            languageCode: "en",
            durationSecs: 20
        )
    }

    /// A few seconds of invented Russian talk.
    static func shortRussianTranscript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Анна", start: 0, end: 2, text: "Проверка связи, меня слышно?"),
                Utterance(speakerId: "speaker_1", speakerName: "Борис", start: 2.5, end: 4, text: "Да, всё слышно."),
            ],
            languageCode: "ru",
            durationSecs: 5
        )
    }

    /// An honest overview of the long transcript: two short paragraphs.
    static let longOverview = """
    Анна и Борис прошлись по плану запуска. Борис оценил оставшееся тестирование в неделю, если не всплывут новые ошибки.

    Анна взяла на себя документацию и обновление раздела об установке; дату релиза решили подтвердить после тестов.
    """

    static let longTLDR = "Команда сверила план запуска: неделя на тесты, Анна обновляет документацию."

    /// Real, but far less than 48 minutes of talk lead us to expect.
    static let terseOverview = "Обсудили план запуска."

    /// An answer as JSON text. `title: nil` leaves the key out.
    static func answer(
        title: String? = "План запуска и документация",
        tldr: String = longTLDR,
        overview: String = longOverview,
        actionItems: [[String: Any]] = [["owner": "Анна", "task": "Обновить раздел про установку", "due": NSNull()]],
        highlights: [[String: Any]] = [["speaker": "Борис", "highlights": ["Тестирование займёт ещё неделю"]]]
    ) -> String {
        var object: [String: Any] = [
            "tldr": tldr, "overview": overview,
            "action_items": actionItems, "per_speaker_highlights": highlights,
        ]
        if let title { object["title"] = title }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func reply(_ content: String, finish: String = "stop", cost: Double? = nil) -> Result<ChatCompletion, any Error> {
        .success(ChatCompletion(content: content, usage: cost.map { ChatUsage(cost: $0) }, finishReason: finish))
    }

    struct Run {
        let summary: MeetingSummary?
        let cost: Double?
        let error: (any Error)?
        let calls: [MockChatClient.Call]

        /// How it ended, as a comparable label.
        var ending: String {
            switch error {
            case nil: return "summary"
            case SummarizerError.truncated?: return "truncated"
            case let SummarizerError.incomplete(missing)?: return "incomplete(\(missing.joined(separator: ", ")))"
            case let SummarizerError.placeholder(parts)?: return "placeholder(\(parts.joined(separator: ", ")))"
            case let SummarizerError.invalidJSON(snippet)?: return snippet.isEmpty ? "invalidJSON(empty)" : "invalidJSON"
            case let error?: return "other(\(error))"
            }
        }
    }

    static func run(_ replies: [Result<ChatCompletion, any Error>], transcript: Transcript) async -> Run {
        let client = MockChatClient(results: replies)
        let summarizer = Summarizer(client: client, model: "m")
        let metadata = MeetingMetadata(title: "Recording · Zoom · Nov 26, 10:00", date: "2026-11-26")
        do {
            let (summary, cost) = try await summarizer.summarize(transcript: transcript, metadata: metadata)
            return Run(summary: summary, cost: cost, error: nil, calls: client.calls)
        } catch {
            return Run(summary: nil, cost: nil, error: error, calls: client.calls)
        }
    }

    /// `assess` reduced to a comparable label.
    static func label(_ assessment: Summarizer.Assessment) -> String {
        switch assessment {
        case .complete: return "complete"
        case .cutOff: return "cutOff"
        case .empty: return "empty"
        case let .incomplete(missing, placeholders):
            return "incomplete(\(missing.joined(separator: ", "))"
                + (placeholders.isEmpty ? "" : "; placeholders: \(placeholders.joined(separator: ", "))") + ")"
        case let .placeholder(parts): return "placeholder(\(parts.joined(separator: ", ")))"
        case let .terse(_, parts): return "terse(\(parts.joined(separator: ", ")))"
        case .malformed: return "malformed"
        }
    }

    static func assess(_ content: String, transcriptLetters: Int) -> Summarizer.Assessment {
        Summarizer.assess(ChatCompletion(content: content, finishReason: "stop"), transcriptLetters: transcriptLetters)
    }

    static let longLetters = SummaryContent.letters(in: longRussianTranscript())
    static let shortLetters = SummaryContent.letters(in: shortRussianTranscript())

    /// The retry instruction, written out: what the retry must say, not what
    /// the function under test happens to build.
    static let never = #"never a placeholder such as "x", "...", "N/A", "TBD" or the word "string" — in the same language and the same JSON shape."#
    static let overviewOffer = " If there is too little for an overview, make it an empty string."

    // MARK: - The two real cases

    /// Case 1: a long meeting whose overview is `...`. Asked again fresh (the
    /// placeholder is never replayed), on the same budget, naming the overview.
    @Test func ellipsisOverviewOfALongMeetingIsAskedAgain() async throws {
        let run = await Self.run(
            [Self.reply(Self.answer(overview: "...")), Self.reply(Self.answer())],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.ending == "summary")
        #expect(run.summary?.overview == Self.longOverview)
        try #require(run.calls.count == 2)
        #expect(run.calls[1].maxTokens == run.calls[0].maxTokens)
        #expect(run.calls[1].reasoning == nil)
        let first = run.calls[0].messages, retry = run.calls[1].messages
        try #require(retry.count == 2)
        #expect(retry[0].content == first[0].content)
        #expect(retry[1].content == first[1].content + "\n\n"
            + "Your previous answer had placeholder or very short text in: overview. Answer again with those parts written from what was said in the transcript — "
            + Self.never + Self.overviewOffer)
    }

    @Test func ellipsisOverviewTwiceThrows() async {
        let dots = Self.reply(Self.answer(overview: "…"))
        let run = await Self.run([dots, dots], transcript: Self.longRussianTranscript())
        #expect(run.summary == nil)
        #expect(run.ending == "placeholder(overview)")
        #expect(run.error?.localizedDescription
            == "The summary came back with placeholder text instead of content (overview). Try again, or use another model.")
        #expect(run.calls.count == 2)
    }

    /// Case 2: `x` for the title, TL;DR and overview. The title is named too,
    /// since the answer is asked for again anyway.
    @Test func xForEveryTextPartIsAskedAgainByName() async throws {
        let x = Self.answer(title: "x", tldr: "x", overview: "x", actionItems: [], highlights: [])
        let honest = Self.answer(
            title: "Audio check before the demo",
            tldr: "Alice and Bob checked the audio and set the demo for tomorrow at ten.",
            overview: "", actionItems: [], highlights: []
        )
        let run = await Self.run([Self.reply(x), Self.reply(honest)], transcript: Self.shortEnglishTranscript())
        #expect(run.ending == "summary")
        #expect(run.summary?.title == "Audio check before the demo")
        try #require(run.calls.count == 2)
        #expect(run.calls[1].messages.last?.content.hasSuffix("\n\n"
            + "Your previous answer had placeholder or very short text in: title, tldr, overview. Answer again with those parts written from what was said in the transcript — "
            + Self.never + Self.overviewOffer) == true)
    }

    @Test func xTwiceThrowsNamingEveryPart() async {
        let x = Self.reply(Self.answer(title: "x", tldr: "x", overview: "x", actionItems: [], highlights: []))
        let run = await Self.run([x, x], transcript: Self.longRussianTranscript())
        #expect(run.summary == nil)
        #expect(run.ending == "placeholder(title, tldr, overview)")
        #expect(run.error?.localizedDescription
            == "The summary came back with placeholder text instead of content (title, tldr, overview). Try again, or use another model.")
    }

    /// Only the TL;DR names itself: no overview offer, which would invite the
    /// model to blank a good overview.
    @Test func aTLDRAloneGetsNoOverviewOffer() async throws {
        let run = await Self.run(
            [Self.reply(Self.answer(tldr: "TBD")), Self.reply(Self.answer())],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.ending == "summary")
        try #require(run.calls.count == 2)
        #expect(run.calls[1].messages.last?.content.hasSuffix("\n\n"
            + "Your previous answer had placeholder or very short text in: tldr. Answer again with those parts written from what was said in the transcript — "
            + Self.never) == true)
    }

    // MARK: - After a placeholder, a worse retry still fails

    /// Nothing real came first, so a retry that is no better fails as its own
    /// kind; there is still only one retry.
    @Test func placeholderThenAWorseRetryThrows() async {
        let table: [(retry: Result<ChatCompletion, any Error>, want: String)] = [
            (Self.reply(""), "invalidJSON(empty)"),
            (Self.reply(#"{"tldr":"Команда"#, finish: "length"), "truncated"),
            (Self.reply("Sure! Here is the summary."), "invalidJSON"),
            (Self.reply(Self.answer(overview: "—")), "placeholder(overview)"),
        ]
        for (retry, want) in table {
            let run = await Self.run([Self.reply(Self.answer(overview: "...")), retry], transcript: Self.longRussianTranscript())
            #expect(run.ending == want)
            #expect(run.calls.count == 2)
        }
    }

    /// A cut-off first answer gets the compact retry; a placeholder in that
    /// retry's answer throws.
    @Test func placeholderAfterTheCutOffRetryThrows() async {
        let run = await Self.run(
            [Self.reply(#"{"tldr":"Команда"#, finish: "length"), Self.reply(Self.answer(overview: "..."))],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.ending == "placeholder(overview)")
        #expect(run.calls.count == 2)
    }

    // MARK: - Terse is not a placeholder

    /// The length floors only trigger the retry. A real but terse answer, twice,
    /// is saved: it has every part and real content, so it is not partial.
    @Test func terseTwiceIsSaved() async throws {
        let terse = Self.answer(overview: Self.terseOverview)
        let run = await Self.run(
            [Self.reply(terse, cost: 0.01), Self.reply(terse, cost: 0.02)],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.ending == "summary")
        #expect(run.summary?.overview == Self.terseOverview)
        #expect(abs((run.cost ?? 0) - 0.03) < 1e-9)
        try #require(run.calls.count == 2)
        #expect(run.calls[1].messages.last?.content.hasSuffix("\n\n"
            + "Your previous answer had placeholder or very short text in: overview. Answer again with those parts written from what was said in the transcript — "
            + Self.never + Self.overviewOffer) == true)
    }

    @Test func terseThenRealSavesTheRetry() async {
        let run = await Self.run(
            [Self.reply(Self.answer(overview: Self.terseOverview)), Self.reply(Self.answer())],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.ending == "summary")
        #expect(run.summary?.overview == Self.longOverview)
    }

    /// A real first answer is kept when the retry comes back worse — a
    /// placeholder, nothing, a cut-off, prose, or an error.
    @Test func terseThenWorseSavesTheFirst() async {
        let table: [Result<ChatCompletion, any Error>] = [
            Self.reply(Self.answer(overview: "...")),
            Self.reply(""),
            Self.reply(#"{"tldr":"Команда"#, finish: "length"),
            Self.reply("Sure! Here is the summary."),
            Self.reply(#"{"tldr":"Обсудили план запуска."}"#),
            .failure(OpenRouterError.httpError(status: 500, bodySnippet: "upstream")),
        ]
        for retry in table {
            let run = await Self.run(
                [Self.reply(Self.answer(overview: Self.terseOverview)), retry],
                transcript: Self.longRussianTranscript()
            )
            #expect(run.ending == "summary", "\(retry)")
            #expect(run.summary?.overview == Self.terseOverview, "\(retry)")
            #expect(run.calls.count == 2)
        }
    }

    // MARK: - Missing and placeholder together

    /// An answer with parts missing AND placeholder text where it has parts is
    /// asked again fresh, naming both: replaying `x` would anchor the model on it.
    @Test func incompleteWithPlaceholdersIsAskedFresh() async throws {
        let first = #"{"tldr":"x","overview":"..."}"#
        let run = await Self.run([Self.reply(first), Self.reply(Self.answer())], transcript: Self.longRussianTranscript())
        #expect(run.ending == "summary")
        try #require(run.calls.count == 2)
        let retry = run.calls[1].messages
        try #require(retry.count == 2)
        #expect(retry[1].content == run.calls[0].messages[1].content + "\n\n"
            + "Your previous answer was missing: action_items, per_speaker_highlights, and had placeholder or very short text in: tldr, overview. Answer again with the complete JSON object, every key present, and those parts written from what was said in the transcript — "
            + Self.never + Self.overviewOffer)
    }

    /// Lock: missing parts beside real ones keep the replay repair.
    @Test func incompleteWithRealPartsIsRepaired() async throws {
        let first = #"{"tldr":"Команда сверила план запуска.","overview":""}"#
        let run = await Self.run([Self.reply(first), Self.reply(Self.answer())], transcript: Self.longRussianTranscript())
        #expect(run.ending == "summary")
        try #require(run.calls.count == 2)
        try #require(run.calls[1].messages.count == 4)
        #expect(run.calls[1].messages[2].content == first)
    }

    // MARK: - Honest answers pass first time

    /// Short meetings: a one-sentence TL;DR, an empty or tiny overview, empty
    /// lists, no title — accepted on the first call, in English and Russian.
    @Test func honestShortSummariesPassFirstTime() async {
        let table: [(answer: String, transcript: Transcript)] = [
            (Self.answer(title: nil, tldr: "Alice and Bob checked the audio before the demo.",
                         overview: "", actionItems: [], highlights: []), Self.shortEnglishTranscript()),
            (Self.answer(title: "Проверка связи", tldr: "Проверка связи перед встречей.",
                         overview: "Тест.", actionItems: [], highlights: []), Self.shortRussianTranscript()),
            (Self.answer(title: nil, tldr: "Test.", overview: "", actionItems: [], highlights: []),
             Self.shortRussianTranscript()),
        ]
        for (answer, transcript) in table {
            let run = await Self.run([Self.reply(answer)], transcript: transcript)
            #expect(run.ending == "summary", "\(answer)")
            #expect(run.calls.count == 1, "\(answer)")
        }
    }

    /// A blank overview passes whenever the TL;DR is real, at any length.
    @Test func blankOverviewOfALongMeetingIsAccepted() async {
        let run = await Self.run([Self.reply(Self.answer(overview: ""))], transcript: Self.longRussianTranscript())
        #expect(run.ending == "summary")
        #expect(run.summary?.overview == "")
        #expect(run.calls.count == 1)
    }

    @Test func honestLongSummaryPassesFirstTime() async {
        let run = await Self.run([Self.reply(Self.answer())], transcript: Self.longRussianTranscript())
        #expect(run.ending == "summary")
        #expect(run.summary?.title == "План запуска и документация")
        #expect(run.calls.count == 1)
    }

    /// Twenty minutes of filler: the honest answer says there was almost no
    /// speech. With no overview it passes first time; with a short one it
    /// costs a retry, and the same answer again is saved — never failed.
    @Test func fillerOnlyTranscriptIsSummarizedHonestly() async throws {
        #expect(SummaryContent.letters(in: Self.fillerTranscript()) > 7_000)
        let tldr = "Запись почти без речи: только повторяющаяся фраза."

        let blank = await Self.run([Self.reply(Self.answer(title: nil, tldr: tldr, overview: "", actionItems: [], highlights: []))],
                                   transcript: Self.fillerTranscript())
        #expect(blank.ending == "summary")
        #expect(blank.calls.count == 1)

        let short = Self.reply(Self.answer(title: nil, tldr: tldr, overview: "Речи почти нет.", actionItems: [], highlights: []))
        let twice = await Self.run([short, short], transcript: Self.fillerTranscript())
        #expect(twice.ending == "summary")
        #expect(twice.summary?.overview == "Речи почти нет.")
        #expect(twice.calls.count == 2)
    }

    // MARK: - How much a meeting needs (the retry trigger)

    @Test func expectationsScaleWithTheTranscript() {
        #expect(Self.longLetters > 25_000)
        #expect(Self.shortLetters < 100)
        let table: [(content: String, letters: Int, want: String)] = [
            (Self.answer(overview: "Итоги встречи."), Self.longLetters, "terse(overview)"),
            (Self.answer(overview: "Итоги встречи."), Self.shortLetters, "complete"),
            (Self.answer(overview: ""), Self.longLetters, "complete"),
            (Self.answer(overview: "  "), Self.shortLetters, "complete"),
            (Self.answer(overview: "Ок."), Self.shortLetters, "placeholder(overview)"),   // under 3: a placeholder at any length
            (Self.answer(tldr: "Бюджет."), Self.longLetters, "terse(tldr)"),
            (Self.answer(tldr: "Бюджет."), Self.shortLetters, "complete"),
            (Self.answer(tldr: "Обсудили бюджет."), Self.longLetters, "complete"),
            (Self.answer(tldr: "x", overview: "Итоги встречи."), Self.longLetters, "placeholder(tldr, overview)"),
            (Self.answer(), Self.longLetters, "complete"),
            (Self.answer(overview: "Итоги встречи."), 0, "complete"),                     // 0 = placeholders only
        ]
        for (content, letters, want) in table {
            #expect(Self.label(Self.assess(content, transcriptLetters: letters)) == want, "\(content) @ \(letters)")
        }
    }

    // MARK: - List entries: cleaned, never retried

    /// Entries are dropped only when they hold no letter or digit, echo the
    /// schema (or say N/A), or are a `<…>` / `{…}` slot. A speaker left with no
    /// highlights goes; an echoed owner becomes "unassigned". Short honest
    /// entries stay.
    @Test func listEntriesAreCleanedNotRetried() throws {
        let content = Self.answer(
            actionItems: [
                ["owner": "Анна", "task": "QA", "due": NSNull()],
                ["owner": "Ян", "task": "Да", "due": NSNull()],
                ["owner": "None", "task": "1:1 с Борисом", "due": NSNull()],
                ["owner": "null", "task": "Позвонить юристу", "due": NSNull()],
                ["owner": "<owner>", "task": "Обновить смету", "due": NSNull()],
                ["owner": "[Имя]", "task": "Забронировать зал", "due": NSNull()],
                ["owner": "—", "task": "Разослать запись", "due": NSNull()],
                ["owner": "string", "task": "string", "due": NSNull()],
                ["owner": "Анна", "task": "...", "due": NSNull()],
                ["owner": "Анна", "task": "{task}", "due": NSNull()],
            ],
            highlights: [
                ["speaker": "Борис", "highlights": ["[смех]", "N/A", "Неделя на тесты"]],
                ["speaker": "Them", "highlights": ["N/A"]],
                ["speaker": "Ли", "highlights": []],
                ["speaker": "string", "highlights": ["string"]],
            ]
        )
        guard case let .complete(summary) = Self.assess(content, transcriptLetters: Self.longLetters) else {
            Issue.record("expected the answer to be kept")
            return
        }
        #expect(summary.actionItems.map(\.task)
            == ["QA", "Да", "1:1 с Борисом", "Позвонить юристу", "Обновить смету", "Забронировать зал", "Разослать запись"])
        #expect(summary.actionItems.map(\.owner)
            == ["Анна", "Ян", "None", "unassigned", "unassigned", "unassigned", "unassigned"])
        try #require(summary.perSpeakerHighlights.count == 1)
        #expect(summary.perSpeakerHighlights[0].speaker == "Борис")
        #expect(summary.perSpeakerHighlights[0].highlights == ["[смех]", "Неделя на тесты"])
    }

    /// A silent speaker the model listed with "N/A": the answer is saved on the
    /// first call, without that speaker.
    @Test func silentSpeakerIsDroppedAndTheAnswerKept() async {
        let run = await Self.run(
            [Self.reply(Self.answer(highlights: [
                ["speaker": "Анна", "highlights": ["Возьмёт документацию"]],
                ["speaker": "Them", "highlights": ["N/A"]],
            ]))],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.ending == "summary")
        #expect(run.calls.count == 1)
        #expect(run.summary?.perSpeakerHighlights.map(\.speaker) == ["Анна"])
    }

    /// Missing parts are still asked for first.
    @Test func missingPartsComeFirst() {
        #expect(Self.label(Self.assess(#"{"tldr":"x"}"#, transcriptLetters: Self.shortLetters))
            == "incomplete(overview, action_items, per_speaker_highlights; placeholders: tldr)")
        #expect(Self.label(Self.assess(#"{"tldr":"Короткий созвон."}"#, transcriptLetters: Self.shortLetters))
            == "incomplete(overview, action_items, per_speaker_highlights)")
    }

    /// The TL;DR / overview / title test.
    @Test func placeholderTable() {
        let placeholders = [
            "", "   ", "...", "…", "—", "-", "?!", "x", "X.", "ok", "N/A", "н/д", "Q3",
            "TBD", "todo", "string", "String.", "\"string\"", "строка", "null", "None", "lorem ipsum",
            "<tldr>", "{{title}}", "[overview]", "<краткое содержание>", "tl;dr", "TL;DR:", "Overview",
            "xxx", "Ааа", "...!...",
        ]
        for text in placeholders {
            #expect(SummaryContent.isPlaceholder(text), "\(text)")
        }
        let content = [
            "Test", "Тест", "Launch on June 10.", "Запуск 10 июня.", "1:1 sync", "Обсудили бюджет.",
            "TBD items were reviewed first.", "None of the dates worked.", "[WIP] Roadmap review",
            "Строка в договоре", "会议纪要", "[смех]",
        ]
        for text in content {
            #expect(!SummaryContent.isPlaceholder(text), "\(text)")
        }
    }

    // MARK: - The title

    /// Title is optional: a placeholder title alone never costs a retry, but it
    /// is dropped from the summary (covers read the summary's title first).
    @Test func placeholderTitleAloneIsDroppedNotRetried() async {
        let run = await Self.run([Self.reply(Self.answer(title: "x"))], transcript: Self.longRussianTranscript())
        #expect(run.ending == "summary")
        #expect(run.calls.count == 1)
        #expect(run.summary?.title == nil)
    }

    @Test func titleToAdoptTable() {
        let placeholder = "Recording · Zoom · Nov 26, 10:00"
        let table: [(generated: String?, current: String, want: String?)] = [
            ("План запуска и документация", placeholder, "План запуска и документация"),
            ("  Q4 hiring plan  ", "Meeting 2026-11-26", "Q4 hiring plan"),
            ("Q4 hiring plan", "", "Q4 hiring plan"),
            ("Q4 hiring plan", "x", "Q4 hiring plan"),                         // the "x" an earlier run saved
            ("Q4 hiring plan", "xxx", "Q4 hiring plan"),
            ("Q4 hiring plan", "...", "Q4 hiring plan"),
            ("x", placeholder, nil),
            ("...", placeholder, nil),
            ("string", placeholder, nil),
            ("<title>", placeholder, nil),
            ("Meeting 2026-11-26", placeholder, nil),                         // a placeholder of our own
            (nil, placeholder, nil),
            ("   ", placeholder, nil),
            ("Q4 hiring plan", "Weekly sync with Acme", nil),                 // a calendar event's name stays
            ("Q4 hiring plan", "Бюджет на 2027", nil),                        // so does one the user typed
            ("Q4 hiring plan", "QA", nil),                                    // short, but a title
            ("Q4 hiring plan", "1:1", nil),
        ]
        for (generated, current, want) in table {
            #expect(MeetingNaming.titleToAdopt(generated: generated, replacing: current) == want,
                    "\(generated ?? "nil") over \(current)")
        }
    }

    // MARK: - Prompt and copy

    /// The cut-off retry asks for a shorter overview — never for a stub. Its
    /// old wording ("a shorter overview and fewer highlights") had no floor.
    @Test func compactRetryText() {
        #expect(Summarizer.compactRetryInstruction
            == #"Your previous answer was cut off before the JSON was complete. Answer again, more compactly — a shorter overview and fewer highlights, but still real content from the transcript, never a placeholder such as "..." — in the same language and the same JSON shape."#)
    }

    /// The first request rules placeholders out and offers the honest way out
    /// for a meeting with little in it — both of which `assess` accepts.
    @Test func firstRequestGivesAnHonestWayOut() async throws {
        let run = await Self.run([Self.reply(Self.answer())], transcript: Self.longRussianTranscript())
        let system = try #require(run.calls.first?.messages.first?.content)
        #expect(system.hasSuffix("\n"
            + #"Never write a placeholder such as "x", "...", "N/A" or "string" for any value. If the transcript is too short for an overview, make the overview an empty string; if there is nothing to summarize, say so in the tldr."#))
    }
}
