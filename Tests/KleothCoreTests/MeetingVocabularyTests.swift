import Testing
import Foundation
@testable import KleothCore

/// One vocabulary for dictation and meetings: the personal dictionary goes to a
/// meeting's cloud transcription as Scribe `keyterms` and to its summary as
/// preferred spellings. With an empty dictionary both requests stay exactly
/// what they were before (the summary's prefix stays cacheable).
///
/// Invented terms only — never anyone's real vocabulary.
@Suite struct MeetingVocabularyTests {
    // MARK: - Scribe request fixtures

    private static let cannedResponse = """
    {"language_code":"eng","language_probability":0.99,"text":"hello there","words":[]}
    """

    private struct Sent {
        let request: URLRequest
        let body: String
        let boundary: String
    }

    /// Runs one `transcribe` against a canned transport and returns what was sent.
    private func send(options: ScribeOptions) async throws -> Sent {
        // One fixed file name, so two bodies can be compared byte for byte.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-meeting-vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioURL = dir.appendingPathComponent("meeting.m4a")
        try Data("AUDIO".utf8).write(to: audioURL)

        let transport = MockTransport(json: Self.cannedResponse)
        let client = ScribeClient(apiKey: "test-key-not-a-secret", transport: transport)
        _ = try await client.transcribe(fileURL: audioURL, options: options)

        let request = try #require(transport.recordedRequests.first)
        let body = try #require(transport.uploadBodyText())
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        return Sent(request: request, body: body, boundary: boundary)
    }

    private func partValues(named name: String, in body: String) -> [String] {
        let header = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        return body.components(separatedBy: header).dropFirst().compactMap { tail in
            tail.range(of: "\r\n").map { String(tail[tail.startIndex..<$0.lowerBound]) }
        }
    }

    private func makeDictionaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kleoth-meeting-vocab-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    // MARK: - Meeting transcription

    @Test func meetingRequestCarriesKeyterms() async throws {
        let terms = ["Acmeflow", "Zorblat"]
        let sent = try await send(options: .meeting(keyterms: terms))

        #expect(partValues(named: "keyterms", in: sent.body) == terms)
        // Still the meeting request: diarized, audio events tagged, scribe_v2.
        #expect(partValues(named: "model_id", in: sent.body) == ["scribe_v2"])
        #expect(partValues(named: "diarize", in: sent.body) == ["true"])
        #expect(partValues(named: "tag_audio_events", in: sent.body) == ["true"])
        #expect(!sent.body.contains("name=\"no_verbatim\""), "Meetings stay verbatim.")
    }

    @Test func emptyVocabularyLeavesTheMeetingRequestUnchanged() async throws {
        let before = try await send(options: ScribeOptions())
        let after = try await send(options: .meeting(keyterms: []))

        #expect(!after.body.contains("name=\"keyterms\""))
        // The same parts byte for byte, once the random boundary is factored out.
        // Compared as a sorted list: the keyed fields come from a dictionary,
        // so their order differs from one request to the next even today.
        func parts(_ sent: Sent) -> [String] {
            sent.body.components(separatedBy: "--\(sent.boundary)").sorted()
        }
        #expect(parts(after) == parts(before))
        #expect(after.body.count == before.body.count)
    }

    @Test func overLimitDictionarySendsTheFirstHundredValidTermsInOrder() async throws {
        let url = makeDictionaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Invalid entries come first: they are dropped and don't count against the cap.
        let invalid = ["bad<term", "one two three four five six", String(repeating: "x", count: Keyterms.maxCharacters + 1)]
        let valid = (1...150).map { "Zorblat\($0)" }
        let store = PersonalDictionaryStore(url: url)
        try store.save(invalid + valid)

        let terms = store.sentTerms()
        #expect(terms == Array(valid.prefix(Keyterms.maxTerms)))

        let sent = try await send(options: .meeting(keyterms: terms))
        let onWire = partValues(named: "keyterms", in: sent.body)
        #expect(onWire.count == Keyterms.maxTerms)
        #expect(onWire.first == "Zorblat1")
        #expect(onWire.last == "Zorblat100", "File order decides: the first 100 valid terms win.")
    }

    @Test func cyrillicTermsAreKeptAndSentAsUTF8() async throws {
        let atLimit = String(repeating: "ж", count: Keyterms.maxCharacters)
        let overLimit = String(repeating: "ж", count: Keyterms.maxCharacters + 1)
        let sanitized = Keyterms.sanitize(["Зорблатов", "зорблатов", "Акмефлоу Про", atLimit, overLimit, "Acmeflow"])
        // Characters, not UTF-8 bytes, count toward the limit; Cyrillic de-dupes case-insensitively.
        #expect(sanitized == ["Зорблатов", "Акмефлоу Про", atLimit, "Acmeflow"])

        let sent = try await send(options: .meeting(keyterms: ["Зорблатов", "Acmeflow"]))
        #expect(partValues(named: "keyterms", in: sent.body) == ["Зорблатов", "Acmeflow"])
    }

