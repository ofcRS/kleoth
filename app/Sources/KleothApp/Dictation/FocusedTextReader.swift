import AppKit
import ApplicationServices
import KleothCore
import os

/// The only code in Kleoth that reads another app's text: the focused field's selection and the
/// text around its caret, through Accessibility, for context-aware dictation (design
/// 2026-09-24-dictation-context §3.2, §4.4).
///
/// It reports facts and decides nothing. `DictationContextPolicy` classifies the element, plans the
/// windows and turns the facts into a context; `DictationInsertionPlan` uses the re-check. Every
/// rule is pinned by KleothCore's tests, and this layer stays thin. By construction it:
/// - classifies the element from its role, subrole, editability and the app's bundle id before any
///   text is read, and reads nothing more from an element the policy skips (a password field, a
///   password manager, Kleoth's own windows, anything that isn't editable text), or from one whose
///   subrole or editability didn't answer (fail closed);
/// - sends no message at all to Kleoth or to an excluded app;
/// - bounds every message: each element it messages gets `DictationDefaults.contextElementTimeout`
///   (0.25 s) through `AXUIElementSetMessagingTimeout`, never the system-wide element, where the
///   timeout would change for the whole process;
/// - writes nothing but the wake attributes the two wake lists name, and `endSession()` sets back
///   only the ones it turned on;
/// - logs roles, lengths (UTF-16 units), AX error raw values and timings, never field text.
///
/// It runs on its own serial `DispatchQueue`, a custom actor executor (`DispatchSerialQueue` is a
/// `SerialExecutor` from macOS 14), so a blocked AX message never holds a cooperative-pool thread.
/// Callers bound every call with `withDeadline` and abandon it on expiry (the `PasteboardReader`
/// idiom): an abandoned call finishes here later and its answer is dropped.
actor FocusedTextReader {
    static let shared = FocusedTextReader()

    /// The focused field at release, as read.
    struct Snapshot: Sendable, Equatable {
        /// What was read. A skipped element keeps only what classified it: no range, length or text.
        var facts: DictationFieldFacts
        /// The policy's verdict on the element; `.skip` when nothing was read past it.
        var kind: DictationContextPolicy.ElementKind
        /// How long the read took once it ran on this queue: the row's `context_seconds`.
        var seconds: Double
    }

    private let queue = DispatchSerialQueue(label: "dev.kleoth.focused-text")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let log = Logger(subsystem: "dev.kleoth", category: "Dictation")

    /// A wake attribute this session turned on, for `endSession()` to turn off.
    private struct RaisedAttribute {
        let processIdentifier: pid_t
        let attribute: String
        /// The app element it was set on, messaged again to set it back.
        let app: AXUIElement
    }

    private var raised: [RaisedAttribute] = []

    // MARK: - Chord-down

    /// Chord-down (and the pill's Dictate): a wake, nothing more. No text is read.
    ///
    /// Reading the app element's `AXRole` makes Chrome's and Electron's application object turn on
    /// its accessibility tree (`kAXModeBasic`) for the assistive client that asks, and the focused
    /// element's role read does the same for a Chromium web view with the Sonoma activation flag
    /// on. The tree then builds while the user speaks, so the snapshot at release finds a field.
    /// An app in `DictationDefaults.wakeWithManualAccessibility` or `wakeWithEnhancedUserInterface`
    /// also gets that attribute set to true, set back in `endSession()`. Both lists are empty for
    /// now: the role read is the wake (§3.2), and adding an app is a one-line change there.
    /// Kleoth and the excluded apps get no message.
    func wake(processIdentifier: pid_t, bundleId: String?) {
        let trace = Trace()
        if let reason = Self.appSkipReason(bundleId: bundleId, isKleoth: processIdentifier == getpid()) {
            log.info("Context wake: skipped (\(reason, privacy: .public))")
            return
        }
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, DictationDefaults.contextElementTimeout)
        let appRole = AXMessage.copy(app, "AXRole", trace).string
        var attributes: [String] = []
        for listed in Self.wakeAttributes where Self.lists(bundleId, in: listed.bundleIds) {
            let outcome = raise(listed.attribute, on: app, processIdentifier: processIdentifier, trace: trace)
            attributes.append("\(listed.attribute) \(outcome)")
        }
        var focusedRole: String?
        if let focused = AXMessage.copy(app, "AXFocusedUIElement", trace).element {
            AXUIElementSetMessagingTimeout(focused, DictationDefaults.contextElementTimeout)
            focusedRole = AXMessage.copy(focused, "AXRole", trace).string
        }
        let flags = attributes.isEmpty ? "" : "; " + attributes.joined(separator: "; ")
        log.info(
            "Context wake: app role=\(appRole ?? "-", privacy: .public) focused role=\(focusedRole ?? "-", privacy: .public)\(flags, privacy: .public) (\(trace.summary, privacy: .public))"
        )
    }

    // MARK: - Release

    /// Release: one read of the focused field. First what classifies it (role, subrole,
    /// editability) together with its selection range, length and placeholder; then, for editable
    /// text, the selected text and the two windows the policy's `readPlan` names; for a terminal,
    /// only the selection.
    ///
    /// nil when there is nothing to classify: Accessibility refused or timed out, the app has no
    /// focused element yet (a Chromium tree still building), or the element's subrole or
    /// editability didn't answer. A skipped element gives a snapshot of kind `.skip` holding only
    /// what classified it: its role and subrole, or nothing for Kleoth or an excluded app, which
    /// get no message. The snapshot counts only when the app in front at release is the
    /// press-time app: the caller checks, as it checks the setting.
    func snapshot(processIdentifier: pid_t, bundleId: String?) -> Snapshot? {
        let trace = Trace()
        switch Self.focus(processIdentifier: processIdentifier, bundleId: bundleId, trace: trace) {
        case let .unavailable(why):
            log.info("Context snapshot: none (\(why, privacy: .public)) (\(trace.summary, privacy: .public))")
            return nil
        case let .skipped(facts, reason):
            let snapshot = Snapshot(facts: facts, kind: .skip(reason), seconds: trace.seconds)
            log.info("Context snapshot: \(Self.describe(snapshot), privacy: .public) (\(trace.summary, privacy: .public))")
            return snapshot
        case let .readable(element, found, kind):
            var facts = found
            Self.readText(into: &facts, of: element, kind: kind, trace: trace)
            let snapshot = Snapshot(facts: facts, kind: kind, seconds: trace.seconds)
            log.info("Context snapshot: \(Self.describe(snapshot), privacy: .public) (\(trace.summary, privacy: .public))")
            return snapshot
        }
    }

    // MARK: - Before ⌘V

    /// Just before ⌘V: the focused element read afresh (its identity can change when a web page
    /// re-renders), compared with the snapshot by `DictationContextPolicy.isUnchanged`, with up to
    /// 40 characters of live text on each side of its caret or selection (R2). The live element is
    /// classified like the snapshot's, so a field that is never read stays unread here too.
    ///
    /// The answers (R9 and the Task 9 amendments):
    /// - `.unchanged` or `.changed` with both neighbours read; "" only where the field ends.
    /// - `.unavailable` when the field can't be read, and when a neighbour of an unchanged caret or
    ///   selection can't be: never "" for a failed read. A moved caret whose neighbours can't be
    ///   read gets it too: at a caret `decide` treats `.changed` like `.unchanged`, so the
    ///   snapshot's neighbours are the safe answer.
    /// - `.changed` with "" for each new neighbour of a moved selection that can't be read
    ///   (accepted: on that double failure the spacing may be off); with "" for both when the
    ///   snapshot's app is no longer in front, or its focus moved to an element that is never read.
    /// - `.notNeeded`, with no message sent, for a snapshot with nothing to re-check: a skipped
    ///   element; or a terminal, whose reference goes to the program's input whatever the screen
    ///   does, and around whose selection nothing is ever read.
    func recheck(_ snapshot: Snapshot) -> DictationInsertionPlan.Recheck {
        let trace = Trace()
        let (answer, why) = Self.recheckAnswer(for: snapshot, trace: trace)
        let reason = why.isEmpty ? "" : " (\(why))"
        log.info(
            "Context re-check: \(Self.describe(answer), privacy: .public)\(reason, privacy: .public) (\(trace.summary, privacy: .public))"
        )
        return answer
    }

    // MARK: - Session end

    /// The dictation is over: every wake attribute `wake` turned on is set back to false. Only
    /// those: an attribute found on is left on. The write must land, so it gets a longer timeout
    /// than a read and one retry after a timeout.
    func endSession() {
        let attributes = raised
        raised = []
        for flag in attributes {
            let trace = Trace()
            AXUIElementSetMessagingTimeout(flag.app, Self.restoreTimeout)
            var error = AXMessage.set(flag.app, flag.attribute, kCFBooleanFalse, trace)
            if error == .cannotComplete {
                error = AXMessage.set(flag.app, flag.attribute, kCFBooleanFalse, trace)
            }
            let outcome = error == .success ? "set back to false" : "setting back to false failed"
            log.info("Context wake: \(flag.attribute, privacy: .public) \(outcome, privacy: .public) (\(trace.summary, privacy: .public))")
        }
    }

    /// Sets a wake attribute to true on an app element and remembers it for `endSession()`, only
    /// when it read as off or absent: an app that the user (or another assistive tool) switched on
    /// is left as found. Only -25205 and -25212 say "absent". Any other failure to read it, or a
    /// non-boolean answer, leaves it untouched, since a write then could leave the app changed with
    /// nothing to undo it. A set that timed out may still have landed, so it is remembered too.
    private func raise(_ attribute: String, on app: AXUIElement, processIdentifier: pid_t, trace: Trace) -> String {
        if raised.contains(where: { $0.processIdentifier == processIdentifier && $0.attribute == attribute }) {
            return "already set by Kleoth"
        }
        let read = AXMessage.copy(app, attribute, trace)
        if read.error == .success {
            guard let number = read.value as? NSNumber else { return "not a boolean, left as found" }
            if number.boolValue { return "already on, left as found" }
        } else if !AXMessage.absent.contains(read.error) {
            return "unreadable, left as found"
        }
        let error = AXMessage.set(app, attribute, kCFBooleanTrue, trace)
        guard error == .success || error == .cannotComplete else { return "set failed" }
        raised.append(RaisedAttribute(processIdentifier: processIdentifier, attribute: attribute, app: app))
        return "set to true"
    }

    // MARK: - Constants

    /// Read in one message from the focused element: what classifies it, and where its caret is.
    private static let factAttributes = [
        "AXRole", "AXSubrole", "AXSelectedTextRange", "AXNumberOfCharacters", "AXPlaceholderValue",
    ]

    /// The wake attributes, each with the apps that get it (bundle ids, compared ignoring case).
    private static let wakeAttributes: [(attribute: String, bundleIds: Set<String>)] = [
        ("AXManualAccessibility", DictationDefaults.wakeWithManualAccessibility),
        ("AXEnhancedUserInterface", DictationDefaults.wakeWithEnhancedUserInterface),
    ]

    /// UTF-16 units the re-check reads on each side of the live caret or selection (R2). One
    /// character, as the spec first had it, can't tell a space after a word from a field's start,
    /// and a mid-sentence continuation would then be capitalized. At most 40 characters, since a
    /// character is at least one unit.
    private static let recheckWindow = 40

    /// Setting a wake attribute back must land, so it waits longer than a read.
    private static let restoreTimeout: Float = 1
}

