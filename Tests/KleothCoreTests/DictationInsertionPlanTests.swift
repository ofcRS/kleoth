import Testing
import Foundation
@testable import KleothCore

@Suite struct DictationInsertionPlanTests {
    private typealias Plan = DictationInsertionPlan

    private let selectionChanged = "The selection changed — pasted the dictation on its own"
    private let unreadable = "Replaced the selection — it couldn't be read (⌘Z undoes)"
    private let fenced = "Couldn't merge this selection — added the dictation after it"
    private let tooLong = "Selection too long to merge — added the dictation after it"
    private let cantMerge = "Apple on-device can't merge — added the dictation after the selection"
    private let shortSkip = "Pasted as heard — dictations under 24 words skip the clean-up pass."

    /// A context as the policy builds it, its boundary judged from `before`; each test sets only what
    /// its case is about.
    private func field(
        _ placement: DictationPlacement, before: String = "", after: String = "", selection: String = "",
        verdict: DictationFieldContext.SelectionVerdict = .merge, singleLine: Bool = false
    ) -> DictationFieldContext {
        DictationFieldContext(
            placement: placement, before: before, after: after, selection: selection,
            verdict: verdict, isSingleLine: singleLine, boundary: DictationContextFit.boundary(before: before)
        )
    }

    /// "Let's meet on Monday." with "Monday" selected (manual checklist 3).
    private var monday: DictationFieldContext {
        field(.selection, before: "Let's meet on ", after: ".", selection: "Monday")
    }

    /// What the model makes of "Tuesday at eleven" dictated over "Monday".
    private let mergedMonday = DictationPolishResult.polished(text: "Tuesday at 11", language: "en", cost: 0.0006)

    /// Every re-check `decide` can be given.
    private let everyRecheck: [Plan.Recheck] = [
        .notNeeded, .unavailable, .unchanged(before: "is ", after: "then"), .changed(before: "Done. ", after: ""),
    ]

