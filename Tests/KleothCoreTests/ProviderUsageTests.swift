import Testing
import Foundation
@testable import KleothCore

@Suite struct ProviderUsageTests {
    // MARK: - ElevenLabs

    @Test func elevenLabsUsageDecodesSubscription() async throws {
        let json = """
        {
          "tier": "starter",
          "character_count": 17231,
          "character_limit": 100000,
          "can_extend_character_limit": false,
          "next_character_count_reset_unix": 1769904000,
          "status": "active"
        }
        """
        let transport = MockTransport(json: json)
        let client = ElevenLabsUsageClient(apiKey: "test-key", transport: transport)

        let usage = try await client.fetch()

        #expect(usage.characterCount == 17231)
        #expect(usage.characterLimit == 100_000)
        #expect(usage.tier == "starter")
        #expect(usage.nextReset == Date(timeIntervalSince1970: 1_769_904_000))

        // The request hits the subscription endpoint with the key in the header
        // (and nowhere else — never in the URL).
        let request = try #require(transport.recordedRequests.first)
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user/subscription")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "test-key")
        #expect(request.url?.query() == nil)
    }

    @Test func elevenLabsUsageThrowsOnHTTPError() async {
        let transport = MockTransport(json: "{\"detail\":\"unauthorized\"}", statusCode: 401)
        let client = ElevenLabsUsageClient(apiKey: "bad-key", transport: transport)

        do {
            _ = try await client.fetch()
            Issue.record("Expected ProviderUsageError.httpStatus")
        } catch let ProviderUsageError.httpStatus(code) {
            #expect(code == 401)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - OpenRouter

    @Test func openRouterCreditsDecodeEnvelope() async throws {
        let json = """
        { "data": { "total_credits": 25.0, "total_usage": 14.97 } }
        """
        let transport = MockTransport(json: json)
        let client = OpenRouterUsageClient(apiKey: "test-key", transport: transport)

        let credits = try await client.fetch()

        #expect(abs(credits.totalCredits - 25.0) < 1e-9)
        #expect(abs(credits.totalUsage - 14.97) < 1e-9)
        #expect(abs(credits.remaining - 10.03) < 1e-9)

        let request = try #require(transport.recordedRequests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    /// Used-over-purchased accounts (or rounding artifacts) must not report a
    /// negative remaining balance.
    @Test func openRouterRemainingNeverNegative() {
        let credits = OpenRouterCredits(totalCredits: 5, totalUsage: 6.2)
        #expect(credits.remaining == 0)
    }

    @Test func openRouterCreditsThrowOnHTTPError() async {
        let transport = MockTransport(json: "{}", statusCode: 500)
        let client = OpenRouterUsageClient(apiKey: "test-key", transport: transport)

        do {
            _ = try await client.fetch()
            Issue.record("Expected ProviderUsageError.httpStatus")
        } catch let ProviderUsageError.httpStatus(code) {
            #expect(code == 500)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
