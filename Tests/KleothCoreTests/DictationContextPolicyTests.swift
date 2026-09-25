import Testing
import Foundation
@testable import KleothCore

@Suite struct DictationContextPolicyTests {
    private typealias Policy = DictationContextPolicy

    private let unreadable = "Replaced the selection — it couldn't be read (⌘Z undoes)"
    private let fenced = "Couldn't merge this selection — added the dictation after it"
    private let tooLong = "Selection too long to merge — added the dictation after it"

    /// What the reader reports for a field holding `before + selected + after`, with `selected`
    /// selected (a caret when it is empty): the windows are the read plan's, taken from the field in
    /// UTF-16 units the way `AXStringForRange` takes them.
    private func read(
        _ before: String, _ selected: String = "", _ after: String = "",
        bundleId: String? = "com.apple.TextEdit", role: String? = "AXTextArea"
    ) -> DictationFieldFacts {
        let field = Array((before + selected + after).utf16)
        let selection = DictationTextRange(location: before.utf16.count, length: selected.utf16.count)
        let plan = Policy.readPlan(selection: selection, characterCount: field.count)
        func text(_ range: DictationTextRange) -> String {
            let start = min(max(0, range.location), field.count)
            let end = min(max(start, range.end), field.count)
            return String(decoding: field[start..<end], as: UTF16.self)
        }
        return DictationFieldFacts(
            processIdentifier: 4242, bundleId: bundleId, role: role, subrole: nil, isEditable: true,
            characterCount: field.count, selection: selection, selectedText: text(selection),
            textBefore: text(plan.before), textAfter: text(plan.after), placeholder: nil
        )
    }

    /// The context the app builds from `facts`: the element's kind first, then the policy.
    private func context(_ facts: DictationFieldFacts) -> DictationFieldContext? {
        let kind = Policy.elementKind(
            bundleId: facts.bundleId, role: facts.role, subrole: facts.subrole,
            isEditable: facts.isEditable, isKleoth: false
        )
        return Policy.context(from: facts, kind: kind)
    }

