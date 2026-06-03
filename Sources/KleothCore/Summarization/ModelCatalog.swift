import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live, filtered catalog of summarization models from OpenRouter.
///
/// The Settings model picker used to ship a hardcoded list that went stale and
/// — worse — listed `openai/*` models that this account's no-train data policy
/// 404s (see CLAUDE.md). `ModelCatalog` replaces it: it fetches the **public**
/// OpenRouter models endpoint (no API key needed), keeps only providers known
/// to work under the no-train policy, and falls back to a small curated list of
/// real, verified slugs when offline or on any error.
///
/// The filter/sort logic (``filtered(from:keeping:)``) is pure and unit-tested;
/// ``fetch(transport:)`` wraps it with networking + disk caching and is
/// **fail-soft** — it never throws to the UI.
public struct ModelCatalog: Sendable {
    /// Default summarization model — kept in sync with `Settings.load()`.
    /// Always surfaced first in the picker and guaranteed present.
    public static let defaultModel = "google/gemini-3-flash-preview"

    /// Provider prefixes that work under this account's no-train data policy.
    /// Anything outside this set (`openai/`, `mistralai/`, `x-ai/`, …) is
    /// dropped because OpenRouter 404s it under `require_parameters: true`.
    public static let allowedProviderPrefixes: [String] = [
        "google/",
        "deepseek/",
        "anthropic/",
        "z-ai/",
        "moonshotai/",
        "minimax/",
        "meta-llama/",
    ]

    /// A small set of real, currently-available slugs (verified live against
    /// the models endpoint) used offline or when the fetch fails. The default
    /// model is first; the rest span the allowed providers so the picker is
    /// useful even with no network. Keep these to real slugs only.
    public static let curatedFallback: [String] = [
        "google/gemini-3-flash-preview",   // default
        "google/gemini-3.5-flash",
        "google/gemini-3.1-pro-preview",
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-chat-v3.1",
        "anthropic/claude-haiku-4.5",
        "anthropic/claude-sonnet-4.6",
        "z-ai/glm-4.7",
        "moonshotai/kimi-k2.6",
        "minimax/minimax-m3",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    /// How long a cached catalog is considered fresh (24 hours).
    public static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// Where the cache file lives. Defaults to the app's config-support dir.
    private let cacheURL: URL

    /// - Parameter cacheURL: override the on-disk cache location (tests). When
    ///   `nil`, uses ``defaultCacheURL`` under the user's config-support dir.
    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
    }

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/models")!

    // MARK: - Pure filter + sort

    /// Keeps only ids under an allowed provider prefix, de-duplicates, sorts
    /// (grouped by provider, then by name), and guarantees both ``defaultModel``
    /// and `current` are present even if the feed omits them.
    ///
    /// Pure and deterministic — the unit-tested core of the catalog.
    ///
    /// - Parameters:
    ///   - ids: candidate model ids (e.g. from the live feed or fallback).
    ///   - current: the model the user currently has selected; always retained
    ///     so an externally-configured choice never vanishes from the picker.
    public static func filtered(from ids: [String], keeping current: String? = nil) -> [String] {
        // De-duplicate while keeping only allowed providers.
        var seen = Set<String>()
        var allowed: [String] = []
        for id in ids {
            guard isAllowed(id), !seen.contains(id) else { continue }
            seen.insert(id)
            allowed.append(id)
        }

        // Guarantee the default and the current selection are present.
        for guaranteed in [defaultModel, current] {
            guard let id = guaranteed, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            allowed.append(id)
        }

        // Sort grouped by provider, then by the slug's name part.
        var sorted = allowed.sorted { a, b in
            let (pa, na) = split(a)
            let (pb, nb) = split(b)
            if pa != pb { return pa < pb }
            return na < nb
        }

        // The default model always leads the list (the picker's first row).
        if let idx = sorted.firstIndex(of: defaultModel), idx != 0 {
            sorted.remove(at: idx)
            sorted.insert(defaultModel, at: 0)
        }
        return sorted
    }

    /// Whether `id`'s provider prefix is in ``allowedProviderPrefixes``.
    static func isAllowed(_ id: String) -> Bool {
        allowedProviderPrefixes.contains { id.hasPrefix($0) }
    }

    /// Splits `provider/name` into its two parts (name is `""` if no slash).
    private static func split(_ id: String) -> (provider: String, name: String) {
        guard let slash = id.firstIndex(of: "/") else { return (id, "") }
        return (String(id[..<slash]), String(id[id.index(after: slash)...]))
    }

    // MARK: - Async fetch (fail-soft)

    /// The decoded `{ "data": [ { "id": … } ] }` shape of the models endpoint.
    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    /// Fetches the live model list, filtered to allowed providers and sorted.
    ///
    /// **Never throws to the UI.** On any failure (offline, non-2xx, bad JSON)
    /// it returns the freshest available list: a fresh on-disk cache if one
    /// exists, otherwise ``curatedFallback`` (both run through
    /// ``filtered(from:keeping:)`` so they include the default and `current`).
    /// A successful fetch refreshes the cache.
    ///
    /// - Parameters:
    ///   - transport: HTTP seam (pass `URLSessionTransport()` in the app).
    ///   - current: the user's current selection, always kept in the result.
    public func fetch(transport: HTTPTransport, keeping current: String? = nil) async -> [String] {
        do {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "GET"
            // Public endpoint — no Authorization header. Attribution only.
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://kleoth.dev", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Kleoth", forHTTPHeaderField: "X-Title")

            let (data, response) = try await transport.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(statusCode) else {
                return fallbackList(keeping: current)
            }

            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let ids = decoded.data.map(\.id)
            let result = Self.filtered(from: ids, keeping: current)

            // Cache the raw allowed ids (without the per-call `current`/default
            // guarantees) so a later call's own `current` is honored.
            writeCache(Self.filtered(from: ids))
            return result
        } catch {
            return fallbackList(keeping: current)
        }
    }

    /// Freshest offline list: a non-expired cache, else the curated fallback.
    private func fallbackList(keeping current: String?) -> [String] {
        if let cached = readFreshCache() {
            return Self.filtered(from: cached, keeping: current)
        }
        return Self.filtered(from: Self.curatedFallback, keeping: current)
    }

    // MARK: - Disk cache (acronym-free keys, fail-soft)

    /// On-disk cache payload. JSON keys are acronym-free so they round-trip
    /// through snake_case conventions used elsewhere in the codebase.
    private struct CacheFile: Codable {
        /// Unix epoch seconds when the list was fetched.
        let fetchedAt: Double
        /// The filtered, allowed model ids.
        let models: [String]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case models
        }
    }

    /// Default cache location: `<config-support>/model-catalog.json`.
    public static var defaultCacheURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory

        return base
            .appendingPathComponent("Kleoth", isDirectory: true)
            .appendingPathComponent("model-catalog.json")
    }

    /// Returns cached ids only if the cache exists and is within ``cacheTTL``.
    private func readFreshCache() -> [String]? {
        guard
            let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return nil }

        let age = Date().timeIntervalSince1970 - cache.fetchedAt
        guard age >= 0, age < Self.cacheTTL else { return nil }
        return cache.models
    }

    /// Writes the cache, creating the parent directory if needed. Fail-soft —
    /// a cache-write error never propagates (the fetch result is still returned).
    private func writeCache(_ models: [String]) {
        let cache = CacheFile(fetchedAt: Date().timeIntervalSince1970, models: models)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