// MARK: - Reading the focused element

extension FocusedTextReader {
    /// The focused element, classified, before any text is read.
    fileprivate enum Focus {
        /// Nothing to classify. The reason is for the log (a fixed phrase, never text).
        case unavailable(String)
        /// Never read. The facts hold only what classified it, and the reason is the policy's.
        case skipped(DictationFieldFacts, reason: String)
        /// Editable text or a terminal: the facts without any text yet.
        case readable(AXUIElement, DictationFieldFacts, DictationContextPolicy.ElementKind)
    }

    /// Finds and classifies the focused element of `processIdentifier`'s app, in the order that
    /// sends nothing to an app that is never read and reads no text from an element that is never
    /// read. The app itself is checked first (Kleoth, an excluded app), then the element's role
    /// and subrole, then, for a text role only, its editability. A terminal's editability isn't
    /// read, since it doesn't count there, so its facts say false.
    fileprivate static func focus(processIdentifier: pid_t, bundleId: String?, trace: Trace) -> Focus {
        let isKleoth = processIdentifier == getpid()
        var facts = DictationFieldFacts(
            processIdentifier: processIdentifier, bundleId: bundleId, role: nil, subrole: nil, isEditable: false,
            characterCount: nil, selection: nil, selectedText: nil, textBefore: nil, textAfter: nil, placeholder: nil
        )
        if let reason = appSkipReason(bundleId: bundleId, isKleoth: isKleoth) {
            return .skipped(facts, reason: reason)
        }

        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, DictationDefaults.contextElementTimeout)
        guard let element = AXMessage.copy(app, "AXFocusedUIElement", trace).element else {
            return .unavailable("no focused element")
        }
        AXUIElementSetMessagingTimeout(element, DictationDefaults.contextElementTimeout)

