import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET <base>/models` on an OpenAI-compatible server → model ids. Used by the
/// detector (is anything listening? what does it serve?) and the Settings picker.
public enum LocalModelList {
    private struct Response: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]?
    }

    public static func fetch(baseURL: URL, apiKey: String?, transport: HTTPTransport) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw OpenRouterError.httpError(status: status, bodySnippet: String(decoding: data.prefix(200), as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.data ?? []).map(\.id)
    }
}
