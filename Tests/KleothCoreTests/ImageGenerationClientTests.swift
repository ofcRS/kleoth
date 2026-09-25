import Foundation
import Testing
@testable import KleothCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The image engine for OpenRouter's Images API and a local OpenAI-compatible
/// server (design doc 2026-09-24 §4.1, §5): one client, two dialects of the
/// same request, with each engine's failures mapped to the copy the History
/// tile shows.
@Suite struct ImageGenerationClientTests {
    private static let model = "google/gemini-3.1-flash-lite-image"
    private static let localURL = URL(string: "http://localhost:11434/v1")!
    private static let png = CoverTestImages.png(width: 64, height: 64)
    private static let b64 = png.base64EncodedString()
    private static let okJSON =
        #"{"data":[{"b64_json":"\#(b64)","media_type":"image/jpeg"}],"usage":{"cost":0.0336}}"#

    private func openRouter(_ transport: MockTransport) -> ImageGenerationClient {
        ImageGenerationClient(baseURL: OpenRouterClient.baseURL, apiKey: "k", dialect: .openRouter, transport: transport)
    }

    private func local(_ transport: MockTransport, key: String? = nil) -> ImageGenerationClient {
        ImageGenerationClient(baseURL: Self.localURL, apiKey: key, dialect: .openAICompatible, transport: transport)
    }

