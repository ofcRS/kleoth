import Testing
import Foundation
@testable import KleothCore

/// What `ScribeClient` actually puts on the wire for the dictation options.
/// The body is captured by `MockTransport` while the request is in flight —
/// `transcribe` deletes its temporary body file as soon as the upload returns.
@Suite struct ScribeDictationOptionsTests {
    private static let cannedResponse = """
    {"language_code":"eng","language_probability":0.99,"text":"hello there","words":[]}
    """

    private struct Sent {
        let request: URLRequest
        let body: String
    }

    /// Runs one `transcribe` against a canned transport and returns what was sent.
    private func send(options: ScribeOptions) async throws -> Sent {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-scribe-opts-\(UUID().uuidString).m4a")
        try Data("AUDIO".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transport = MockTransport(json: Self.cannedResponse)
        let client = ScribeClient(apiKey: "test-key-not-a-secret", transport: transport)
        _ = try await client.transcribe(fileURL: audioURL, options: options)

        let request = try #require(transport.recordedRequests.first)
        let body = try #require(transport.uploadBodyText())
        return Sent(request: request, body: body)
    }

    private func partValues(named name: String, in body: String) -> [String] {
        let header = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        return body.components(separatedBy: header).dropFirst().compactMap { tail in
            tail.range(of: "\r\n").map { String(tail[tail.startIndex..<$0.lowerBound]) }
        }
    }

    @Test func modelIdentifierIsTheModelIdActuallySent() async throws {
        let client = ScribeClient(apiKey: "test-key-not-a-secret", transport: MockTransport(json: Self.cannedResponse))
        #expect(client.modelIdentifier(for: .dictation(keyterms: [])) == "scribe_v2")
        #expect(client.modelIdentifier(for: ScribeOptions(modelId: "scribe_v1")) == "scribe_v1")
        // A non-Scribe engine falls back to its type name, never to a Scribe slug.
        struct FakeEngine: Transcriber {
            var usdPerHour: Double { 0 }
            func transcribe(fileURL: URL, options: ScribeOptions) async throws -> ScribeResponse {
                throw CancellationError()
            }
        }
        #expect(FakeEngine().modelIdentifier(for: .dictation(keyterms: [])) == "FakeEngine")
    }

    @Test func dictationOptionsSendNoVerbatimTrue() async throws {
        let sent = try await send(options: .dictation(keyterms: []))
        #expect(partValues(named: "no_verbatim", in: sent.body) == ["true"])
    }

    @Test func noVerbatimFalseOmitsField() async throws {
        let sent = try await send(options: ScribeOptions())
        #expect(
            !sent.body.contains("name=\"no_verbatim\""),
            "The meeting path must not gain a no_verbatim part."
        )
    }

    @Test func keytermsAreRepeatedParts() async throws {
        let terms = ["Kleoth", "WhisperKit", "Scribe"]
        let sent = try await send(options: .dictation(keyterms: terms))
        #expect(partValues(named: "keyterms", in: sent.body) == terms)

        // No keyterms → no keyterms part at all.
        let none = try await send(options: .dictation(keyterms: []))
        #expect(!none.body.contains("name=\"keyterms\""))
    }

    @Test func dictationOptionsDisableDiarizationAndAudioEventsAndLanguage() async throws {
        let options = ScribeOptions.dictation(keyterms: [])
        #expect(options.modelId == "scribe_v2")
        #expect(options.diarize == false)
        #expect(options.numSpeakers == nil)
        #expect(options.languageCode == nil)
        #expect(options.tagAudioEvents == false)
        #expect(options.useMultiChannel == false)
        #expect(options.noVerbatim == true)

        let sent = try await send(options: options)
        #expect(partValues(named: "model_id", in: sent.body) == ["scribe_v2"])
        #expect(partValues(named: "diarize", in: sent.body) == ["false"])
        #expect(partValues(named: "tag_audio_events", in: sent.body) == ["false"])
        #expect(
            !sent.body.contains("name=\"language_code\""),
            "Dictation lets Scribe auto-detect the language."
        )
        #expect(!sent.body.contains("name=\"use_multi_channel\""))
        #expect(!sent.body.contains("name=\"num_speakers\""))
    }

    @Test func xiApiKeyHeaderAndBoundaryMatch() async throws {
        let sent = try await send(options: .dictation(keyterms: ["Kleoth"]))

        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path == "/v1/speech-to-text")
        #expect(sent.request.value(forHTTPHeaderField: "xi-api-key") == "test-key-not-a-secret")
        #expect(
            sent.request.value(forHTTPHeaderField: "Authorization") == nil,
            "The key travels only in xi-api-key."
        )

        let contentType = try #require(sent.request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        #expect(contentType.hasPrefix(prefix))
        let boundary = String(contentType.dropFirst(prefix.count))
        #expect(sent.body.hasPrefix("--\(boundary)\r\n"), "Header boundary must match the body's.")
        #expect(sent.body.hasSuffix("--\(boundary)--\r\n"))
    }
}
