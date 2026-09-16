import Testing
@testable import KleothCore

@Suite struct ProviderResolverTests {
    static func snapshot(_ available: Set<AIProvider>) -> ProviderSnapshot {
        var result: ProviderSnapshot = [:]
        for provider in AIProvider.allCases {
            result[provider] = available.contains(provider)
                ? .available(detail: provider.displayName)
                : .unavailable(reason: "Not installed")
        }
        return result
    }

    @Test func automaticWalksTheOrder() {
        let snap = Self.snapshot([.claudeCode, .openRouter])
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: snap)
                == .provider(.claudeCode, fellThroughFrom: nil))
        let onlyRouter = Self.snapshot([.openRouter, .appleOnDevice])
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: onlyRouter)
                == .provider(.openRouter, fellThroughFrom: nil))
    }

    @Test func automaticSkipsProvidersThatCannotDoTheTask() {
        let snap = Self.snapshot([.codex, .appleOnDevice])
        #expect(ProviderResolver.resolve(task: .dictation, pick: nil, snapshot: snap)
                == .provider(.appleOnDevice, fellThroughFrom: nil))
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: snap)
                == .provider(.codex, fellThroughFrom: nil))
    }

    @Test func nothingAvailableIsNone() {
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: Self.snapshot([])) == .none)
        #expect(ProviderResolver.resolve(task: .summary, pick: nil, snapshot: [:]) == .none)
    }

    @Test func explicitAvailablePickWins() {
        let snap = Self.snapshot([.localServer, .claudeCode, .openRouter])
        #expect(ProviderResolver.resolve(task: .summary, pick: .openRouter, snapshot: snap)
                == .provider(.openRouter, fellThroughFrom: nil))
    }

    @Test func explicitPickThatCannotDoTheTaskFallsThrough() {
        let snap = Self.snapshot([.appleOnDevice, .claudeCode])
        #expect(ProviderResolver.resolve(task: .summary, pick: .appleOnDevice, snapshot: snap)
                == .provider(.claudeCode, fellThroughFrom: .appleOnDevice))
        #expect(ProviderResolver.resolve(task: .dictation, pick: .appleOnDevice, snapshot: snap)
                == .provider(.appleOnDevice, fellThroughFrom: nil))
    }

    @Test func explicitUnavailablePickIsReportedNotReplaced() {
        let snap = Self.snapshot([.openRouter])
        #expect(ProviderResolver.resolve(task: .summary, pick: .claudeCode, snapshot: snap)
                == .unavailable(.claudeCode, reason: "Not installed"))
    }

    @Test func fallThroughWithNothingElseIsNone() {
        let snap = Self.snapshot([.appleOnDevice])
        #expect(ProviderResolver.resolve(task: .summary, pick: .appleOnDevice, snapshot: snap) == .none)
    }
}