    private func sentBody(_ transport: MockTransport) throws -> [String: Any] {
        let data = try #require(transport.recordedRequests.first?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The error `generate` throws, or nil when it returned.
    private func thrown(by client: ImageGenerationClient, model: String = Self.model) async -> (any Error)? {
        do {
            _ = try await client.generate(prompt: "p", model: model)
            return nil
        } catch {
            return error
        }
    }

    /// `CoverError.http` with `status`, whatever the body snippet; returns the snippet.
    @discardableResult
    private func expectHTTP(
        _ status: Int, body: String, dialect: ImageGenerationClient.Dialect = .openRouter,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> String? {
        let transport = MockTransport(json: body, statusCode: status)
        let client = dialect == .openRouter ? openRouter(transport) : local(transport)
        do {
            _ = try await client.generate(prompt: "p", model: Self.model)
            Issue.record("expected CoverError.http(\(status)), got an image", sourceLocation: sourceLocation)
        } catch let CoverError.http(got, snippet) {
            #expect(got == status, sourceLocation: sourceLocation)
            return snippet
        } catch {
            Issue.record("expected CoverError.http(\(status)), got \(error)", sourceLocation: sourceLocation)
        }
        return nil
    }

    // MARK: - OpenRouter

    @Test func openRouterPostsToImagesWithBearerAndAttribution() async throws {
        let transport = MockTransport(json: Self.okJSON)

        _ = try await openRouter(transport).generate(prompt: "p", model: Self.model)

        let request = try #require(transport.recordedRequests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/images")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://kleoth.dev")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Kleoth")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func openRouterBodyKeysAreExact() async throws {
        let transport = MockTransport(json: Self.okJSON)

        _ = try await openRouter(transport).generate(prompt: "p", model: Self.model)

        let body = try sentBody(transport)
        #expect(Set(body.keys) == ["model", "prompt", "n", "aspect_ratio", "resolution", "output_format"])
        #expect(body["model"] as? String == "google/gemini-3.1-flash-lite-image")
        #expect(body["prompt"] as? String == "p")
        #expect(body["n"] as? Int == 1)
        #expect(body["aspect_ratio"] as? String == "1:1")
        #expect(body["resolution"] as? String == "1K")
        #expect(body["output_format"] as? String == "jpeg")
        #expect(body["provider"] == nil)
    }

    @Test func b64AndCostAreDecoded() async throws {
        let image = try await openRouter(MockTransport(json: Self.okJSON)).generate(prompt: "p", model: Self.model)
        #expect(image.data == Self.png)
        #expect(image.cost == 0.0336)

        let free = try await openRouter(MockTransport(json: #"{"data":[{"b64_json":"\#(Self.b64)"}]}"#))
            .generate(prompt: "p", model: Self.model)
        #expect(free.data == Self.png)
        #expect(free.cost == nil)
    }

    @Test func statusesMapToErrors() async throws {
        await expectHTTP(401, body: #"{"error":{"message":"No auth credentials found"}}"#)
        await expectHTTP(402, body: #"{"error":{"message":"Insufficient credits"}}"#)

        let dataPolicy = openRouter(MockTransport(
            json: #"{"error":{"message":"No endpoints found matching your data policy"}}"#, statusCode: 404
        ))
        await #expect(throws: CoverError.dataPolicy(model: "google/gemini-3.1-flash-lite-image")) {
            _ = try await dataPolicy.generate(prompt: "p", model: Self.model)
        }

        let moderation = openRouter(MockTransport(
            json: #"{"error":{"message":"Request blocked by content moderation"}}"#, statusCode: 400
        ))
        let refusal = await thrown(by: moderation)
        guard case CoverError.refused = try #require(refusal as? CoverError) else {
            Issue.record("expected CoverError.refused, got \(String(describing: refusal))")
            return
        }

        await expectHTTP(400, body: #"{"error":{"message":"aspect_ratio invalid"}}"#)

        let long = String(repeating: "x", count: 2_000)
        let unavailable = await expectHTTP(503, body: long)
        let snippet = try #require(unavailable)
        #expect(!snippet.isEmpty)
        #expect(snippet.count <= 500)
    }

    // MARK: - OpenAI-compatible (Ollama)

    @Test func localPostsToImagesGenerationsWithoutAuthorization() async throws {
        let anonymous = MockTransport(json: Self.okJSON)
        _ = try await local(anonymous).generate(prompt: "p", model: "x/flux2-klein")

        let request = try #require(anonymous.recordedRequests.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/images/generations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)

        let keyed = MockTransport(json: Self.okJSON)
        _ = try await local(keyed, key: "t").generate(prompt: "p", model: "x/flux2-klein")
        #expect(keyed.recordedRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test func localBodyHasSizeAndResponseFormat() async throws {
        let transport = MockTransport(json: Self.okJSON)

        _ = try await local(transport).generate(prompt: "p", model: "x/flux2-klein")

        let body = try sentBody(transport)
        #expect(Set(body.keys) == ["model", "prompt", "n", "size", "response_format"])
        #expect(body["model"] as? String == "x/flux2-klein")
        #expect(body["prompt"] as? String == "p")
        #expect(body["n"] as? Int == 1)
        #expect(body["size"] as? String == "1024x1024")
        #expect(body["response_format"] as? String == "b64_json")
    }

    @Test func ollamaStyle404IsModelMissingWithThePullHint() async throws {
        let notPulled = #"{"error":{"message":"model \"x/flux2-klein\" not found, try pulling it first"}}"#

        let localClient = local(MockTransport(json: notPulled, statusCode: 404))
        await #expect(throws: ProviderError.modelMissing(model: "x/flux2-klein", hint: "ollama pull x/flux2-klein")) {
            _ = try await localClient.generate(prompt: "p", model: "x/flux2-klein")
        }

        // OpenRouter's 404s are its own (data policy, a bad slug): never an `ollama pull` hint.
        let remote = await thrown(by: openRouter(MockTransport(json: notPulled, statusCode: 404)), model: "x/flux2-klein")
        #expect(remote is CoverError, "expected a CoverError, got \(String(describing: remote))")
        #expect(!(remote is ProviderError))
    }

    /// The data-policy words are OpenRouter's dialect only: a local server's
    /// 404 that happens to carry them (a gateway in front of OpenRouter) is a
    /// plain HTTP error, never a "pick another model in Settings" line, and so
    /// is any local 404 that does not ask for a pull.
    @Test func local404IsHTTPEvenWithDataPolicyWords() async {
        await expectHTTP(
            404, body: #"{"error":{"message":"No endpoints found matching your data policy"}}"#, dialect: .openAICompatible
        )
        await expectHTTP(404, body: #"{"error":{"message":"404 page not found"}}"#, dialect: .openAICompatible)
    }

    // MARK: - Both

    @Test func emptyDataIsNoImage() async throws {
        let empty = openRouter(MockTransport(json: #"{"data":[]}"#))
        await #expect(throws: CoverError.noImage) { _ = try await empty.generate(prompt: "p", model: Self.model) }

        let urlOnly = openRouter(MockTransport(json: #"{"data":[{"url":"https://x"}]}"#))
        await #expect(throws: CoverError.noImage) { _ = try await urlOnly.generate(prompt: "p", model: Self.model) }

        let garbled = openRouter(MockTransport(json: #"{"data":[{"b64_json":"not base64!"}]}"#))
        await #expect(throws: CoverError.unreadableImage) {
            _ = try await garbled.generate(prompt: "p", model: Self.model)
        }
    }

    /// A 200 that is not JSON (a proxy's or captive portal's HTML page) holds
    /// no picture: `noImage`, not a `DecodingError` the History line can't word.
    @Test func nonJSON200IsNoImage() async {
        let html = "<html><body>Welcome to the hotel Wi-Fi</body></html>"
        let remote = openRouter(MockTransport(json: html))
        await #expect(throws: CoverError.noImage) { _ = try await remote.generate(prompt: "p", model: Self.model) }

        let localClient = local(MockTransport(json: html))
        await #expect(throws: CoverError.noImage) { _ = try await localClient.generate(prompt: "p", model: "x/flux2-klein") }
    }

    @Test func localConnectionRefusedIsUnreachable() async throws {
        let refused = MockTransport(outcomes: [.failure(URLError(.cannotConnectToHost))])
        let localClient = local(refused)
        await #expect(throws: ProviderError.unreachable(url: URL(string: "http://localhost:11434/v1")!)) {
            _ = try await localClient.generate(prompt: "p", model: "x/flux2-klein")
        }

        // OpenRouter has no "is Ollama running?" answer: the network error passes through as is.
        let remote = openRouter(MockTransport(outcomes: [.failure(URLError(.cannotConnectToHost))]))
        let error = await #expect(throws: URLError.self) {
            _ = try await remote.generate(prompt: "p", model: Self.model)
        }
        #expect(error?.code == .cannotConnectToHost)
    }
}
