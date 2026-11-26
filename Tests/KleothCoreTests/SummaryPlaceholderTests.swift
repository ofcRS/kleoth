import Testing
import Foundation
@testable import KleothCore

/// Placeholder text is not a summary (2026-11-26). Two summaries were saved as
/// finished: a 48-minute meeting whose overview was `...` (the rest was real),
/// and one whose title, TL;DR and overview were all `x` — and the `x` then
/// replaced the meeting's title. `assess` asked only for a non-blank TL;DR and
/// a non-null overview. Every transcript and answer here is invented.
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

    static func reply(_ content: String, finish: String = "stop") -> Result<ChatCompletion, any Error> {
        .success(ChatCompletion(content: content, finishReason: finish))
    }

    struct Run {
        let summary: MeetingSummary?
        let error: (any Error)?
        let calls: [MockChatClient.Call]

        /// The parts a `.placeholder` error named; nil for any other ending.
        var placeholderParts: [String]? {
            if case let SummarizerError.placeholder(parts)? = error { return parts }
            return nil
        }
    }

    static func run(_ replies: [Result<ChatCompletion, any Error>], transcript: Transcript) async -> Run {
        let client = MockChatClient(results: replies)
        let summarizer = Summarizer(client: client, model: "m")
        let metadata = MeetingMetadata(title: "Recording · Zoom · Nov 26, 10:00", date: "2026-11-26")
        do {
            let (summary, _) = try await summarizer.summarize(transcript: transcript, metadata: metadata)
            return Run(summary: summary, error: nil, calls: client.calls)
        } catch {
            return Run(summary: nil, error: error, calls: client.calls)
        }
    }

    /// `assess` reduced to a comparable label.
    static func label(_ assessment: Summarizer.Assessment) -> String {
        switch assessment {
        case .complete: return "complete"
        case .cutOff: return "cutOff"
        case .empty: return "empty"
        case let .incomplete(missing): return "incomplete(\(missing.joined(separator: ", ")))"
        case let .placeholder(parts): return "placeholder(\(parts.joined(separator: ", ")))"
        case .malformed: return "malformed"
        }
    }

    static func assess(_ content: String, transcriptLetters: Int) -> String {
        label(Summarizer.assess(ChatCompletion(content: content, finishReason: "stop"), transcriptLetters: transcriptLetters))
    }

    // MARK: - The two real cases

    /// Case 1: a long meeting whose overview is `...`. Asked again fresh (the
    /// placeholder is never replayed), on the same budget, naming the overview;
    /// a long meeting gets no "may be empty" way out.
    @Test func ellipsisOverviewOfALongMeetingIsAskedAgain() async throws {
        let run = await Self.run(
            [Self.reply(Self.answer(overview: "...")), Self.reply(Self.answer())],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.error == nil)
        #expect(run.summary?.overview == Self.longOverview)
        try #require(run.calls.count == 2)
        #expect(run.calls[1].maxTokens == run.calls[0].maxTokens)
        #expect(run.calls[1].reasoning == nil)
        let first = run.calls[0].messages, retry = run.calls[1].messages
        try #require(retry.count == 2)
        #expect(retry[0].content == first[0].content)
        #expect(retry[1].content.hasPrefix(first[1].content))
        let instruction = Summarizer.placeholderRetryInstruction(parts: ["overview"], overviewMayBeBlank: false)
        #expect(retry[1].content.hasSuffix(instruction))
        #expect(instruction.contains("overview"))
        #expect(!instruction.contains("empty string"))
    }

    @Test func ellipsisOverviewTwiceThrows() async {
        let dots = Self.reply(Self.answer(overview: "…"))
        let run = await Self.run([dots, dots], transcript: Self.longRussianTranscript())
        #expect(run.summary == nil)
        #expect(run.placeholderParts == ["overview"])
        #expect(run.calls.count == 2)
    }

    /// Case 2: `x` for the title, TL;DR and overview. Even a short meeting
    /// gets no TL;DR of one letter; the title is asked for too since the
    /// answer is asked again anyway, and a short meeting may leave the
    /// overview empty rather than fill it.
    @Test func xForEveryTextPartIsAskedAgainByName() async throws {
        let x = Self.answer(title: "x", tldr: "x", overview: "x", actionItems: [], highlights: [])
        let honest = Self.answer(
            title: "Audio check before the demo",
            tldr: "Alice and Bob checked the audio and set the demo for tomorrow at ten.",
            overview: "", actionItems: [], highlights: []
        )
        let run = await Self.run([Self.reply(x), Self.reply(honest)], transcript: Self.shortEnglishTranscript())
        #expect(run.error == nil)
        #expect(run.summary?.title == "Audio check before the demo")
        try #require(run.calls.count == 2)
        let instruction = Summarizer.placeholderRetryInstruction(parts: ["title", "tldr", "overview"], overviewMayBeBlank: true)
        #expect(run.calls[1].messages.last?.content.hasSuffix(instruction) == true)
        #expect(instruction.contains("empty string"))
    }

    @Test func xTwiceThrowsNamingEveryPart() async {
        let x = Self.reply(Self.answer(title: "x", tldr: "x", overview: "x", actionItems: [], highlights: []))
        let run = await Self.run([x, x], transcript: Self.longRussianTranscript())
        #expect(run.summary == nil)
        #expect(run.placeholderParts == ["title", "tldr", "overview"])
        #expect(run.error?.localizedDescription.contains("placeholder") == true)
    }

    /// A cut-off first answer gets the compact retry; a placeholder in that
    /// retry's answer throws — there is still only one retry.
    @Test func placeholderAfterTheCutOffRetryThrows() async {
        let run = await Self.run(
            [Self.reply(#"{"tldr":"Команда"#, finish: "length"), Self.reply(Self.answer(overview: "..."))],
            transcript: Self.longRussianTranscript()
        )
        #expect(run.placeholderParts == ["overview"])
        #expect(run.calls.count == 2)
    }

    // MARK: - Honest answers still pass

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
            (Self.answer(title: "Демо завтра", tldr: "Демо завтра в десять.",
                         overview: "Короткая проверка звука.",
                         actionItems: [["owner": "unassigned", "task": "Провести демо", "due": "завтра"]],
                         highlights: [["speaker": "Ян", "highlights": ["Всё слышно"]]]),
             Self.shortRussianTranscript()),
        ]
        for (answer, transcript) in table {
            let run = await Self.run([Self.reply(answer)], transcript: transcript)
            #expect(run.error == nil, "\(answer)")
            #expect(run.calls.count == 1, "\(answer)")
        }
    }

    /// A long meeting with a real but compact summary — two short paragraphs,
    /// two-letter names, an owner of "None" — is accepted on the first call.
    @Test func honestLongSummaryPassesFirstTime() async {
        let answer = Self.answer(
            actionItems: [
                ["owner": "Ян", "task": "Подтвердить дату релиза", "due": NSNull()],
                ["owner": "None", "task": "Обновить раздел про установку", "due": NSNull()],
            ],
            highlights: [["speaker": "Ли", "highlights": ["Неделя на тесты"]]]
        )
        let run = await Self.run([Self.reply(answer)], transcript: Self.longRussianTranscript())
        #expect(run.error == nil)
        #expect(run.summary?.title == "План запуска и документация")
        #expect(run.calls.count == 1)
    }

    // MARK: - How much a meeting needs

    /// What the TL;DR and overview must hold grows with the transcript: a
    /// two-word overview of a 48-minute meeting is a stub; of a short one it
    /// is fine. A blank overview is allowed only for a short meeting.
    @Test func expectationsScaleWithTheTranscript() {
        let long = SummaryContent.letters(in: Self.longRussianTranscript())
        let short = SummaryContent.letters(in: Self.shortRussianTranscript())
        #expect(long > 25_000)
        #expect(short < 100)
        let table: [(content: String, letters: Int, want: String)] = [
            (Self.answer(overview: "Итоги встречи."), long, "placeholder(overview)"),
            (Self.answer(overview: "Итоги встречи."), short, "complete"),
            (Self.answer(overview: ""), long, "placeholder(overview)"),
            (Self.answer(overview: "  "), short, "complete"),
            (Self.answer(overview: "Ок."), short, "placeholder(overview)"),         // a stub at any length
            (Self.answer(tldr: "Бюджет."), long, "placeholder(tldr)"),
            (Self.answer(tldr: "Бюджет."), short, "complete"),
            (Self.answer(tldr: "Обсудили бюджет."), long, "complete"),
            (Self.answer(), long, "complete"),
        ]
        for (content, letters, want) in table {
            #expect(Self.assess(content, transcriptLetters: letters) == want, "\(content) @ \(letters)")
        }
    }

    /// The lists: a schema echo or a contentless entry is a placeholder; a
    /// short name never is.
    @Test func listEntriesAreJudgedToo() {
        let table: [(content: String, want: String)] = [
            (Self.answer(actionItems: [["owner": "string", "task": "string", "due": NSNull()]]), "placeholder(action_items)"),
            (Self.answer(actionItems: [["owner": "Анна", "task": "...", "due": NSNull()]]), "placeholder(action_items)"),
            (Self.answer(highlights: [["speaker": "string", "highlights": ["string"]]]), "placeholder(per_speaker_highlights)"),
            (Self.answer(highlights: [["speaker": "Борис", "highlights": ["—"]]]), "placeholder(per_speaker_highlights)"),
            (Self.answer(actionItems: [["owner": "Ян", "task": "Позвонить юристу", "due": NSNull()]],
                         highlights: [["speaker": "Ли", "highlights": ["Согласна с планом"]]]), "complete"),
        ]
        for (content, want) in table {
            #expect(Self.assess(content, transcriptLetters: 300) == want, "\(content)")
        }
    }

    /// Missing parts are asked for first; placeholders are judged only in a
    /// complete answer.
    @Test func missingPartsComeBeforePlaceholders() {
        #expect(Self.assess(#"{"tldr":"x"}"#, transcriptLetters: 300)
            == "incomplete(overview, action_items, per_speaker_highlights)")
    }

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
            "Строка в договоре", "会议纪要",
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
        #expect(run.error == nil)
        #expect(run.calls.count == 1)
        #expect(run.summary != nil)
        #expect(run.summary?.title == nil)
    }

    @Test func titleToAdoptTable() {
        let placeholder = "Recording · Zoom · Nov 26, 10:00"
        let table: [(generated: String?, current: String, want: String?)] = [
            ("План запуска и документация", placeholder, "План запуска и документация"),
            ("  Q4 hiring plan  ", "Meeting 2026-11-26", "Q4 hiring plan"),
            ("Q4 hiring plan", "", "Q4 hiring plan"),
            ("x", placeholder, nil),
            ("...", placeholder, nil),
            ("string", placeholder, nil),
            ("<title>", placeholder, nil),
            ("Meeting 2026-11-26", placeholder, nil),                         // a placeholder of our own
            (nil, placeholder, nil),
            ("   ", placeholder, nil),
            ("Q4 hiring plan", "Weekly sync with Acme", nil),                 // a calendar event's name stays
            ("Q4 hiring plan", "Бюджет на 2027", nil),                        // so does one the user typed
        ]
        for (generated, current, want) in table {
            #expect(MeetingNaming.titleToAdopt(generated: generated, replacing: current) == want,
                    "\(generated ?? "nil") over \(current)")
        }
    }

    // MARK: - Prompt and copy

    /// The cut-off retry asks for a shorter overview — never for a stub. Its
    /// old wording ("a shorter overview and fewer highlights") had no floor.
    @Test func compactRetryRulesOutPlaceholders() {
        #expect(Summarizer.compactRetryInstruction.contains("placeholder"))
    }

    /// The first request names placeholders as wrong and gives the honest way
    /// out for a meeting with little in it.
    @Test func firstRequestGivesAnHonestWayOut() async throws {
        let run = await Self.run([Self.reply(Self.answer())], transcript: Self.longRussianTranscript())
        let system = try #require(run.calls.first?.messages.first?.content)
        #expect(system.contains("placeholder"))
        #expect(system.contains("empty string"))
    }

    @Test func errorCopy() {
        let message = SummarizerError.placeholder(parts: ["tldr", "overview"]).localizedDescription
        #expect(message == "The summary came back with placeholder text instead of content (tldr, overview). Try again, or use another model.")
    }
}
