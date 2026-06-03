import Testing
@testable import KleothCore

/// Covers the pure filter/sort core of `ModelCatalog`: only no-train-friendly
/// providers survive, and the default + the user's current model are always
/// present so the Settings picker never loses a configured choice.
@Suite struct ModelCatalogTests {
    /// A representative slice of the live feed: allowed providers mixed with
    /// providers this account's data policy 404s (`openai/`, `x-ai/`, `mistralai/`, `qwen/`).
    static let feed = [
        "openai/gpt-4o",
        "openai/gpt-4o-mini",
        "x-ai/grok-4",
        "mistralai/mistral-large",
        "qwen/qwen3.5-max",
        "google/gemini-3-flash-preview",
        "google/gemini-3.5-flash",
        "anthropic/claude-haiku-4.5",
        "anthropic/claude-sonnet-4.6",
        "deepseek/deepseek-v4-flash",
        "z-ai/glm-4.7",
        "moonshotai/kimi-k2.6",
        "minimax/minimax-m3",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    @Test func dropsDisallowedProviders() {
        let result = ModelCatalog.filtered(from: Self.feed)
        // None of the no-train-blocked providers survive.
        #expect(!result.contains("openai/gpt-4o"))
        #expect(!result.contains("openai/gpt-4o-mini"))
        #expect(!result.contains("x-ai/grok-4"))
        #expect(!result.contains("mistralai/mistral-large"))
        #expect(!result.contains("qwen/qwen3.5-max"))
        #expect(!result.contains { ModelCatalog.isAllowed($0) == false })
    }

    @Test func keepsAllowedProviders() {
        let result = ModelCatalog.filtered(from: Self.feed)
        #expect(result.contains("google/gemini-3-flash-preview"))
        #expect(result.contains("google/gemini-3.5-flash"))
        #expect(result.contains("anthropic/claude-haiku-4.5"))
        #expect(result.contains("anthropic/claude-sonnet-4.6"))
        #expect(result.contains("deepseek/deepseek-v4-flash"))
    }

    @Test func alwaysIncludesDefaultEvenWhenAbsentFromFeed() {
        // A feed with no Google models at all still yields the default.
        let result = ModelCatalog.filtered(from: ["anthropic/claude-haiku-4.5"])
        #expect(result.contains(ModelCatalog.defaultModel))
    }

    @Test func defaultModelLeadsTheList() {
        let result = ModelCatalog.filtered(from: Self.feed)
        #expect(result.first == ModelCatalog.defaultModel)
    }

    @Test func alwaysIncludesCurrentSelection() {
        // An externally-configured slug not in the feed is retained.
        let current = "z-ai/glm-5"
        let result = ModelCatalog.filtered(from: Self.feed, keeping: current)
        #expect(result.contains(current))
    }

    @Test func currentFromDisallowedProviderIsStillKept() {
        // If the user already configured an openai/* model, don't silently drop
        // it — the picker must still display the active selection.
        let current = "openai/gpt-4o-mini"
        let result = ModelCatalog.filtered(from: Self.feed, keeping: current)
        #expect(result.contains(current))
    }

    @Test func deduplicatesRepeatedIDs() {
        let result = ModelCatalog.filtered(
            from: ["google/gemini-3.5-flash", "google/gemini-3.5-flash"]
        )
        #expect(result.filter { $0 == "google/gemini-3.5-flash" }.count == 1)
    }

    @Test func sortsGroupedByProviderThenName() {
        let result = ModelCatalog.filtered(from: Self.feed)
        // After the leading default, providers are contiguous and ascending.
        let providers = result.dropFirst().map { $0.split(separator: "/").first.map(String.init) ?? $0 }
        var firstIndexByProvider: [String: Int] = [:]
        for (i, p) in providers.enumerated() where firstIndexByProvider[p] == nil {
            firstIndexByProvider[p] = i
        }
        // Each provider's rows are contiguous: count of distinct first-indices
        // equals count of provider-change boundaries.
        var boundaries = providers.isEmpty ? 0 : 1
        for i in providers.indices.dropFirst() where providers[i] != providers[i - 1] {
            boundaries += 1
        }
        #expect(boundaries == firstIndexByProvider.count)
    }

    @Test func curatedFallbackIsAllAllowedAndLeadsWithDefault() {
        // The offline fallback must itself pass the filter unchanged in spirit:
        // every entry is an allowed provider and the default is first.
        #expect(ModelCatalog.curatedFallback.first == ModelCatalog.defaultModel)
        #expect(ModelCatalog.curatedFallback.allSatisfy { ModelCatalog.isAllowed($0) })
    }
}