    // MARK: - Meeting cost

    /// A Scribe-priced engine: 1 USD per hour, so the cost reads as a multiplier.
    private struct PricedTranscriber: Transcriber {
        var usdPerHour: Double { 1 }
        func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
            ScribeResponse(
                words: [ScribeWord(text: "Hello", start: 0, end: 0.5, type: "word", speakerId: "speaker_0")],
                audioDurationSecs: 3600
            )
        }
    }

    private func transcriptionCost(keyterms: [String]) async throws -> Double {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-meeting-vocab-cost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        // Unreadable as audio, so the duration falls back to the response's hour.
        let audioFile = baseDir.appendingPathComponent("audio.m4a")
        try Data("fake-audio".utf8).write(to: audioFile)

        let pipeline = MeetingPipeline(
            transcriber: PricedTranscriber(), summarizer: nil, store: MeetingStore(baseDir: baseDir))
        let result = try await pipeline.run(
            audioFile: audioFile,
            metadata: MeetingMetadata(title: "Launch", date: "2026-09-24"),
            options: .meeting(keyterms: keyterms),
            summarize: false
        )
        return result.cost.transcriptionUSD
    }

    @Test func keytermsAddTheSurchargeToTheMeetingCost() async throws {
        #expect(try await transcriptionCost(keyterms: []) == 1)
        let withTerms = try await transcriptionCost(keyterms: ["Acmeflow"])
        #expect(abs(withTerms - DictationDefaults.keytermSurchargeMultiplier) < 1e-9)
    }

    // MARK: - Summary prompt

    static let completeAnswer =
        #"{"title":"T","tldr":"t","overview":"o","action_items":[],"per_speaker_highlights":[]}"#

    static func transcript() -> Transcript {
        Transcript(
            utterances: [
                Utterance(speakerId: "speaker_0", speakerName: "Alice", start: 0, end: 1, text: "Acme flow ships Monday."),
                Utterance(speakerId: "speaker_1", speakerName: "Bob", start: 1.5, end: 2.5, text: "Zor blat too."),
            ],
            languageCode: "en",
            durationSecs: 2.5
        )
    }

    static func metadata() -> MeetingMetadata {
        MeetingMetadata(title: "Launch", date: "2026-05-30", participants: ["Alice", "Bob"])
    }

    /// The messages of the first request a summary run sends.
    private func firstRequest(spellings: [String]?) async throws -> [ChatMessage] {
        let client = MockChatClient(results: [.success(ChatCompletion(content: Self.completeAnswer, finishReason: "stop"))])
        var summarizer = Summarizer(client: client)
        if let spellings { summarizer.preferredSpellings = spellings }
        _ = try await summarizer.summarize(transcript: Self.transcript(), metadata: Self.metadata())
        return try #require(client.calls.first).messages
    }

    /// Today's user message for the fixture, byte for byte.
    static let userContentWithoutSpellings = """
    Meeting: Launch
    Date: 2026-05-30
    Participants: Alice, Bob
    Transcript language: English. Write the entire summary in English.

    Transcript:
    Alice: Acme flow ships Monday.
    Bob: Zor blat too.
    """

    @Test func emptyVocabularyLeavesTheSummaryRequestUnchanged() async throws {
        let unset = try await firstRequest(spellings: nil)
        let empty = try await firstRequest(spellings: [])

        #expect(unset.count == 2)
        #expect(unset[1].content == Self.userContentWithoutSpellings)
        #expect(empty.map(\.role) == unset.map(\.role))
        #expect(empty.map(\.content) == unset.map(\.content))
        #expect(!empty[1].content.contains("Preferred spellings"))
    }

    @Test func summaryPromptCarriesSpellingsWhenTheListIsNonEmpty() async throws {
        let plain = try await firstRequest(spellings: [])
        let withSpellings = try await firstRequest(spellings: ["Acmeflow", "Zorblat", "Зорблатов"])

        // The system prompt — the cached prefix — is untouched.
        #expect(withSpellings[0].content == plain[0].content)

        let user = withSpellings[1].content
        let line = try #require(user.split(separator: "\n").first { $0.hasPrefix("Preferred spellings:") })
        #expect(line.contains("Acmeflow, Zorblat, Зорблатов"))
        // In the header, before the transcript it corrects.
        let lineRange = try #require(user.range(of: String(line)))
        let transcriptRange = try #require(user.range(of: "\n\nTranscript:\n"))
        #expect(lineRange.upperBound <= transcriptRange.lowerBound)
        // Only that line is added.
        #expect(user.replacingOccurrences(of: "\n" + line, with: "") == plain[1].content)
    }
}