        // The process serving the element (asked locally, no message). It is the app's own unless
        // another process hosts the element, and that process is never Kleoth or an excluded app.
        var servingProcess: pid_t = 0
        if AXUIElementGetPid(element, &servingProcess) == .success, servingProcess != processIdentifier {
            let servingBundleId = NSRunningApplication(processIdentifier: servingProcess)?.bundleIdentifier
            if let reason = appSkipReason(bundleId: servingBundleId, isKleoth: servingProcess == getpid()) {
                return .skipped(facts, reason: reason)
            }
        }

        let reply = AXMessage.copyMultiple(element, factAttributes, trace)
        guard reply.error == .success else { return .unavailable("attributes unreadable") }
        // Fail closed: a subrole that didn't answer could be a password field's. A role that didn't
        // answer can't classify the element either, and a skip on a failed read would look to the
        // re-check like focus that moved.
        guard reply.answersString("AXSubrole") else { return .unavailable("subrole unknown") }
        guard reply.answersString("AXRole") else { return .unavailable("role unknown") }
        facts.role = reply.string("AXRole")
        facts.subrole = reply.string("AXSubrole")

        // Asked as if the element were editable first: only a text role needs its editability read,
        // and a password field or a non-text role is skipped without another message.
        var kind = DictationContextPolicy.elementKind(
            bundleId: bundleId, role: facts.role, subrole: facts.subrole, isEditable: true, isKleoth: isKleoth
        )
        if case .text = kind {
            switch editability(of: element, trace: trace) {
            case .unknown:
                return .unavailable("editability unknown")
            case .editable:
                facts.isEditable = true
            case .notEditable:
                kind = DictationContextPolicy.elementKind(
                    bundleId: bundleId, role: facts.role, subrole: facts.subrole, isEditable: false, isKleoth: isKleoth
                )
            }
        }
        if case let .skip(reason) = kind {
            return .skipped(facts, reason: reason)
        }