    @Test func noContextPastesThePolishAsToday() {
        // Setting off, nothing readable, another app at release: the polish result exactly as today,
        // whatever the re-check says, never fitted or trimmed.
        let results: [DictationPolishResult] = [
            .polished(text: "Let's ship it on Friday.", language: "en", cost: 0.0006),
            .raw(text: "lets ship it on friday", reason: "Polish timed out — pasted the raw transcript."),
            .skipped(text: " Ship it on Friday. ", reason: shortSkip),
        ]
        for polish in results {
            for recheck in everyRecheck {
                #expect(Plan.decide(context: nil, polish: polish, rawText: "lets ship it on friday", recheck: recheck)
                    == Plan(text: polish.text, warning: nil, replacedText: nil, outcome: nil), "\(polish) \(recheck)")
            }
        }
    }

    @Test func unchangedSelectionPastesTheMerge() {
        let plan = Plan.decide(
            context: monday, polish: mergedMonday, rawText: "Tuesday at eleven",
            recheck: .unchanged(before: "Let's meet on ", after: ".")
        )
        #expect(plan == Plan(text: "Tuesday at 11", warning: nil, replacedText: "Monday", outcome: .merged))
        // The merged piece goes back inside the selection's own outer whitespace: a line selected with
        // its line break keeps the break. The neighbours play no part.
        let line = field(.selection, before: "- Fix the login bug\n", after: "- Ship", selection: "- Update the docs\n")
        let list = Plan.decide(
            context: line, polish: .polished(text: "- Update the docs and the README", language: "en", cost: 0.0006),
            rawText: "and the readme", recheck: .unchanged(before: "the login bug\n", after: "- Ship")
        )
        #expect(list == Plan(
            text: "- Update the docs and the README\n", warning: nil, replacedText: "- Update the docs\n", outcome: .merged
        ))
    }

    @Test func changedSelectionPastesTheDictationAlone() {
        // The user clicked elsewhere while it transcribed: pasting the merge would put a second copy of
        // the selection's sentence at the new caret. So the dictation goes in alone, as heard, fitted to
        // the new neighbours.
        let plan = Plan.decide(
            context: monday, polish: mergedMonday, rawText: "Tuesday at eleven",
            recheck: .changed(before: "See you", after: "then")
        )
        #expect(plan == Plan(
            text: " Tuesday at eleven ", warning: selectionChanged, replacedText: nil, outcome: .selectionChanged
        ))
        // At a sentence start it gets a capital and no space; a single-line field gets one line.
        let search = field(.selection, before: "Find ", selection: "Monday", singleLine: true)
        #expect(Plan.decide(
            context: search, polish: mergedMonday, rawText: "tuesday\nat eleven", recheck: .changed(before: "Done. ", after: "")
        ).text == "Tuesday at eleven")
        // A failed merge too, and one cut short with Esc (the controller's skip): the selection they
        // would go after isn't where the caret is any more, and the changed selection outranks both.
        let failed = DictationPolishResult.raw(
            text: "Tuesday at eleven", reason: "Polish timed out — added the dictation after the selection."
        )
        let escaped = DictationPolishResult.skipped(text: "Tuesday at eleven", reason: "Cancelled with Esc — pasted as heard.")
        for polish in [failed, escaped] {
            #expect(Plan.decide(
                context: monday, polish: polish, rawText: "Tuesday at eleven", recheck: .changed(before: "", after: "")
            ) == Plan(
                text: "Tuesday at eleven", warning: selectionChanged, replacedText: nil, outcome: .selectionChanged
            ), "\(polish)")
        }
    }

    @Test func unavailableRecheckStillPastesTheMerge() {
        // The re-check timed out (a hung app): treated as unchanged, so the merge goes in.
        let expected = Plan(text: "Tuesday at 11", warning: nil, replacedText: "Monday", outcome: .merged)
        #expect(Plan.decide(context: monday, polish: mergedMonday, rawText: "Tuesday at eleven", recheck: .unavailable) == expected)
        // So does a re-check that never ran.
        #expect(Plan.decide(context: monday, polish: mergedMonday, rawText: "Tuesday at eleven", recheck: .notNeeded) == expected)
    }

    @Test func failedMergeAppendsTheRawDictation() {
        // The merge failed (HTTP error, timeout, a guard): nothing is lost. The selection goes back with
        // the raw dictation after it, and the pill shows the polisher's own reason: the plan adds none.
        let context = field(.selection, selection: "Add a retry to the Scribe upload.")
        let failed = DictationPolishResult.raw(
            text: "And log every failed attempt.", reason: "Polish timed out — added the dictation after the selection."
        )
        for recheck in [Plan.Recheck.unchanged(before: "", after: ""), .unavailable, .notNeeded] {
            #expect(Plan.decide(context: context, polish: failed, rawText: "And log every failed attempt.", recheck: recheck)
                == Plan(
                    text: "Add a retry to the Scribe upload. And log every failed attempt.",
                    warning: nil, replacedText: nil, outcome: .appended
                ), "\(recheck)")
        }
        // A selected list gets the dictation on a line of its own.
        let list = field(.selection, selection: "- Fix the login bug\n- Update the docs")
        let offline = DictationPolishResult.raw(
            text: "Ping the design team", reason: "Polish failed (offline) — added the dictation after the selection."
        )
        #expect(Plan.decide(context: list, polish: offline, rawText: "Ping the design team", recheck: .unavailable)
            .text == "- Fix the login bug\n- Update the docs\nPing the design team")
    }

    @Test func escDuringAMergeAppendsWithoutAWarning() {
        // Esc while polishing a merge: the selection with the dictation as heard after it, and `.done`.
        // Neither the polisher's "Cancelled." nor the controller's skip gets a warning from the plan.
        let context = field(.selection, before: "Plan: ", selection: "Refactor the export module.")
        let cancelled: [DictationPolishResult] = [
            .raw(text: "Make it stream the file.", reason: "Cancelled."),
            .skipped(text: "Make it stream the file.", reason: "Cancelled with Esc — pasted as heard."),
        ]
        for polish in cancelled {
            #expect(Plan.decide(
                context: context, polish: polish, rawText: "Make it stream the file.",
                recheck: .unchanged(before: "Plan: ", after: "")
            ) == Plan(
                text: "Refactor the export module. Make it stream the file.", warning: nil, replacedText: nil, outcome: .appended
            ), "\(polish)")
        }
    }

    @Test func overCapSelectionAppendsThePolishedDictation() {
        // Over 4,000 characters: the selection stays, the dictation polished as if typed at its end goes
        // after it, and the pill says why it wasn't merged.
        let long = String(repeating: "Step one. ", count: 450) + "Step two."
        let context = field(.selection, before: "Plan: ", after: " Today.", selection: long, verdict: .append(tooLong))
        let plan = Plan.decide(
            context: context, polish: .polished(text: "Then ship it.", language: "en", cost: 0.0006),
            rawText: "then ship it", recheck: .unchanged(before: "Plan: ", after: " Today.")
        )
        #expect(plan == Plan(text: long + " Then ship it.", warning: tooLong, replacedText: nil, outcome: .appended))
    }

    @Test func appendVerdictShowsItsReason() {
        // Whatever became of the polish — polished, failed, or skipped by the gate — an appended
        // selection's own reason is the pill's warning: it says why the selection wasn't merged.
        let results: [DictationPolishResult] = [
            .polished(text: "And keep it short.", language: "en", cost: 0.0006),
            .raw(text: "and keep it short", reason: "Polish timed out — added the dictation after the selection."),
            .skipped(text: "and keep it short", reason: shortSkip),
        ]
        for reason in [fenced, tooLong, cantMerge] {
            let context = field(.selection, selection: "Refactor the export module.", verdict: .append(reason))
            for polish in results {
                #expect(Plan.decide(context: context, polish: polish, rawText: "and keep it short", recheck: .unavailable)
                    == Plan(
                        text: "Refactor the export module. " + polish.text, warning: reason, replacedText: nil, outcome: .appended
                    ), "\(reason) \(polish)")
            }
        }
    }

    @Test func unreadableSelectionIsReplacedWithAWarning() {
        // A selection that couldn't be read, or is over 20,000 characters: the dictation replaces it as
        // it always has, with the warning, and the re-check changes nothing (R6).
        let context = field(.selection, before: "Let's meet on ", after: ".", verdict: .replace(unreadable))
        for recheck in everyRecheck {
            #expect(Plan.decide(context: context, polish: mergedMonday, rawText: "Tuesday at eleven", recheck: recheck)
                == Plan(text: "Tuesday at 11", warning: unreadable, replacedText: nil, outcome: .replaced), "\(recheck)")
        }
        // A failed polish pastes its raw text as today, not fitted; the plan's warning is the one shown.
        #expect(Plan.decide(
            context: context, polish: .raw(text: "tuesday at eleven", reason: "Polish timed out — pasted the raw transcript."),
            rawText: "tuesday at eleven", recheck: .unchanged(before: "Let's meet on ", after: ".")
        ) == Plan(text: "tuesday at eleven", warning: unreadable, replacedText: nil, outcome: .replaced))
    }

    @Test func cursorTextIsFittedToTheLiveNeighbours() {
        // The snapshot saw a field start (a capital, no space); by the paste the text before the caret
        // reads "…is ". The live neighbours decide: no capital, no leading space.
        let empty = field(.cursor)
        #expect(empty.boundary == .fieldStart)
        let heard = "That we parse the whole file."
        let polish = DictationPolishResult.polished(text: "that we parse the whole file.", language: "en", cost: 0.0006)
        for recheck in [Plan.Recheck.unchanged(before: "is ", after: ""), .changed(before: "is ", after: "")] {
            #expect(Plan.decide(context: empty, polish: polish, rawText: heard, recheck: recheck)
                == Plan(text: "that we parse the whole file.", warning: nil, replacedText: nil, outcome: .cursor), "\(recheck)")
        }
        // A word on either side gets its space.
        #expect(Plan.decide(context: empty, polish: polish, rawText: heard, recheck: .changed(before: "is", after: "for now"))
            .text == " that we parse the whole file. ")
        // With no live text (the re-check timed out, or never ran), the snapshot's neighbours: a field start.
        for recheck in [Plan.Recheck.unavailable, .notNeeded] {
            #expect(Plan.decide(context: empty, polish: polish, rawText: heard, recheck: recheck)
                .text == "That we parse the whole file.", "\(recheck)")
        }
        // A failed polish pastes the raw text, fitted the same way (Scribe's capital stays: only a model
        // lowercases), and its own warning applies.
        let midSentence = field(.cursor, before: "I think the problem is", after: " for now.")
        let failed = DictationPolishResult.raw(text: heard, reason: "Polish timed out — pasted the raw transcript.")
        #expect(Plan.decide(context: midSentence, polish: failed, rawText: heard, recheck: .unavailable)
            == Plan(text: " That we parse the whole file.", warning: nil, replacedText: nil, outcome: .cursor))
        // A single-line field gets one line.
        let search = field(.cursor, before: "Find ", singleLine: true)
        #expect(Plan.decide(
            context: search, polish: .skipped(text: "first line\nsecond line", reason: shortSkip),
            rawText: "first line\nsecond line", recheck: .unchanged(before: "Find ", after: "")
        ).text == "first line second line")
    }

    @Test func referenceIsPastedAsToday() {
        // A terminal selection was only a reference: the dictation goes to the terminal's input exactly as
        // the polish left it, never fitted to the text around the selection.
        let context = field(.reference, selection: "error: cannot find 'parseMeetingErrors' in scope")
        let heard = "fix the parse meeting errors function"
        let results: [DictationPolishResult] = [
            .polished(text: "Fix the parseMeetingErrors function — it can't be found.", language: "en", cost: 0.0006),
            .raw(text: heard, reason: "Polish timed out — pasted the raw transcript."),
            .skipped(text: heard, reason: shortSkip),
        ]
        for polish in results {
            for recheck in everyRecheck {
                #expect(Plan.decide(context: context, polish: polish, rawText: heard, recheck: recheck)
                    == Plan(text: polish.text, warning: nil, replacedText: nil, outcome: .reference), "\(polish) \(recheck)")
            }
        }
    }

    @Test func changedAppendAlsoPastesTheDictationAlone() {
        // An appended selection that changed: putting it back with the dictation after it would copy it
        // to the new caret. So the dictation goes in alone, as heard, fitted there — polished or not (R6).
        let long = String(repeating: "Step one. ", count: 450) + "Step two."
        let context = field(.selection, before: "Plan: ", selection: long, verdict: .append(tooLong))
        let results: [DictationPolishResult] = [
            .polished(text: "Then ship it.", language: "en", cost: 0.0006),
            .raw(text: "then ship it", reason: "Polish timed out — added the dictation after the selection."),
        ]
        let alone = Plan(text: " then ship it", warning: selectionChanged, replacedText: nil, outcome: .selectionChanged)
        for polish in results {
            #expect(Plan.decide(
                context: context, polish: polish, rawText: "then ship it", recheck: .changed(before: "Notes:", after: "")
            ) == alone, "\(polish)")
        }
        // The same for a merge demoted because the provider can't merge.
        let apple = monday.appendingInstead(because: cantMerge)
        #expect(Plan.decide(
            context: apple, polish: .polished(text: "Tuesday at eleven.", language: "en", cost: 0),
            rawText: "tuesday at eleven", recheck: .changed(before: "", after: "")
        ) == Plan(text: "Tuesday at eleven", warning: selectionChanged, replacedText: nil, outcome: .selectionChanged))
    }

    @Test func outcomeRawValuesAreTheStoredStrings() {
        let stored: [(outcome: Plan.Outcome, value: String)] = [
            (.cursor, "cursor"), (.merged, "merged"), (.appended, "appended"),
            (.replaced, "replaced"), (.reference, "reference"), (.selectionChanged, "selection_changed"),
        ]
        for (outcome, value) in stored {
            #expect(outcome.rawValue == value)
            #expect(Plan.Outcome(rawValue: value) == outcome)
        }
        // The Swift name is not a stored value.
        #expect(Plan.Outcome(rawValue: "selectionChanged") == nil)
    }

    @Test func cursorContextCarryingAnAppendVerdictIsStillACursor() throws {
        // The caret an appended selection becomes in the prompt keeps its `.append` verdict. The
        // controller passes the paste context, never that one, but given it the plan treats it as the
        // caret it is: fitted, no warning, and no selection to append to.
        let long = String(repeating: "Step one. ", count: 450) + "Then ships"
        let append = field(.selection, before: "Plan: ", after: " today.", selection: long, verdict: .append(tooLong))
        let caret = try #require(append.promptContext(providerSupportsContext: true))
        #expect(caret.placement == .cursor)
        #expect(caret.verdict == .append(tooLong))
        let polish = DictationPolishResult.polished(text: "and then we celebrate", language: "en", cost: 0.0006)
        let expected = Plan(text: " and then we celebrate", warning: nil, replacedText: nil, outcome: .cursor)
        let rechecks: [Plan.Recheck] = [
            .unchanged(before: "Then ships", after: " today."), .changed(before: "Then ships", after: " today."), .unavailable,
        ]
        for recheck in rechecks {
            #expect(Plan.decide(context: caret, polish: polish, rawText: "and then we celebrate", recheck: recheck)
                == expected, "\(recheck)")
        }
        // Whatever verdict a caret carries, it is a caret.
        for verdict in [DictationFieldContext.SelectionVerdict.merge, .append(fenced), .replace(unreadable)] {
            let other = field(.cursor, before: "Then ships", after: " today.", verdict: verdict)
            #expect(Plan.decide(context: other, polish: polish, rawText: "and then we celebrate", recheck: .unavailable)
                == expected, "\(verdict)")
        }
    }
}
