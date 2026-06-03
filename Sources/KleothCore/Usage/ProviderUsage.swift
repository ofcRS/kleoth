import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Provider-reported account usage, fetched live from ElevenLabs and OpenRouter.
//
// This is the single place money/quota appears in the product: the rest of the
// UI deliberately shows no per-meeting costs, and nothing here is computed or
// tallied by Kleoth itself — both numbers are whatever the provider reports for
// the whole account, fetched on demand. (Keys go only into request headers and
// are never logged.)

/// Errors thrown by the usage clients.
public enum ProviderUsageError: Error, Sendable {
    /// The provider responded with a non-2xx HTTP status.
    case httpStatus(Int)
}

// MARK: - ElevenLabs

/// The relevant slice of `GET /v1/user/subscription`: ElevenLabs bills its
/// services (including Scribe transcription) against one credit quota per
/// billing cycle, reported in "characters".
public struct ElevenLabsUsage: Codable, Sendable {
    /// Credits used so far this billing cycle.
    public var characterCount: Int
    /// The cycle's credit quota.
    public var characterLimit: Int
    /// Subscription tier slug (e.g. "free", "starter").
    public var tier: String?
    /// Unix timestamp when the cycle's credit count resets.
    public var nextCharacterCountResetUnix: Int?

    /// When the current billing cycle resets, if reported.
    public var nextReset: Date? {
        nextCharacterCountResetUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public init(
        characterCount: Int,
        characterLimit: Int,
        tier: String? = nil,
        nextCharacterCountResetUnix: Int? = nil
    ) {
        self.characterCount = characterCount
        self.characterLimit = characterLimit
        self.tier = tier
        self.nextCharacterCountResetUnix = nextCharacterCountResetUnix
    }
}

/// Fetches the account's subscription usage from ElevenLabs.
public struct ElevenLabsUsageClient: Sendable {
    public let apiKey: String
    public let transport: HTTPTransport
    public let baseURL: URL

    public init(
        apiKey: String,
        transport: HTTPTransport,
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public func fetch() async throws -> ElevenLabsUsage {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/user/subscription"))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await transport.data(for: request)
        try ensureSuccess(response)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ElevenLabsUsage.self, from: data)
    }
}

// MARK: - OpenRouter

/// `GET /api/v1/credits`: lifetime USD purchased and used for the account.
public struct OpenRouterCredits: Codable, Sendable {
    /// Total credits purchased, in USD.
    public var totalCredits: Double
    /// Total usage, in USD, across the account's lifetime.
    public var totalUsage: Double

    /// What's left to spend, in USD (never negative).
    public var remaining: Double { max(0, totalCredits - totalUsage) }

    public init(totalCredits: Double, totalUsage: Double) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
    }
}

/// Fetches the account's credit balance from OpenRouter.
public struct OpenRouterUsageClient: Sendable {
    public let apiKey: String
    public let transport: HTTPTransport
    public let baseURL: URL

    public init(
        apiKey: String,
        transport: HTTPTransport,
        baseURL: URL = URL(string: "https://openrouter.ai")!
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    public func fetch() async throws -> OpenRouterCredits {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/credits"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        try ensureSuccess(response)

        struct Envelope: Codable { var data: OpenRouterCredits }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Envelope.self, from: data).data
    }
}

// MARK: - Shared

/// Throws ``ProviderUsageError/httpStatus(_:)`` for a non-2xx HTTP response.
private func ensureSuccess(_ response: URLResponse) throws {
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw ProviderUsageError.httpStatus(http.statusCode)
    }
}