        facts.selection = reply.range("AXSelectedTextRange")
        facts.characterCount = reply.integer("AXNumberOfCharacters")
        facts.placeholder = reply.string("AXPlaceholderValue")
        return .readable(element, facts, kind)
    }

    /// Why an app is never read, whatever its focused element: Kleoth itself, or an excluded app.
    /// Asked of the policy as if the element were editable text, which only the app can skip.
    fileprivate static func appSkipReason(bundleId: String?, isKleoth: Bool) -> String? {
        let kind = DictationContextPolicy.elementKind(
            bundleId: bundleId, role: "AXTextArea", subrole: nil, isEditable: true, isKleoth: isKleoth
        )
        guard case let .skip(reason) = kind else { return nil }
        return reason
    }

    fileprivate enum Editability {
        case editable
        case notEditable
        /// A message failed: it can't be told, so nothing is read (fail closed).
        case unknown
    }

    /// Editable text is a settable `AXValue` or an `AXEditableAncestor` (§3.2). The second covers
    /// a contenteditable editor such as T3 Code's TipTap composer. It counts as not editable only
    /// when both answered.
    fileprivate static func editability(of element: AXUIElement, trace: Trace) -> Editability {
        let value = AXMessage.isSettable(element, "AXValue", trace)
        if value.error == .success, value.isSettable { return .editable }
        let ancestor = AXMessage.copy(element, "AXEditableAncestor", trace)
        if ancestor.element != nil { return .editable }
        let valueAnswered = value.error == .success || AXMessage.absent.contains(value.error)
        let ancestorAnswered = ancestor.error == .success || AXMessage.absent.contains(ancestor.error)
        return valueAnswered && ancestorAnswered ? .notEditable : .unknown
    }

    /// The snapshot's text reads, for an element the policy reads.
    /// - Editable text: the selected text (A.1), then the windows `readPlan` names around the
    ///   caret or selection. Without a caret there is nothing to read around, and the policy gives
    ///   no context. Without a length, the window after isn't planned: a range past the field's
    ///   end is never sent to another app.
    /// - A terminal: only the selection, as a reference (§3.5). No text around it, and no caret. A
    ///   terminal may report no range, or an empty one, for a mouse selection, so only a known
    ///   range past the cap stops the read.
    fileprivate static func readText(
        into facts: inout DictationFieldFacts, of element: AXUIElement,
        kind: DictationContextPolicy.ElementKind, trace: Trace
    ) {
        switch kind {
        case .skip:
            return
        case .terminal:
            if let range = facts.selection, range.length > maxSelectionUnits { return }
            facts.selectedText = AXMessage.copy(element, "AXSelectedText", trace).string
        case .text:
            guard let range = facts.selection else { return }
            facts.selectedText = selectedText(of: element, range: range, trace: trace)
            let plan = DictationContextPolicy.readPlan(
                selection: range, characterCount: facts.characterCount ?? max(0, range.end)
            )
            var windows = WindowReader(element: element, characterCount: facts.characterCount, trace: trace)
            facts.textBefore = windows.text(in: plan.before)
            facts.textAfter = facts.characterCount == nil ? nil : windows.text(in: plan.after)
        }
    }

    /// `AXSelectedText` of a non-empty selection whose UTF-16 length is at most twice
    /// `maxReadableSelectionCharacters` (A.1). The policy's cap counts Characters, and an emoji is
    /// two units, so reading up to twice as many units lets the policy decide; a longer selection
    /// is never copied across. nil at a caret.
    fileprivate static func selectedText(of element: AXUIElement, range: DictationTextRange, trace: Trace) -> String? {
        guard range.length > 0, range.length <= maxSelectionUnits else { return nil }
        return AXMessage.copy(element, "AXSelectedText", trace).string
    }

    fileprivate static var maxSelectionUnits: Int { 2 * DictationDefaults.maxReadableSelectionCharacters }
}