    @Test func secureSubroleIsNeverRead() {
        // A password field is skipped wherever it is: in any app, a terminal included, and editable.
        for bundleId in ["com.apple.TextEdit", "com.google.Chrome", "com.mitchellh.ghostty", nil] as [String?] {
            for role in ["AXTextField", "AXTextArea"] {
                #expect(Policy.elementKind(
                    bundleId: bundleId, role: role, subrole: "AXSecureTextField", isEditable: true, isKleoth: false
                ) == .skip("secure field"), "\(bundleId ?? "nil") \(role)")
            }
        }
        // Nothing comes out of a skipped element, however much the facts hold.
        var facts = read("user@example.com ", "hunter2", " sign in")
        facts.subrole = "AXSecureTextField"
        #expect(context(facts) == nil)
        #expect(Policy.context(from: facts, kind: .skip("secure field")) == nil)
    }

    @Test func terminalsAreReferencesWhateverTheirRole() {
        // Ghostty's surface is an editable AXTextArea, as an editor's is: the bundle id decides first.
        #expect(Policy.elementKind(
            bundleId: "com.mitchellh.ghostty", role: "AXTextArea", subrole: nil, isEditable: true, isKleoth: false
        ) == .terminal)
        // Every listed terminal, in its real casing, whatever its element reports.
        let terminals = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
            "io.alacritty", "org.alacritty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        ]
        let elements: [(role: String?, isEditable: Bool)] = [
            ("AXTextArea", true), ("AXTextArea", false), ("AXStaticText", false), (nil, false),
        ]
        for bundleId in terminals {
            for element in elements {
                #expect(Policy.elementKind(
                    bundleId: bundleId, role: element.role, subrole: nil, isEditable: element.isEditable, isKleoth: false
                ) == .terminal, "\(bundleId) \(element.role ?? "nil") \(element.isEditable)")
            }
        }
        #expect(Policy.terminalBundleIds == Set(terminals.map { $0.lowercased() }))
        // So a selection there is a reference, never text to merge.
        #expect(context(read("$ swift build\n", "parseMeetingErrors", "\n$ ", bundleId: "com.mitchellh.ghostty"))?.placement == .reference)
    }

    @Test func excludedAppsAndKleothAreSkipped() {
        let excluded = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
            "com.apple.Passwords", "com.apple.keychainaccess",
        ]
        for bundleId in excluded {
            #expect(Policy.elementKind(
                bundleId: bundleId, role: "AXTextArea", subrole: nil, isEditable: true, isKleoth: false
            ) == .skip("excluded app"), "\(bundleId)")
        }
        #expect(Policy.excludedBundleIds == Set(excluded.map { $0.lowercased() }))
        #expect(context(read("Vault note: ", "the recovery code", "", bundleId: "com.1password.1password")) == nil)
        // Kleoth's own windows are never read, even an editable text area, and that rule comes first.
        #expect(Policy.elementKind(
            bundleId: "dev.kleoth.app", role: "AXTextArea", subrole: nil, isEditable: true, isKleoth: true
        ) == .skip("Kleoth"))
        #expect(Policy.elementKind(
            bundleId: "com.mitchellh.ghostty", role: "AXTextArea", subrole: nil, isEditable: true, isKleoth: true
        ) == .skip("Kleoth"))
        // An excluded app is skipped before its fields are looked at.
        #expect(Policy.elementKind(
            bundleId: "com.bitwarden.desktop", role: "AXTextField", subrole: "AXSecureTextField", isEditable: true, isKleoth: false
        ) == .skip("excluded app"))
    }

    @Test func secureFieldsAndExcludedAppsGiveNoContextWhateverTheKind() {
        // Defense in depth: should a caller pass a kind that disagrees with the facts, the facts still
        // decide — a password field or a password manager is never read.
        let kinds: [Policy.ElementKind] = [.text(singleLine: false), .text(singleLine: true), .terminal]
        var secure = read("user@example.com ", "hunter2", " sign in", role: "AXTextField")
        secure.subrole = "AXSecureTextField"
        var secureCaret = read("hunter", "", "2", role: "AXTextField")
        secureCaret.subrole = "AXSecureTextField"
        for kind in kinds {
            #expect(Policy.context(from: secure, kind: kind) == nil, "\(kind)")
            #expect(Policy.context(from: secureCaret, kind: kind) == nil, "\(kind)")
        }
        // Bundle ids in their real casing, matched as `elementKind` matches them.
        let excluded = [
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
            "com.apple.Passwords", "com.apple.keychainaccess", " COM.APPLE.KEYCHAINACCESS ",
        ]
        for bundleId in excluded {
            let vault = read("Vault note: ", "the recovery code", " end", bundleId: bundleId)
            let vaultCaret = read("Vault note: the recovery code", "", "", bundleId: bundleId)
            for kind in kinds {
                #expect(Policy.context(from: vault, kind: kind) == nil, "\(bundleId) \(kind)")
                #expect(Policy.context(from: vaultCaret, kind: kind) == nil, "\(bundleId) \(kind)")
            }
        }
        // Any other app's facts still follow the kind they are given.
        #expect(Policy.context(from: read("Note: ", "the plan", " end"), kind: .text(singleLine: false))?.placement == .selection)
        #expect(Policy.context(from: read("Note: ", "the plan", " end"), kind: .terminal)?.placement == .reference)
    }

    @Test func onlyEditableTextRolesCount() {
        func kind(_ role: String?, editable: Bool = true, subrole: String? = nil) -> Policy.ElementKind {
            Policy.elementKind(bundleId: "com.apple.TextEdit", role: role, subrole: subrole, isEditable: editable, isKleoth: false)
        }
        #expect(kind("AXTextArea") == .text(singleLine: false))
        #expect(kind("AXTextField") == .text(singleLine: true))
        #expect(kind("AXComboBox") == .text(singleLine: true))
        #expect(kind("AXTextField", subrole: "AXSearchField") == .text(singleLine: true))
        // Other roles are not text, even when their value is settable.
        for role in ["AXStaticText", "AXWebArea", "AXButton", "AXGroup"] {
            #expect(kind(role) == .skip("not editable text"), "\(role)")
        }
        #expect(kind(nil) == .skip("not editable text"))
        // A text role that can't be edited is a label, not a field.
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            #expect(kind(role, editable: false) == .skip("not editable text"), "\(role)")
        }
        // An app nobody listed, or no bundle id at all, is judged by its element alone.
        #expect(Policy.elementKind(
            bundleId: "com.t3tools.t3code", role: "AXTextArea", subrole: nil, isEditable: true, isKleoth: false
        ) == .text(singleLine: false))
        #expect(Policy.elementKind(
            bundleId: nil, role: "AXTextField", subrole: nil, isEditable: true, isKleoth: false
        ) == .text(singleLine: true))
    }

    @Test func readPlanClampsAtTheFieldEdges() {
        func plan(_ location: Int, _ length: Int, count: Int) -> (before: DictationTextRange, after: DictationTextRange) {
            Policy.readPlan(selection: DictationTextRange(location: location, length: length), characterCount: count)
        }
        func range(_ location: Int, _ length: Int) -> DictationTextRange {
            DictationTextRange(location: location, length: length)
        }
        // The windows: 1,500 units before the caret and 500 after it.
        let middle = plan(2_000, 0, count: 3_000)
        #expect(middle.before == range(500, 1_500))
        #expect(middle.after == range(2_000, 500))
        // A caret at the field's start has nothing before it; one at its end, nothing after.
        let start = plan(0, 0, count: 3_000)
        #expect(start.before == range(0, 0))
        #expect(start.after == range(0, 500))
        let end = plan(3_000, 0, count: 3_000)
        #expect(end.before == range(1_500, 1_500))
        #expect(end.after == range(3_000, 0))
        // A selection that ends the field: the windows sit on either side of it.
        let selection = plan(2_990, 10, count: 3_000)
        #expect(selection.before == range(1_490, 1_500))
        #expect(selection.after == range(3_000, 0))
        // A short field and an empty one.
        let short = plan(40, 5, count: 100)
        #expect(short.before == range(0, 40))
        #expect(short.after == range(45, 55))
        let empty = plan(0, 0, count: 0)
        #expect(empty.before == range(0, 0))
        #expect(empty.after == range(0, 0))
        // A range reaching past the end (a stale count) is clamped to it, and no length goes negative.
        let past = plan(150, 0, count: 100)
        #expect(past.before == range(0, 100))
        #expect(past.after == range(100, 0))
        let overhanging = plan(90, 20, count: 100)
        #expect(overhanging.before == range(0, 90))
        #expect(overhanging.after == range(100, 0))
        let backwards = plan(50, -10, count: 100)
        #expect(backwards.before == range(0, 50))
        #expect(backwards.after == range(50, 50))
        // NSNotFound (Int.max) as a location is clamped too; nothing overflows.
        let notFound = plan(Int.max, 1, count: 100)
        #expect(notFound.before == range(0, 100))
        #expect(notFound.after == range(100, 0))
    }

    @Test func caretMakesCursorContextAndSelectionMerges() throws {
        #expect(context(read("I think the problem is", "", " for now.")) == DictationFieldContext(
            placement: .cursor, before: "I think the problem is", after: " for now.", selection: "",
            verdict: .merge, isSingleLine: false, boundary: .midSentence
        ))
        // A single-line field says so; the boundary is judged from the text before the caret.
        let search = try #require(context(read("Done. ", role: "AXTextField")))
        #expect(search.isSingleLine)
        #expect(search.boundary == .sentenceStart)
        #expect(context(read(""))?.boundary == .fieldStart)
        #expect(context(read("First line\n"))?.boundary == .lineStart)

        #expect(context(read("Let's meet on ", "Monday", ".")) == DictationFieldContext(
            placement: .selection, before: "Let's meet on ", after: ".", selection: "Monday",
            verdict: .merge, isSingleLine: false, boundary: .midSentence
        ))
        // Select-all merges too (§9 Q7), in a single-line field as anywhere.
        #expect(context(read("", "Встречаемся в 7 у главного входа.", "", role: "AXComboBox")) == DictationFieldContext(
            placement: .selection, before: "", after: "", selection: "Встречаемся в 7 у главного входа.",
            verdict: .merge, isSingleLine: true, boundary: .fieldStart
        ))
        // Without a selection range there is nowhere to place the dictation against.
        var noRange = read("Hello")
        noRange.selection = nil
        #expect(context(noRange) == nil)
    }

    @Test func selectionVerdictFollowsTheCaps() {
        func verdict(selecting count: Int) -> DictationFieldContext.SelectionVerdict? {
            context(read("Before. ", String(repeating: "a", count: count), " After."))?.verdict
        }
        #expect(verdict(selecting: 4_000) == .merge)
        #expect(verdict(selecting: 4_001) == .append(tooLong))
        #expect(verdict(selecting: 20_000) == .append(tooLong))
        #expect(verdict(selecting: 20_001) == .replace(unreadable))
        // Unreadable: no text came back for the range, or none at all.
        var facts = read("Let's meet on ", "Monday", ".")
        facts.selectedText = nil
        #expect(context(facts) == DictationFieldContext(
            placement: .selection, before: "Let's meet on ", after: ".", selection: "",
            verdict: .replace(unreadable), isSingleLine: false, boundary: .midSentence
        ))
        facts.selectedText = ""
        #expect(context(facts)?.verdict == .replace(unreadable))
        // A selection that is only an attachment holds no text to merge.
        #expect(context(read("See ", "\u{FFFC}", " here."))?.verdict == .replace(unreadable))
        // The caps count characters, not UTF-16 units: 4,000 emoji are 8,000 units and still merge.
        #expect(context(read("", String(repeating: "😀", count: 4_000), ""))?.verdict == .merge)
        // A selection of whitespace (the space between two words) is text to merge.
        #expect(context(read("on", " ", "Monday"))?.verdict == .merge)
    }

    @Test func fenceDelimiterDropsCursorContextAndDemotesAMerge() throws {
        // At a caret, a delimiter on either side drops the whole context: the dictation goes in as today.
        #expect(context(read("The prompt starts with <<<TRANSCRIPT and ")) == nil)
        #expect(context(read("Close it with ", "", " AFTER>>> on its own line.")) == nil)
        // A selection holding one is not merged: it stays, the dictation goes after it, and the text
        // around it isn't sent.
        #expect(context(read("Note: ", "wrap it in <<<SELECTION markers", " and go.")) == DictationFieldContext(
            placement: .selection, before: "", after: "", selection: "wrap it in <<<SELECTION markers",
            verdict: .append(fenced), isSingleLine: false, boundary: .midSentence
        ))
        // So is a selection with one beside it.
        let beside = try #require(context(read("It ends at TRANSCRIPT>>> so ", "keep it", " as is.")))
        #expect(beside.verdict == .append(fenced))
        #expect(beside.before == "")
        #expect(beside.after == "")
        #expect(beside.selection == "keep it")
        // The delimiter is checked before the length to merge…
        let long = String(repeating: "word ", count: 1_000) + "REFERENCE>>>"
        #expect(context(read("", long, ""))?.verdict == .append(fenced))
        // …but after the length to read: a selection too long to read is replaced, whatever it holds.
        let unreadablyLong = String(repeating: "a", count: 19_988) + "<<<TRANSCRIPT"
        #expect(unreadablyLong.count == 20_001)
        let replaced = try #require(context(read("Note: ", unreadablyLong, " end.")))
        #expect(replaced.verdict == .replace(unreadable))
        #expect(replaced.selection == "")
    }

    @Test func delimiterInsideTheDroppedPartialWordKeepsTheContext() throws {
        // The check runs on what is sent: a marker inside the partial word the cut drops never
        // reaches the prompt, so the context stays.
        let words = String(repeating: "word ", count: 298)   // 1,490 characters
        let dropped = try #require(context(read("a" + "b<<<AFTER " + words)))
        #expect(dropped.placement == .cursor)
        #expect(dropped.before == "…" + words)
        // A partial word too long to drop stays in the window (R13), and its marker with it: no context.
        let kept = String(repeating: "c", count: 41) + "<<<AFTER"
        #expect(context(read("a" + kept + " " + String(words.prefix(1_500 - kept.count - 1)))) == nil)
    }

    @Test func windowsAreCutAtAWordMarkedAndCleaned() throws {
        // 2,002 units before the caret: the window is the last 1,500, starting inside "consequences".
        let head = String(repeating: "a", count: 494) + " consequ"
        let tail = "ences of this. " + String(repeating: "Then more. ", count: 135)
        // 611 units after it: the window is the first 500, ending inside "Finalizing".
        let next = " " + String(repeating: "Next one. ", count: 49) + "Finalizing the rest." + String(repeating: "x", count: 100)
        let cut = try #require(context(read(head + tail, "", next)))
        #expect(cut.before == "…of this. " + String(repeating: "Then more. ", count: 135))
        #expect(cut.after == " " + String(repeating: "Next one. ", count: 48) + "Next one.…")

        // Windows that reach the field's edges are whole: 1,500 units before, 500 after.
        let whole = try #require(context(read(
            String(repeating: "b", count: 1_499) + " ", "", " " + String(repeating: "c", count: 499)
        )))
        #expect(whole.before == String(repeating: "b", count: 1_499) + " ")
        #expect(whole.after == " " + String(repeating: "c", count: 499))

        // With no character count, a full 500-unit window after the caret is taken as cut — in UTF-16
        // units, so 248 emoji and five letters fill it. (Its last 249 characters are one partial word,
        // too long to drop, so the cut stays where the read made it, R13.)
        let emoji = "ok " + String(repeating: "😀", count: 248) + "z"
        var unknown = read("Hi", "", emoji)
        #expect(context(unknown)?.after == emoji)
        unknown.characterCount = nil
        #expect(context(unknown)?.after == emoji + "…")
        unknown.textAfter = "ok " + String(repeating: "😀", count: 247) + "z"
        #expect(context(unknown)?.after == unknown.textAfter)

        // The boundary comes from the window before its cut, so the "…" never reads as a sentence end;
        // and the cut never leaves "…)" behind, so `before` itself classifies the caret the same way
        // (the paste fits the dictation to it when the re-check can't read the live text).
        let bracket = try #require(context(read(String(repeating: "a", count: 1_600) + " )")))
        #expect(bracket.before != "…)")
        #expect(bracket.before == "…" + String(repeating: "a", count: 1_498) + " )")
        #expect(bracket.boundary == .midSentence)
        #expect(DictationContextFit.boundary(before: bracket.before) == bracket.boundary)
        #expect(DictationContextFit.boundary(before: "…)") == .sentenceStart)
        // A cut that would leave no text keeps the whole window, still marked.
        let token = String(repeating: "x", count: 1_499)
        let url = try #require(context(read("see " + token + " ")))
        #expect(url.before == "…" + token + " ")
        #expect(url.boundary == .midSentence)
        let spaced = try #require(context(read("see " + String(repeating: "x", count: 1_497) + "   ")))
        #expect(spaced.before == "…" + String(repeating: "x", count: 1_497) + "   ")
        let opening = try #require(context(read("Hi", "", " " + String(repeating: "y", count: 499) + "tail")))
        #expect(opening.after == " " + String(repeating: "y", count: 499) + "…")

        // U+FFFC, U+FFFD and the zero-width U+200B and U+FEFF are removed from every string read.
        let cleaned = try #require(context(read("See\u{FFFC} the\u{200B} chart", "", "\u{FEFF} below\u{FFFD}.")))
        #expect(cleaned.before == "See the chart")
        #expect(cleaned.after == " below.")
        #expect(context(read("Meet on ", "Mon\u{200B}day\u{FFFC}", "."))?.selection == "Monday")
        // A zero-width space after a period no longer hides the sentence end.
        #expect(context(read("Done.\u{200B}"))?.boundary == .sentenceStart)
        // A window edge that splits an emoji comes back as U+FFFD, removed like any other.
        let split = try #require(context(read("😀" + String(repeating: "y", count: 1_499))))
        #expect(split.before == "…" + String(repeating: "y", count: 1_499))
    }

    @Test func cutThatWouldLeaveNoLettersOrDigitsKeepsTheWholeWindow() throws {
        // A short partial word goes, but what is left here is only closing brackets: "…)))" reads as a
        // sentence end (the "…") where the caret sits mid-sentence. So the whole window stays, marked.
        let closers = String(repeating: ")", count: 1_497)
        let lisp = try #require(context(read("xx(f " + closers)))
        #expect(lisp.before == "…(f " + closers)
        #expect(lisp.boundary == .midSentence)
        #expect(DictationContextFit.boundary(before: lisp.before) == lisp.boundary)
        // Emoji are no letters either.
        let thumbs = String(repeating: "👍", count: 749)
        #expect(context(read("ab c " + thumbs))?.before == "…c " + thumbs)
        // One digit left is enough: the partial word goes as usual.
        let counted = try #require(context(read("xx(f 1" + String(repeating: ")", count: 1_496))))
        #expect(counted.before == "…1" + String(repeating: ")", count: 1_496))
        #expect(DictationContextFit.boundary(before: counted.before) == counted.boundary)
    }

    @Test func cutDropsAtMostFortyCharactersOfAPartialWord() throws {
        // Chinese and Japanese are written without spaces, so the nearest space can be most of a window
        // away. Past 40 characters of partial word the cut stays where the read made it — at a
        // Character — still marked (R13).
        let cjk = String(repeating: "漢", count: 1_400) + " OK " + String(repeating: "字", count: 200)
        let before = try #require(context(read(cjk)))
        #expect(before.before.count >= 1_400)
        #expect(before.before == "…" + String(repeating: "漢", count: 1_296) + " OK " + String(repeating: "字", count: 200))
        // The same at the far end of the text after the caret…
        let after = try #require(context(read("Hi", "", " see " + String(repeating: "字", count: 600))))
        #expect(after.after == " see " + String(repeating: "字", count: 495) + "…")
        // …for a terminal reference…
        let error = "error: " + String(repeating: "文", count: 1_600)
        let reference = try #require(context(read("$ make\n", error, "\n$ ", bundleId: "com.mitchellh.ghostty")))
        #expect(reference.selection == "error: " + String(repeating: "文", count: 1_493) + "…")
        // …and for the text before the caret an appended selection becomes in the prompt.
        let steps = String(repeating: "步", count: 4_000) + " OK " + String(repeating: "步", count: 100)
        let append = try #require(context(read("Plan: ", steps)))
        #expect(append.verdict == .append(tooLong))
        let prompt = try #require(append.promptContext(providerSupportsContext: true))
        #expect(prompt.before == "…" + String(repeating: "步", count: 1_396) + " OK " + String(repeating: "步", count: 100))

        // Exactly 40 characters of partial word go; a 41st keeps the window whole. At the start of
        // the window before the caret…
        func beforeWindow(startingWith partial: Int) throws -> (cut: String, rest: String, window: String) {
            let rest = String(String(repeating: "word ", count: 300).prefix(1_500 - partial - 1))
            let window = String(repeating: "y", count: partial) + " " + rest
            let cut = try #require(context(read("zz" + window))).before
            return (cut, rest, window)
        }
        let forty = try beforeWindow(startingWith: 40)
        #expect(forty.cut == "…" + forty.rest)
        let fortyOne = try beforeWindow(startingWith: 41)
        #expect(fortyOne.cut == "…" + fortyOne.window)
        // …and at the end of the window after it.
        func afterWindow(endingWith partial: Int) throws -> (cut: String, rest: String, window: String) {
            let rest = String(String(repeating: "word ", count: 100).prefix(500 - partial - 1))
            let window = rest + " " + String(repeating: "z", count: partial)
            let cut = try #require(context(read("Hi", "", window + "zzzzzzzzzz"))).after
            return (cut, rest, window)
        }
        let lastForty = try afterWindow(endingWith: 40)
        #expect(lastForty.cut == lastForty.rest + "…")
        let lastFortyOne = try afterWindow(endingWith: 41)
        #expect(lastFortyOne.cut == lastFortyOne.window + "…")
    }

    @Test func placeholderIsNotContext() {
        let empty = DictationFieldContext(
            placement: .cursor, before: "", after: "", selection: "",
            verdict: .merge, isSingleLine: true, boundary: .fieldStart
        )
        // A field reporting its placeholder as its value is empty, with the caret at either end…
        for (before, after) in [("", "Message #general"), ("Message #general", "")] {
            var facts = read(before, "", after, role: "AXTextField")
            facts.placeholder = "Message #general"
            #expect(context(facts) == empty, "before: \(before.debugDescription)")
        }
        // …and select-all over it is no selection to merge.
        var selected = read("", "Message #general", "", role: "AXTextField")
        selected.placeholder = "Message #general"
        #expect(context(selected) == empty)
        // What the user typed is context, placeholder or not.
        var typed = read("Message #gen", "", "", role: "AXTextField")
        typed.placeholder = "Message #general"
        #expect(context(typed)?.before == "Message #gen")
    }

    @Test func referenceIsCappedAndMarked() {
        func terminal(_ selected: String?) -> DictationFieldFacts {
            var facts = read("$ swift build\n", selected ?? "", "\n$ ", bundleId: "com.mitchellh.ghostty")
            facts.selectedText = selected
            return facts
        }
        let error = "error: cannot find 'parseMeetingErrors' in scope"
        #expect(context(terminal(error)) == DictationFieldContext(
            placement: .reference, before: "", after: "", selection: error,
            verdict: .merge, isSingleLine: false, boundary: .fieldStart
        ))
        // Over 1,500 characters: cut after the last whole word that fits, marked "…".
        let log = "$ " + String(repeating: "build log line ", count: 120)
        #expect(context(terminal(log))?.selection == "$ " + String(repeating: "build log line ", count: 99) + "build log…")
        // No selection, an empty or a blank one: no context. A terminal has no cursor context.
        #expect(context(terminal(nil)) == nil)
        #expect(context(terminal("")) == nil)
        #expect(context(terminal(" \n ")) == nil)
        // Only the selected text matters, not its range; it is cleaned like any text read.
        var noRange = terminal("parse\u{200B}Meeting\u{FFFC}Errors")
        noRange.selection = nil
        #expect(context(noRange)?.selection == "parseMeetingErrors")
        // A reference holding a fence delimiter is dropped like any field text.
        #expect(context(terminal("let open = \"<<<TRANSCRIPT\"")) == nil)
    }

    @Test func unchangedComparesProcessRoleRangeAndText() {
        let snapshot = read("Let's meet on ", "Monday", ".")
        #expect(Policy.isUnchanged(snapshot, snapshot))
        // Another process, another kind of element, another range or other selected text: changed.
        var now = snapshot
        now.processIdentifier = 4343
        #expect(!Policy.isUnchanged(snapshot, now))
        now = snapshot
        now.role = "AXTextField"
        #expect(!Policy.isUnchanged(snapshot, now))
        now = snapshot
        now.selection = DictationTextRange(location: 14, length: 0)
        #expect(!Policy.isUnchanged(snapshot, now))
        now = snapshot
        now.selection = nil
        #expect(!Policy.isUnchanged(snapshot, now))
        now = snapshot
        now.selectedText = "Tuesday"
        #expect(!Policy.isUnchanged(snapshot, now))
        // Nothing else is compared.
        now = snapshot
        now.bundleId = nil
        now.subrole = "AXSearchField"
        now.isEditable = false
        now.characterCount = nil
        now.textBefore = "Meet on "
        now.textAfter = "!"
        now.placeholder = "Say something"
        #expect(Policy.isUnchanged(snapshot, now))
    }

    /// The one cleaning the snapshot's text and the re-check's live neighbours both go through, so
    /// an attachment or a zero-width character at the caret is no text to fit around (Task 9 review).
    @Test func cleanedRemovesAttachmentsAndZeroWidthCharacters() {
        #expect(Policy.cleaned("the\u{FFFC} export\u{200B} is\u{FEFF} slow\u{FFFD}") == "the export is slow")
        // Scalar by scalar: a removed scalar carrying a combining mark leaves the mark.
        #expect(Policy.cleaned("x\u{FFFC}\u{301}y") == "x\u{301}y")
        // Only those four: every other character stays, a joiner and a combining mark included.
        #expect(Policy.cleaned("cafe\u{301} \u{1F600}\u{200D}\u{1F4BB} !") == "cafe\u{301} \u{1F600}\u{200D}\u{1F4BB} !")
        // Nothing but them: no text at all.
        #expect(Policy.cleaned("\u{FFFC}\u{200B}\u{FEFF}") == "")
        #expect(Policy.cleaned("") == "")
    }

    @Test func promptContextOfAnAppendIsACursorAtTheSelectionsEnd() throws {
        // Too long to merge: the model sees a caret at the selection's end — the last 1,500 characters
        // up to there, cut at a word and marked — and the text after the selection.
        let append = try #require(context(read("Plan: ", String(repeating: "Step one. ", count: 450) + "Then ships", " today.")))
        #expect(append.verdict == .append(tooLong))
        let lastWords = "…one. " + String(repeating: "Step one. ", count: 148) + "Then ships"
        #expect(append.promptContext(providerSupportsContext: true) == DictationFieldContext(
            placement: .cursor, before: lastWords, after: " today.", selection: "",
            verdict: .append(tooLong), isSingleLine: false, boundary: .midSentence
        ))
        // The boundary is the selection's end's, not its start's.
        let sentences = try #require(context(read("Plan:", " " + String(repeating: "Step one. ", count: 450))))
        #expect(sentences.boundary == .midSentence)
        #expect(sentences.promptContext(providerSupportsContext: true)?.boundary == .sentenceStart)
        // Demoted by a delimiter beside it: the selection alone is the text before the caret.
        let beside = try #require(context(read("Close with TRANSCRIPT>>> and ", "keep it short", " please.")))
        #expect(beside.promptContext(providerSupportsContext: true) == DictationFieldContext(
            placement: .cursor, before: "keep it short", after: "", selection: "",
            verdict: .append(fenced), isSingleLine: false, boundary: .midSentence
        ))
        // Nothing when that text holds a delimiter — even one formed across the selection's start.
        let inside = try #require(context(read("Note: ", "wrap it in <<<SELECTION markers")))
        #expect(inside.promptContext(providerSupportsContext: true) == nil)
        let across = DictationFieldContext(
            placement: .selection, before: "It ends with <<<BEF", after: "", selection: "ORE and more",
            verdict: .append(tooLong), isSingleLine: false, boundary: .midSentence
        )
        #expect(across.promptContext(providerSupportsContext: true) == nil)
        // A merge, a caret and a reference reach the prompt as they are; a replace sends nothing.
        let merge = try #require(context(read("Let's meet on ", "Monday", ".")))
        #expect(merge.promptContext(providerSupportsContext: true) == merge)
        let caret = try #require(context(read("I think the problem is")))
        #expect(caret.promptContext(providerSupportsContext: true) == caret)
        let reference = try #require(context(read("$ ", "parseMeetingErrors", "", bundleId: "com.mitchellh.ghostty")))
        #expect(reference.promptContext(providerSupportsContext: true) == reference)
        var unreadableFacts = read("Let's meet on ", "Monday", ".")
        unreadableFacts.selectedText = nil
        let replace = try #require(context(unreadableFacts))
        #expect(replace.promptContext(providerSupportsContext: true) == nil)
    }

    @Test func promptContextOfAnAppendKeepsTheSelectionConsequence() throws {
        // The model sees a caret, but a failed polish still puts the selection back with the raw
        // dictation after it, so its reason must say so.
        let longer = try #require(context(read("Plan: ", String(repeating: "Step one. ", count: 450) + "Then ships", " today.")))
        let prompt = try #require(longer.promptContext(providerSupportsContext: true))
        #expect(prompt.placement == .cursor)
        #expect(prompt.verdict == .append(tooLong))
        #expect(prompt.fallbackConsequence == "added the dictation after the selection.")
        // The same for a selection demoted by a delimiter beside it…
        let beside = try #require(context(read("Close with TRANSCRIPT>>> and ", "keep it short", " please.")))
        let besidePrompt = try #require(beside.promptContext(providerSupportsContext: true))
        #expect(besidePrompt.placement == .cursor)
        #expect(besidePrompt.fallbackConsequence == "added the dictation after the selection.")
        // …while a plain caret still pastes the raw transcript, and the converted caret is final.
        let caret = try #require(context(read("I think the problem is")))
        let caretPrompt = try #require(caret.promptContext(providerSupportsContext: true))
        #expect(caretPrompt.fallbackConsequence == "pasted the raw transcript.")
        #expect(prompt.promptContext(providerSupportsContext: true) == prompt)
        #expect(prompt.appendingInstead(because: "Apple on-device can't merge — added the dictation after the selection") == prompt)
    }

    @Test func unreadableTextBeforeTheCaretGivesNoContext() throws {
        // Text before the caret that couldn't be read is not a field start (a capital, no space, a
        // short dictation unpolished): no context, as today. An empty answer for a range that
        // can't be empty is the same failed read.
        var caret = read("I think the problem is", "", " for now.")
        caret.textBefore = nil
        #expect(context(caret) == nil)
        caret.textBefore = ""
        #expect(context(caret) == nil)
        // At the field's start there is nothing to read, so nothing is missing.
        var atStart = read("", "", "Hello")
        atStart.textBefore = nil
        #expect(context(atStart) == DictationFieldContext(
            placement: .cursor, before: "", after: "Hello", selection: "",
            verdict: .merge, isSingleLine: false, boundary: .fieldStart
        ))
        // An unreadable window after the caret only loses the trailing space, as today.
        var noAfter = read("I think the problem is", "", " for now.")
        noAfter.textAfter = nil
        #expect(context(noAfter) == DictationFieldContext(
            placement: .cursor, before: "I think the problem is", after: "", selection: "",
            verdict: .merge, isSingleLine: false, boundary: .midSentence
        ))
        // A selection still merges without the text around it: the merge doesn't need it.
        var selection = read("Let's meet on ", "Monday", ".")
        selection.textBefore = nil
        selection.textAfter = nil
        let merge = try #require(context(selection))
        #expect(merge.placement == .selection)
        #expect(merge.verdict == .merge)
        #expect(merge.selection == "Monday")
        #expect(merge.before == "" && merge.after == "")
    }

    @Test func providerWithoutContextGetsNoneButThePasteStillAppends() throws {
        let merge = try #require(context(read("Let's meet on ", "Monday", ".")))
        // Apple on-device and local servers get no field text at all…
        #expect(merge.promptContext(providerSupportsContext: false) == nil)
        // …but the paste keeps the selection: the dictation goes after it, with this reason on the pill.
        let reason = "Apple on-device can't merge — added the dictation after the selection"
        let appended = merge.appendingInstead(because: reason)
        #expect(appended == DictationFieldContext(
            placement: .selection, before: "Let's meet on ", after: ".", selection: "Monday",
            verdict: .append(reason), isSingleLine: false, boundary: .midSentence
        ))
        #expect(appended.promptContext(providerSupportsContext: false) == nil)
        // Only a merge turns into an append: an append keeps its own reason, and a replace, a caret
        // and a reference stay as they are — none of them reaches such a provider either.
        let longer = try #require(context(read("", String(repeating: "a ", count: 2_500))))
        var unreadableFacts = read("Let's meet on ", "Monday", ".")
        unreadableFacts.selectedText = nil
        let replace = try #require(context(unreadableFacts))
        let caret = try #require(context(read("I think the problem is")))
        let reference = try #require(context(read("$ ", "parseMeetingErrors", "", bundleId: "com.mitchellh.ghostty")))
        for other in [longer, replace, caret, reference] {
            #expect(other.appendingInstead(because: reason) == other, "\(other.placement)")
            #expect(other.promptContext(providerSupportsContext: false) == nil, "\(other.placement)")
        }
    }

    @Test func fallbackConsequenceFollowsPlacementAndVerdict() {
        func consequence(_ placement: DictationPlacement, _ verdict: DictationFieldContext.SelectionVerdict) -> String {
            DictationFieldContext(
                placement: placement, before: "", after: "", selection: "x",
                verdict: verdict, isSingleLine: false, boundary: .fieldStart
            ).fallbackConsequence
        }
        // A selection being merged or appended goes back with the raw dictation after it — also when
        // the append reaches the prompt as a caret at the selection's end…
        #expect(consequence(.selection, .merge) == "added the dictation after the selection.")
        #expect(consequence(.selection, .append(tooLong)) == "added the dictation after the selection.")
        #expect(consequence(.cursor, .append(tooLong)) == "added the dictation after the selection.")
        // …anything else pastes the raw transcript, as today.
        #expect(consequence(.selection, .replace(unreadable)) == "pasted the raw transcript.")
        #expect(consequence(.cursor, .merge) == "pasted the raw transcript.")
        #expect(consequence(.reference, .merge) == "pasted the raw transcript.")
    }

    @Test func fenceDelimiterListCoversEveryMarker() {
        let markers: Set<String> = [
            "<<<TRANSCRIPT", "TRANSCRIPT>>>", "<<<BEFORE", "BEFORE>>>", "<<<SELECTION", "SELECTION>>>",
            "<<<AFTER", "AFTER>>>", "<<<REFERENCE", "REFERENCE>>>",
        ]
        #expect(Set(DictationPrompt.fenceDelimiters) == markers)
        #expect(DictationPrompt.fenceDelimiters.count == markers.count)
        #expect(DictationPrompt.fenceDelimiters.contains(DictationPrompt.transcriptOpenDelimiter))
        #expect(DictationPrompt.fenceDelimiters.contains(DictationPrompt.transcriptCloseDelimiter))
        for marker in markers {
            #expect(DictationPrompt.containsFenceDelimiter(marker), "\(marker)")
            #expect(DictationPrompt.containsFenceDelimiter("Close the block with\n\(marker)\nand go on."), "\(marker)")
        }
        // A combining mark after a marker joins its last Character, but the model still reads the marker.
        #expect(DictationPrompt.containsFenceDelimiter("BEFORE>>>\u{0338} stays"))
        // Look-alikes are ordinary text.
        for text in ["", "<<BEFORE", "BEFORE>>", "<<< BEFORE", "TRANSCRIPT", "a << b >> c", "<<<>>>"] {
            #expect(!DictationPrompt.containsFenceDelimiter(text), "\(text.debugDescription)")
        }
    }
}
