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

    @Test func shortComposeUtterancesSkip() {
        #expect(PolishGate.wordCount(short) < DictationDefaults.minimumWordsToPolish)
        #expect(PolishGate.decide(rawText: short, style: .compose, alwaysPolish: false) != .polish)
    }

    @Test func longComposeInputStillPolishes() {
        #expect(PolishGate.wordCount(long) >= DictationDefaults.minimumWordsToPolish)
        #expect(PolishGate.decide(rawText: long, style: .compose, alwaysPolish: false) == .polish)
        // A terminal is a compose target, so a long prompt into Ghostty polishes.
        #expect(PolishGate.decide(rawText: long, style: AppStyle.classify(bundleId: "com.mitchellh.ghostty"), alwaysPolish: false) == .polish)
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

    // MARK: - Field context (design 2026-09-24-dictation-context §3.8)

    /// Today's two skips, byte for byte: the placement adds none.
    private let chatSkip = PolishGate.Decision.skip(reason: "Pasted as heard — messages into chat apps skip the clean-up pass.")
    private let shortSkip = PolishGate.Decision.skip(reason: "Pasted as heard — dictations under 24 words skip the clean-up pass.")
    private let threeWords = "нет, в полвосьмого"
    private let tooLong = "Selection too long to merge — added the dictation after it"

    /// A field context as the policy makes one, its boundary judged from `before`.
    private func context(
        _ placement: DictationPlacement, before: String = "", selection: String = "",
        verdict: DictationFieldContext.SelectionVerdict = .merge
    ) -> DictationFieldContext {
        DictationFieldContext(
            placement: placement, before: before, after: "", selection: selection,
            verdict: verdict, isSingleLine: false, boundary: DictationContextFit.boundary(before: before)
        )
    }

    @Test func aSelectionAlwaysPolishes() {
        // Only the model can merge a selection with the dictation, so nothing skips one: not a chat
        // app, not three words, not the "Also clean up short dictations" toggle being off.
        #expect(PolishGate.wordCount(threeWords) == 3)
        #expect(PolishGate.decide(rawText: threeWords, style: .chat, alwaysPolish: false, placement: .selection) == .polish)
        for style in AppStyle.allCases {
            for text in [threeWords, short, long] {
                for always in [false, true] {
                    #expect(PolishGate.decide(rawText: text, style: style, alwaysPolish: always, placement: .selection) == .polish,
                            "\(style) \(PolishGate.wordCount(text)) words, toggle \(always)")
                }
            }
        }
    }

    @Test func midSentenceShortComposeDictationsPolish() {
        // Continuing a sentence takes the model (a lowercase first word, no final period before the
        // rest of the sentence), so a short dictation mid-sentence is polished (§9 Q3).
        for text in [threeWords, short] {
            #expect(PolishGate.decide(rawText: text, style: .compose, alwaysPolish: false, placement: .cursor(.midSentence)) == .polish)
        }
        // An appended selection is gated as a caret at its end: here, mid-sentence.
        let append = context(.selection, before: "Plan: ", selection: "Refactor the export module", verdict: .append(tooLong))
        #expect(PolishGate.decide(
            rawText: short, style: .compose, alwaysPolish: false, placement: PolishGate.placement(for: append)
        ) == .polish)
    }

    @Test func sentenceStartShortDictationsStillSkip() {
        // At the start of a field, a line or a sentence, a short dictation is today's short skip; a
        // long one, or the toggle, still polishes.
        for boundary in [DictationContextFit.Boundary.fieldStart, .lineStart, .sentenceStart] {
            let placement = PolishGate.Placement.cursor(boundary)
            #expect(PolishGate.decide(rawText: short, style: .compose, alwaysPolish: false, placement: placement) == shortSkip, "\(boundary)")
            #expect(PolishGate.decide(rawText: long, style: .compose, alwaysPolish: false, placement: placement) == .polish, "\(boundary)")
            #expect(PolishGate.decide(rawText: short, style: .compose, alwaysPolish: true, placement: placement) == .polish, "\(boundary)")
        }
        // An appended selection that ends a sentence, too.
        let append = context(.selection, before: "Plan: ", selection: "Refactor the export module.", verdict: .append(tooLong))
        #expect(PolishGate.decide(
            rawText: short, style: .compose, alwaysPolish: false, placement: PolishGate.placement(for: append)
        ) == shortSkip)
    }

    @Test func chatAppCursorContextStillSkips() {
        // A message into a chat app is pasted as heard wherever the caret sits, mid-sentence included:
        // the chat rule comes before the caret's. The toggle still polishes it.
        for boundary in [DictationContextFit.Boundary.fieldStart, .lineStart, .sentenceStart, .midSentence] {
            for text in [threeWords, short, long] {
                #expect(PolishGate.decide(rawText: text, style: .chat, alwaysPolish: false, placement: .cursor(boundary)) == chatSkip,
                        "\(boundary) \(PolishGate.wordCount(text)) words")
            }
            #expect(PolishGate.decide(rawText: short, style: .chat, alwaysPolish: true, placement: .cursor(boundary)) == .polish,
                    "\(boundary)")
        }
    }

    @Test func referenceKeepsTodaysRules() {
        // A terminal selection is a spelling reference, not a place in a sentence: the dictation is
        // gated exactly as without field context (`.none`, also a replaced selection's placement).
        for style in AppStyle.allCases {
            for text in [threeWords, short, long] {
                for always in [false, true] {
                    let today = PolishGate.decide(rawText: text, style: style, alwaysPolish: always)
                    #expect(PolishGate.decide(rawText: text, style: style, alwaysPolish: always, placement: .reference) == today,
                            "\(style) \(PolishGate.wordCount(text)) words, toggle \(always)")
                    #expect(PolishGate.decide(rawText: text, style: style, alwaysPolish: always, placement: .none) == today,
                            "\(style) \(PolishGate.wordCount(text)) words, toggle \(always)")
                }
            }
        }
        // Today's reasons.
        #expect(PolishGate.decide(rawText: long, style: .chat, alwaysPolish: false, placement: .reference) == chatSkip)
        #expect(PolishGate.decide(rawText: short, style: .compose, alwaysPolish: false, placement: .reference) == shortSkip)
    }

    @Test func placementFollowsTheVerdict() throws {
        // No context — the setting off, nothing readable: today's rules.
        #expect(PolishGate.placement(for: nil) == PolishGate.Placement.none)
        // A caret: where it sits.
        #expect(PolishGate.placement(for: context(.cursor, before: "I think the problem is")) == .cursor(.midSentence))
        #expect(PolishGate.placement(for: context(.cursor, before: "Done. ")) == .cursor(.sentenceStart))
        #expect(PolishGate.placement(for: context(.cursor)) == .cursor(.fieldStart))
        // A terminal selection: a reference.
        #expect(PolishGate.placement(for: context(.reference, selection: "error: cannot find 'parseMeetingErrors' in scope")) == .reference)
        // A selection to merge.
        #expect(PolishGate.placement(for: context(.selection, before: "Let's meet on ", selection: "Monday")) == .selection)
        // An appended selection: a caret at its end, whatever its start.
        let midSentence = context(.selection, before: "Done. ", selection: "Refactor the export", verdict: .append(tooLong))
        #expect(midSentence.boundary == .sentenceStart)
        #expect(PolishGate.placement(for: midSentence) == .cursor(.midSentence))
        let sentenceEnd = context(.selection, before: "I think", selection: " we should ship.", verdict: .append(tooLong))
        #expect(sentenceEnd.boundary == .midSentence)
        #expect(PolishGate.placement(for: sentenceEnd) == .cursor(.sentenceStart))
        // The caret the prompt gets for an appended selection is gated the same.
        for append in [midSentence, sentenceEnd] {
            let caret = try #require(append.promptContext(providerSupportsContext: true))
            #expect(PolishGate.placement(for: caret) == PolishGate.placement(for: append))
        }
        // A replaced selection — it couldn't be read: today's rules.
        let unreadable = "Replaced the selection — it couldn't be read (⌘Z undoes)"
        let replaced = context(.selection, before: "Let's meet on ", verdict: .replace(unreadable))
        #expect(PolishGate.placement(for: replaced) == PolishGate.Placement.none)
    }
}
