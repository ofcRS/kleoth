import Testing
@testable import KleothCore

@Suite struct AIProviderTests {
    @Test func rawValuesAreTheStoredIds() {
        #expect(AIProvider.claudeCode.rawValue == "claude-code")
        #expect(AIProvider.appleOnDevice.rawValue == "apple")
        #expect(AIProvider.localServer.rawValue == "local")
    }

    @Test func taskSupport() {
        #expect(AIProvider.codex.supports(.summary))
        #expect(!AIProvider.codex.supports(.dictation))
        #expect(AIProvider.appleOnDevice.supports(.dictation))
        #expect(!AIProvider.appleOnDevice.supports(.summary))
        for provider in [AIProvider.openRouter, .localServer, .claudeCode] {
            #expect(provider.supports(.summary) && provider.supports(.dictation))
        }
    }

    @Test func autoOrderIsTheSpecOrder() {
        #expect(AIProvider.autoOrder == [.localServer, .claudeCode, .codex, .openRouter, .appleOnDevice])
    }

    @Test func defaultModels() {
        #expect(AIProvider.openRouter.defaultModel(for: .summary) == ModelCatalog.defaultModel)
        #expect(AIProvider.openRouter.defaultModel(for: .dictation) == DictationDefaults.polishModel)
        #expect(AIProvider.claudeCode.defaultModel(for: .summary) == "sonnet")
        #expect(AIProvider.claudeCode.defaultModel(for: .dictation) == "haiku")
        #expect(AIProvider.codex.defaultModel(for: .summary) == "")
        #expect(AIProvider.localServer.defaultModel(for: .summary) == "")
        #expect(AIProvider.appleOnDevice.defaultModel(for: .dictation) == "apple-on-device")
    }

    @Test func parseAcceptsIdsAndTreatsAutoAsNil() {
        #expect(AIProvider.parse("claude-code") == .claudeCode)
        #expect(AIProvider.parse("auto") == nil)
        #expect(AIProvider.parse("") == nil)
        #expect(AIProvider.parse(nil) == nil)
        #expect(AIProvider.parse("bogus") == nil)
    }
}
