import Testing
import Foundation
@testable import KleothCore

@Suite struct PolishGateTests {
    private let short = "привет, буду через десять минут, закажи кофе"
    private let long = String(repeating: "add a retry to the recording controller and rerun the suite ", count: 4)

    @Test func chatAppsAlwaysSkipWhateverTheLength() {
        #expect(PolishGate.decide(rawText: long, style: .chat, alwaysPolish: false) != .polish)
        #expect(PolishGate.decide(rawText: short, style: .chat, alwaysPolish: false) != .polish)
    }

    @Test func shortUtterancesSkipInEveryOtherMode() {
        #expect(PolishGate.wordCount(short) < DictationDefaults.minimumWordsToPolish)
        #expect(PolishGate.decide(rawText: short, style: .compose, alwaysPolish: false) != .polish)
        #expect(PolishGate.decide(rawText: short, style: .terminal, alwaysPolish: false) != .polish)
    }

    @Test func longComposeAndTerminalInputStillPolishes() {
        #expect(PolishGate.wordCount(long) >= DictationDefaults.minimumWordsToPolish)
        #expect(PolishGate.decide(rawText: long, style: .compose, alwaysPolish: false) == .polish)
        #expect(PolishGate.decide(rawText: long, style: .terminal, alwaysPolish: false) == .polish)
    }

    @Test func thresholdIsInclusiveAtTheMinimum() {
        let exactly = Array(repeating: "слово", count: DictationDefaults.minimumWordsToPolish).joined(separator: " ")
        let oneLess = Array(repeating: "слово", count: DictationDefaults.minimumWordsToPolish - 1).joined(separator: " ")
        #expect(PolishGate.decide(rawText: exactly, style: .compose, alwaysPolish: false) == .polish)
        #expect(PolishGate.decide(rawText: oneLess, style: .compose, alwaysPolish: false) != .polish)
    }

    @Test func alwaysPolishOverridesBothRules() {
        #expect(PolishGate.decide(rawText: short, style: .chat, alwaysPolish: true) == .polish)
        #expect(PolishGate.decide(rawText: short, style: .compose, alwaysPolish: true) == .polish)
    }

    @Test func skipReasonsAreUserFacingAndDistinct() {
        guard case let .skip(chat) = PolishGate.decide(rawText: long, style: .chat, alwaysPolish: false),
              case let .skip(brief) = PolishGate.decide(rawText: short, style: .compose, alwaysPolish: false)
        else { Issue.record("expected two skips"); return }
        #expect(chat != brief)
        #expect(!chat.isEmpty && !brief.isEmpty)
        #expect(brief.contains("\(DictationDefaults.minimumWordsToPolish)"))
    }

    @Test func wordCountIgnoresRunsOfWhitespaceAndNewlines() {
        #expect(PolishGate.wordCount("  one\n\ntwo   three\t") == 3)
        #expect(PolishGate.wordCount("") == 0)
    }

    @Test func skippedResultIsNeitherPolishedNorAFallback() {
        let result = DictationPolishResult.skipped(text: "as heard", reason: "r")
        #expect(result.text == "as heard")
        #expect(result.usedRawFallback == false)
        #expect(result.ranModel == false)
        #expect(result.fallbackReason == nil)
        #expect(result.cost == 0)
    }
}
