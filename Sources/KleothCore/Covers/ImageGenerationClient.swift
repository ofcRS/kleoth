import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Draws one cover picture from an image prompt. The engines (OpenRouter, a
/// local server, Codex) differ only in how they are reached, so the drawing
/// depends on this, never on a concrete client.
public protocol CoverImageGenerating: Sendable {
    func generate(prompt: String, model: String) async throws -> GeneratedImage
}

/// The engine's picture as it came back (PNG, JPEG or WebP, not yet
/// normalized) and the USD it cost, when the engine reports one — only
/// OpenRouter does; nil means free or unknown.
public struct GeneratedImage: Sendable, Equatable {
    public let data: Data
    public let cost: Double?

    public init(data: Data, cost: Double?) {
        self.data = data
        self.cost = cost
    }
}

/// One client, two dialects of the same Images API (design doc 2026-09-24
/// §4.1): OpenRouter's `POST /images` and the OpenAI-shaped
/// `POST /images/generations` a local server such as Ollama speaks. Both
/// answer `data[0].b64_json`, so one decoder serves both.
///
/// Failures map to the copy the History tile shows (§5): a local server that
/// is not listening is `ProviderError.unreachable` and a model it has not
/// pulled is `ProviderError.modelMissing`, exactly as the chat client reports
/// them; everything else non-2xx is a `CoverError`, and the drawing words it
/// per status because it knows the engine.
///
/// The OpenRouter body carries no `provider.require_parameters`, unlike chat
/// (`OpenAICompatibleClient`): the Images API has no such key, and the
/// account guardrails it works around (no-train and ZDR turning required
/// parameters into 404s) are a chat-completions concern. An image model the
/// data policy leaves without an endpoint still 404s, and that surfaces as
/// `CoverError.dataPolicy` naming the model to change.
public struct ImageGenerationClient: CoverImageGenerating {
    public enum Dialect: String, Sendable, Equatable {
        /// `https://openrouter.ai/api/v1/images`, with attribution headers.
        case openRouter
        /// `<local_server_url>/images/generations` (Ollama, LM Studio, a gateway).
        case openAICompatible
    }

    /// The API root, e.g. `https://openrouter.ai/api/v1` or `http://localhost:11434/v1`.
    public let baseURL: URL
    /// Bearer token; nil or empty sends no `Authorization` header (Ollama needs none).
    public let apiKey: String?
    public let dialect: Dialect
    public let transport: HTTPTransport

    public init(baseURL: URL, apiKey: String?, dialect: Dialect, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.dialect = dialect
        self.transport = transport
    }

    public var endpoint: URL {
        switch dialect {
        case .openRouter: baseURL.appendingPathComponent("images")
        case .openAICompatible: baseURL.appendingPathComponent("images/generations")
        }
    }

    /// Asks for one square picture and returns its bytes and reported cost.
    ///
    /// Throws, besides the transport's own errors:
    /// - `ProviderError.unreachable(url:)` when nothing listens at a local
    ///   server's address. Deliberately not transient: a server that is not
    ///   running will not start in the 2 s before a retry.
    /// - `ProviderError.modelMissing` for a local 404 that names an unpulled model.
    /// - `CoverError.dataPolicy` for OpenRouter's "no endpoints … data policy" 404.
    /// - `CoverError.refused` when the model's moderation refused the prompt.
    /// - `CoverError.http(status:body:)` for any other non-2xx; `body` is the
    ///   first 500 bytes, for the log.
    /// - `CoverError.noImage` when the answer holds no `b64_json` — including
    ///   a 200 that is not JSON at all (a proxy's or captive portal's HTML
    ///   page), which would otherwise surface as a `DecodingError` no History
    ///   line can word — and `CoverError.unreadableImage` when it is not base64.
    public func generate(prompt: String, model: String) async throws -> GeneratedImage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if dialect == .openRouter {
            // Optional attribution headers (no secrets), as the chat client sends.
            request.setValue("https://kleoth.dev", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Kleoth", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.body(prompt: prompt, model: model, dialect: dialect)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError
            where dialect == .openAICompatible && Self.unreachableCodes.contains(error.code) {
            throw ProviderError.unreachable(url: baseURL)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            // Local servers only: OpenRouter's 404s (a data policy, a bad slug)
            // can carry the same words and must never become an `ollama pull` hint.
            if status == 404, dialect == .openAICompatible,
               let hint = OpenAICompatibleClient.pullHint(model: model, body: data) {
                throw ProviderError.modelMissing(model: model, hint: hint)
            }
            if dialect == .openRouter, Self.isDataPolicyRefusal(status: status, body: body) {
                throw CoverError.dataPolicy(model: model)
            }
            if Self.isModerationRefusal(status: status, body: body) {
                throw CoverError.refused(body)
            }
            throw CoverError.http(status: status, body: body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(ResponseBody.self, from: data) else { throw CoverError.noImage }
        guard let b64 = envelope.data?.first?.b64Json, !b64.isEmpty else { throw CoverError.noImage }
        guard let bytes = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), !bytes.isEmpty else {
            throw CoverError.unreadableImage
        }
        return GeneratedImage(data: bytes, cost: envelope.usage?.cost)
    }

    /// The request body. OpenRouter takes an aspect ratio and a resolution
    /// tier and can be asked for JPEG (smaller to download); the OpenAI shape
    /// takes a pixel size and must be asked for base64, or it may answer with
    /// a URL. Both ask for one picture.
    static func body(prompt: String, model: String, dialect: Dialect) -> [String: Any] {
        switch dialect {
        case .openRouter:
            return [
                "model": model, "prompt": prompt, "n": 1,
                "aspect_ratio": "1:1", "resolution": "1K", "output_format": "jpeg",
            ]
        case .openAICompatible:
            return [
                "model": model, "prompt": prompt, "n": 1,
                "size": "1024x1024", "response_format": "b64_json",
            ]
        }
    }

    /// A 400/403 whose body says the prompt was blocked by moderation or a
    /// safety/content policy. The user can do something about it (New Cover
    /// writes another scene), so it gets its own copy instead of an HTTP code.
    static func isModerationRefusal(status: Int, body: String) -> Bool {
        guard status == 400 || status == 403 else { return false }
        let text = body.lowercased()
        return ["moderation", "safety", "content policy", "content_policy", "prohibited"]
            .contains { text.contains($0) }
    }

    /// OpenRouter's 404 when the account's data policy (no-train, ZDR) leaves
    /// the model without an endpoint: "No endpoints found matching your data
    /// policy", or a `zdr` violation.
    static func isDataPolicyRefusal(status: Int, body: String) -> Bool {
        guard status == 404 else { return false }
        let text = body.lowercased()
        return ["data policy", "no endpoints found", "zdr"].contains { text.contains($0) }
    }

    /// Nothing listens at the address, or the name does not resolve.
    private static let unreachableCodes: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]

    /// `{"data": [{"b64_json": "…"}], "usage": {"cost": 0.0336}}`; OpenRouter
    /// adds `media_type`, which is not needed — the normalizer reads the bytes.
    private struct ResponseBody: Decodable {
        struct Item: Decodable { let b64Json: String? }
        struct Usage: Decodable { let cost: Double? }
        let data: [Item]?
        let usage: Usage?
    }
}