// MARK: - The re-check

extension FocusedTextReader {
    /// The re-check's answer and, for the log, why (a fixed phrase, never text).
    fileprivate static func recheckAnswer(
        for snapshot: Snapshot, trace: Trace
    ) -> (DictationInsertionPlan.Recheck, String) {
        guard case .text = snapshot.kind else { return (.notNeeded, "no field context") }
        let then = snapshot.facts
        // Where it moved and can't be read around. A selection is replaced no more, so its
        // unread neighbours are "". A caret keeps the snapshot's (A.2).
        let wasCaret = (then.selection?.length ?? 0) <= 0
        let unreadableMove: DictationInsertionPlan.Recheck = wasCaret ? .unavailable : .changed(before: "", after: "")

        // ⌘V goes to the app in front. Once that isn't the snapshot's app, the paste lands in a field
        // that was never classified. `NSRunningApplication` is thread-safe and sends no AX message.
        guard NSRunningApplication(processIdentifier: then.processIdentifier)?.isActive == true else {
            return (unreadableMove, "another app is in front")
        }

        switch focus(processIdentifier: then.processIdentifier, bundleId: then.bundleId, trace: trace) {
        case let .unavailable(why):
            return (.unavailable, why)
        case let .skipped(_, reason):
            return (unreadableMove, "focus moved to an element never read: \(reason)")
        case let .readable(element, live, kind):
            guard case .text = kind else { return (unreadableMove, "focus moved off the text field") }
            // An unreadable range is no evidence of a move.
            guard let range = live.selection else { return (.unavailable, "selection unreadable") }
            var now = live
            // The selected text only decides once everything else matches, and a failed read of
            // it is no evidence of a change either.
            if now.role == then.role, range == then.selection {
                now.selectedText = selectedText(of: element, range: range, trace: trace)
                if then.selectedText != nil, now.selectedText == nil {
                    return (.unavailable, "selected text unreadable")
                }
            }
            let unchanged = DictationContextPolicy.isUnchanged(then, now)
            var windows = WindowReader(element: element, characterCount: now.characterCount, trace: trace)
            let (rawBefore, rawAfter) = neighbours(of: range, reader: &windows)
            // Cleaned like the snapshot's windows: an attachment or a zero-width character at the
            // caret is no text to space or capitalize around.
            let before = rawBefore.map(DictationContextPolicy.cleaned)
            let after = rawAfter.map(DictationContextPolicy.cleaned)
            if let before, let after {
                return unchanged ? (.unchanged(before: before, after: after), "") : (.changed(before: before, after: after), "")
            }
            if unchanged { return (.unavailable, "neighbours unreadable") }
            if wasCaret { return (.unavailable, "caret moved, neighbours unreadable") }
            return (.changed(before: before ?? "", after: after ?? ""), "selection moved, neighbours unreadable")
        }
    }

    /// Up to `recheckWindow` units on each side of `range`, clamped to the field: "" where the
    /// field ends, nil when a window couldn't be read. Without a length, the window after isn't
    /// planned and counts as unread.
    fileprivate static func neighbours(
        of range: DictationTextRange, reader: inout WindowReader
    ) -> (before: String?, after: String?) {
        let count = reader.characterCount.map { max(0, $0) }
        let start = min(max(0, range.location), count ?? .max)
        let end = min(max(start, range.end), count ?? .max)
        let beforeLength = min(start, recheckWindow)
        let before = reader.text(in: DictationTextRange(location: start - beforeLength, length: beforeLength))
        guard let count else { return (before, nil) }
        let after = reader.text(in: DictationTextRange(location: end, length: min(recheckWindow, count - end)))
        return (before, after)
    }
}

// MARK: - Windows of text

/// Reads windows of one element's text in UTF-16 units: `AXStringForRange`, or, for an element that
/// doesn't support it, a cut out of its whole `AXValue`, read once and only while the field holds at
/// most `DictationDefaults.maxValueCharactersWithoutRangeReads` (a huge document isn't copied across
/// processes for 2,000 characters of it).
fileprivate struct WindowReader {
    let element: AXUIElement
    let characterCount: Int?
    let trace: Trace

    /// Set once `AXStringForRange` answered "unsupported"; later windows go straight to `AXValue`.
    private var rangeReadsUnsupported = false
    private var valueWasRead = false
    private var value: NSString?

    init(element: AXUIElement, characterCount: Int?, trace: Trace) {
        self.element = element
        self.characterCount = characterCount
        self.trace = trace
    }

    /// The text in `window`: "" for an empty window, at the field's edge, with no message sent;
    /// nil when it can't be read. An empty answer for a non-empty window is a failed read, never
    /// "no text": text before a caret read as "" would make it a field start (A.3).
    mutating func text(in window: DictationTextRange) -> String? {
        guard window.length > 0 else { return "" }
        if !rangeReadsUnsupported {
            let reply = AXMessage.string(element, range: window, trace)
            if reply.error == .success { return Self.nonEmpty(reply.string) }
            guard AXMessage.unsupported.contains(reply.error) else { return nil }
            rangeReadsUnsupported = true
        }
        return Self.nonEmpty(valueText(in: window))
    }

    private mutating func valueText(in window: DictationTextRange) -> String? {
        guard let count = characterCount, count <= DictationDefaults.maxValueCharactersWithoutRangeReads else {
            return nil
        }
        if !valueWasRead {
            valueWasRead = true
            value = AXMessage.copy(element, "AXValue", trace).string.map { $0 as NSString }
        }
        guard let value else { return nil }
        let start = min(max(0, window.location), value.length)
        let end = min(max(start, window.end), value.length)
        return value.substring(with: NSRange(location: start, length: end - start))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - AX messages

/// Every AX message the reader sends, each noted in the call's trace. All are reads except `set`,
/// which only writes a wake attribute.
fileprivate enum AXMessage {
    /// The two replies that say an attribute is absent rather than unreadable.
    static let absent: Set<AXError> = [.attributeUnsupported, .noValue]
    /// The replies that say an element doesn't take `AXStringForRange` at all.
    static let unsupported: Set<AXError> = [.parameterizedAttributeUnsupported, .attributeUnsupported]

    struct Reply {
        var value: CFTypeRef?
        var error: AXError

        var string: String? { value as? String }

        var element: AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    static func copy(_ element: AXUIElement, _ attribute: String, _ trace: Trace) -> Reply {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        trace.note(attribute, error)
        return Reply(value: error == .success ? value : nil, error: error)
    }

    /// Options 0, not `.stopOnError`: an attribute the element lacks comes back as an error in its
    /// place, and the others still arrive.
    static func copyMultiple(_ element: AXUIElement, _ attributes: [String], _ trace: Trace) -> Attributes {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
        trace.note("multiple", error)
        var slots: [String: Slot] = [:]
        if error == .success, let objects = values as? [AnyObject] {
            for (attribute, object) in zip(attributes, objects) {
                let slot = Slot(object)
                if case let .failed(code) = slot { trace.note(attribute, code: code) }
                slots[attribute] = slot
            }
        }
        return Attributes(error: error, slots: slots)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String, _ trace: Trace) -> (isSettable: Bool, error: AXError) {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        trace.note("settable " + attribute, error)
        return (error == .success && settable.boolValue, error)
    }

    /// `AXStringForRange` with an `AXValue` of `.cfRange`.
    static func string(_ element: AXUIElement, range: DictationTextRange, _ trace: Trace) -> Reply {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return Reply(value: nil, error: .illegalArgument)
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, parameter, &value)
        trace.note("AXStringForRange", error)
        return Reply(value: error == .success ? value : nil, error: error)
    }

    /// The only write: a wake attribute, on an app element.
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFBoolean, _ trace: Trace) -> AXError {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        trace.note("set " + attribute, error)
        return error
    }

    /// One attribute's place in an `AXUIElementCopyMultipleAttributeValues` answer.
    enum Slot {
        case value(AnyObject)
        /// An `AXValue` of type `.axError` in the attribute's place, by raw value.
        case failed(Int32)
        /// CFNull: the API's marker for an attribute the element doesn't have.
        case missing

        init(_ object: AnyObject) {
            if CFGetTypeID(object) == CFNullGetTypeID() {
                self = .missing
                return
            }
            if CFGetTypeID(object) == AXValueGetTypeID() {
                let value = unsafeDowncast(object, to: AXValue.self)
                var code: Int32 = 0
                if AXValueGetType(value) == .axError, AXValueGetValue(value, .axError, &code) {
                    self = .failed(code)
                    return
                }
            }
            self = .value(object)
        }
    }

    /// The answer to one `AXUIElementCopyMultipleAttributeValues`, by attribute.
    struct Attributes {
        let error: AXError
        let slots: [String: Slot]

        func string(_ attribute: String) -> String? {
            guard case let .value(object)? = slots[attribute] else { return nil }
            return object as? String
        }

        /// A definite answer for a string attribute: a string, or one of the documented "none"
        /// replies (-25205, -25212, or CFNull in its place). Any other error, or a value of another
        /// type, answers nothing.
        func answersString(_ attribute: String) -> Bool {
            switch slots[attribute] {
            case let .value(object)?:
                return CFGetTypeID(object) == CFStringGetTypeID()
            case let .failed(code)?:
                return AXMessage.absent.contains { $0.rawValue == code }
            case .missing?:
                return true
            case nil:
                return false
            }
        }

        /// An `AXValue` of `.cfRange`, as the policy's range. A location of `NSNotFound` (Chromium's
        /// "no selection"), or a negative location or length, is no selection (A.1): the policy
        /// would otherwise clamp it to a caret at the field's end that isn't there.
        func range(_ attribute: String) -> DictationTextRange? {
            guard case let .value(object)? = slots[attribute], CFGetTypeID(object) == AXValueGetTypeID() else {
                return nil
            }
            let value = unsafeDowncast(object, to: AXValue.self)
            var range = CFRange()
            guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
            return DictationTextRange(location: range.location, length: range.length)
        }

        /// A non-negative number; nil for anything else.
        func integer(_ attribute: String) -> Int? {
            guard case let .value(object)? = slots[attribute], CFGetTypeID(object) == CFNumberGetTypeID(),
                  let number = (object as? NSNumber)?.intValue, number >= 0 else { return nil }
            return number
        }
    }
}

// MARK: - The log

/// What one reader call did, for its log line: the messages it sent, the AX errors that came back
/// (by attribute and raw value) and the time it took. Never a value read.
fileprivate final class Trace {
    private let started = ContinuousClock.now
    private var messages = 0
    private var errors: [String] = []

    func note(_ name: String, _ error: AXError) {
        messages += 1
        if error != .success { errors.append("\(name)=\(error.rawValue)") }
    }

    /// An attribute's own error inside a successful multi-attribute reply (not a message of its own).
    func note(_ name: String, code: Int32) {
        errors.append("\(name)=\(code)")
    }

    var seconds: Double {
        let (whole, fraction) = started.duration(to: .now).components
        return Double(whole) + Double(fraction) / 1e18
    }

    /// "4 AX messages, 3.2 ms" or "2 AX messages, 250.4 ms, errors AXFocusedUIElement=-25204".
    var summary: String {
        let time = String(format: "%.1f ms", seconds * 1_000)
        let failures = errors.isEmpty ? "" : ", errors " + errors.joined(separator: " ")
        return "\(messages) AX messages, \(time)\(failures)"
    }
}

extension FocusedTextReader {
    /// A snapshot for the log: the kind, roles and lengths in UTF-16 units. Never text. A skipped
    /// element shows its roles only, not even the length of what it holds.
    fileprivate static func describe(_ snapshot: Snapshot) -> String {
        let facts = snapshot.facts
        var fields = [
            "kind=\(describe(snapshot.kind))", "role=\(facts.role ?? "-")", "subrole=\(facts.subrole ?? "-")",
        ]
        if case .skip = snapshot.kind { return fields.joined(separator: " ") }
        fields += [
            "editable=\(facts.isEditable)",
            "chars=\(facts.characterCount.map { String($0) } ?? "-")",
            "selection=\(facts.selection.map { String($0.length) } ?? "-")",
            "selected=\(length(facts.selectedText))",
            "before=\(length(facts.textBefore))",
            "after=\(length(facts.textAfter))",
            "placeholder=\(length(facts.placeholder))",
        ]
        return fields.joined(separator: " ")
    }

    fileprivate static func describe(_ kind: DictationContextPolicy.ElementKind) -> String {
        switch kind {
        case let .text(singleLine): singleLine ? "text (single line)" : "text"
        case .terminal: "terminal"
        case let .skip(reason): "skip (\(reason))"
        }
    }

    /// A re-check for the log: its case and the neighbours' lengths.
    fileprivate static func describe(_ recheck: DictationInsertionPlan.Recheck) -> String {
        switch recheck {
        case .notNeeded: "not needed"
        case let .unchanged(before, after): "unchanged, neighbours \(before.utf16.count)/\(after.utf16.count)"
        case let .changed(before, after): "changed, neighbours \(before.utf16.count)/\(after.utf16.count)"
        case .unavailable: "unavailable"
        }
    }

    fileprivate static func length(_ text: String?) -> String {
        text.map { String($0.utf16.count) } ?? "-"
    }

    /// Whether a wake list names this app. Bundle ids are compared ignoring case and outer
    /// whitespace, as `AppStyle.classify` and the policy compare them.
    fileprivate static func lists(_ bundleId: String?, in bundleIds: Set<String>) -> Bool {
        guard let id = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else {
            return false
        }
        return bundleIds.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == id }
    }
}
