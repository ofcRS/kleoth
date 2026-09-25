import Foundation

/// A span of a field's text in UTF-16 code units — the unit Accessibility counts in
/// (`AXSelectedTextRange`, `AXNumberOfCharacters`, `AXStringForRange`), so a range goes back to
/// the reader as it came.
public struct DictationTextRange: Sendable, Equatable {
    public var location: Int
    public var length: Int
    /// One past the last unit. Saturates rather than trapping: another process can report
    /// `NSNotFound` (`Int.max`) as a location, and its garbage must never crash Kleoth.
    public var end: Int {
        let (sum, overflow) = location.addingReportingOverflow(length)
        guard overflow else { return sum }
        return length > 0 ? .max : .min
    }

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// What the AX reader found on the focused element — facts, no decisions.
///
/// Raw, as read: nothing here is cleaned, capped or judged, so the reader (the one piece of code
/// that reads another app's text) stays a thin layer over Accessibility, and
/// ``DictationContextPolicy`` makes every decision where tests pin it.
public struct DictationFieldFacts: Sendable, Equatable {
    /// The process that owns the element. The re-check compares it.
    public var processIdentifier: Int32
    public var bundleId: String?
    /// `AXRole`.
    public var role: String?
    /// `AXSubrole`; `AXSecureTextField` is a password field.
    public var subrole: String?
    /// `AXValue` is settable, or the element has an `AXEditableAncestor`.
    public var isEditable: Bool
    /// `AXNumberOfCharacters`, in UTF-16 units; nil when the element doesn't report it.
    public var characterCount: Int?
    /// `AXSelectedTextRange`: a caret is an empty range. nil = unreadable.
    public var selection: DictationTextRange?
    /// `AXSelectedText`; nil = unreadable or over `DictationDefaults.maxReadableSelectionCharacters`.
    public var selectedText: String?
    /// `AXStringForRange` over ``DictationContextPolicy/readPlan(selection:characterCount:)``'s
    /// `before` window; nil = unreadable.
    public var textBefore: String?
    /// The same over its `after` window.
    public var textAfter: String?
    /// `AXPlaceholderValue`: some fields report it as their value while they are empty.
    public var placeholder: String?

    public init(
        processIdentifier: Int32, bundleId: String?, role: String?, subrole: String?, isEditable: Bool,
        characterCount: Int?, selection: DictationTextRange?, selectedText: String?,
        textBefore: String?, textAfter: String?, placeholder: String?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleId = bundleId
        self.role = role
        self.subrole = subrole
        self.isEditable = isEditable
        self.characterCount = characterCount
        self.selection = selection
        self.selectedText = selectedText
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.placeholder = placeholder
    }
}

/// Where a dictation lands relative to the text already in the field.
public enum DictationPlacement: Sendable, Equatable {
    /// At a caret: the text around it is read-only context.
    case cursor
    /// Over a selection in an editable field; ``DictationFieldContext/SelectionVerdict`` says how.
    case selection
    /// A terminal's selection: a read-only reference for spellings. The dictation goes to the
    /// terminal's input as before — a paste there never lands over the highlighted text.
    case reference
}

/// The text in the field around a dictation, as the prompt, the gate and the paste use it (design
/// 2026-09-24-dictation-context §3.3–§3.5). Made by ``DictationContextPolicy/context(from:kind:)``:
/// cleaned, capped, and marked "…" where a window was cut.
public struct DictationFieldContext: Sendable, Equatable {
    /// For `.selection` — and kept by the caret an appended selection becomes in the prompt. The
    /// strings are the pill's warning (§5).
    public enum SelectionVerdict: Sendable, Equatable {
        /// The model rewrites the selection together with the dictation; the result replaces it.
        case merge
        /// The selection stays and the dictation goes after it, handled as if typed at its end.
        case append(String)
        /// The dictation replaces the selection, as before field context existed.
        case replace(String)
    }

    public var placement: DictationPlacement
    /// Read-only text before the caret or selection; "" = none; "…"-prefixed when cut.
    public var before: String
    /// Read-only text after it; "" = none; "…"-suffixed when cut.
    public var after: String
    /// The selection or the terminal reference; "" at a caret, and for a `.replace` verdict — a
    /// selection that couldn't be read, or too long to read, has no text to use.
    public var selection: String
    /// How a selection is handled; `.merge`, and unused, at a caret or for a reference. The one
    /// caret with another verdict is the one an appended selection becomes in
    /// ``promptContext(providerSupportsContext:)``: it keeps its `.append`, so a failed polish
    /// still says the dictation went after the selection (``fallbackConsequence``).
    public var verdict: SelectionVerdict
    /// An `AXTextField` or `AXComboBox`: no line breaks in the paste or the answer.
    public var isSingleLine: Bool
    /// Where the caret, or the selection's start, sits: judged from the whole window read before
    /// it, never the cut one, whose "…" would read as a sentence end. Kept when `before` isn't sent.
    public var boundary: DictationContextFit.Boundary

    public init(
        placement: DictationPlacement, before: String, after: String, selection: String,
        verdict: SelectionVerdict, isSingleLine: Bool, boundary: DictationContextFit.Boundary
    ) {
        self.placement = placement
        self.before = before
        self.after = after
        self.selection = selection
        self.verdict = verdict
        self.isSingleLine = isSingleLine
        self.boundary = boundary
    }

    /// Ends every fallback reason: "pasted the raw transcript." or "added the dictation after the selection."
    ///
    /// The second for a selection being merged, and for any `.append` verdict — the selection
    /// itself, or the caret it becomes in ``promptContext(providerSupportsContext:)``, which is
    /// what the polisher sees. When their polish fails, the paste puts the selection back with the
    /// raw dictation after it, so nothing selected is lost, and the reason says so. Everywhere
    /// else a failed polish pastes the raw transcript, as it always has.
    public var fallbackConsequence: String {
        switch (placement, verdict) {
        case (_, .append), (.selection, .merge):
            return "added the dictation after the selection."
        default:
            return "pasted the raw transcript."
        }
    }

    /// What the prompt gets: a merge as is; an append as a cursor at the end of the selection;
    /// nil for a provider without context (the paste still appends).
    ///
    /// An appended selection goes back unchanged, so the model writes only the dictation, as if
    /// typed right after the selection: the text before that caret is the last 1,500 characters
    /// of the text before plus the selection, cut and marked like any window. The caret
    /// keeps the `.append` verdict, so a failed polish's reason still names the selection
    /// (``fallbackConsequence``). Nothing is sent when that text holds a fence delimiter (one can
    /// form across the selection's start), or for a replaced selection, which couldn't be read.
    public func promptContext(providerSupportsContext: Bool) -> DictationFieldContext? {
        guard providerSupportsContext else { return nil }
        switch (placement, verdict) {
        case (.cursor, _), (.reference, _), (.selection, .merge):
            return self
        case (.selection, .replace):
            return nil
        case (.selection, .append):
            let text = before + selection
            let limit = DictationDefaults.contextBeforeCharacters
            let window = text.count > limit ? FieldText.cutAtStart(String(text.suffix(limit))) : text
            guard !DictationPrompt.containsFenceDelimiter(window) else { return nil }
            return DictationFieldContext(
                placement: .cursor, before: window, after: after, selection: "",
                verdict: verdict, isSingleLine: isSingleLine, boundary: DictationContextFit.boundary(before: text)
            )
        }
    }

    /// This context with `verdict = .append(reason)` — applied when the resolved provider can't merge
    /// ("Apple on-device can't merge — added the dictation after the selection").
    ///
    /// Only a merge changes: an append already keeps the selection (with its own reason), a
    /// replace couldn't read it, and a caret or a reference has nothing to merge.
    public func appendingInstead(because reason: String) -> DictationFieldContext {
        guard placement == .selection, verdict == .merge else { return self }
        var context = self
        context.verdict = .append(reason)
        return context
    }
}

/// What of a focused field Kleoth reads, and what a dictation does with it (design
/// 2026-09-24-dictation-context §3.1–§3.5): which elements count as text and which are never read,
/// the windows read around the caret, and how the text read is cleaned, cut and judged.
///
/// Pure, over ``DictationFieldFacts``: the app's reader, the only code that reads another app's
/// text, decides nothing, so every rule here is pinned by tests.
public enum DictationContextPolicy {
    /// What the focused element is, for a dictation.
    public enum ElementKind: Sendable, Equatable {
        /// An editable text field; `singleLine` for `AXTextField` and `AXComboBox` (search fields too).
        case text(singleLine: Bool)
        /// A terminal's screen: only its selection is read, as a reference.
        case terminal
        /// Never read. The reason is for the log.
        case skip(String)
    }

    /// Terminal apps, lowercased. Recognized by bundle id before the role is consulted: they
    /// expose the whole screen as one `AXTextArea` (Ghostty's is even editable), and a paste goes
    /// to the program's input, never over the highlighted text, so a merge would only duplicate it.
    public static let terminalBundleIds: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "net.kovidgoyal.kitty",
        "io.alacritty", "org.alacritty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
    ]

    /// Password managers and Keychain Access, lowercased: never read, whatever their fields report
    /// — not every secret on their screens sits in a field marked secure.
    public static let excludedBundleIds: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.passwords", "com.apple.keychainaccess",
    ]

    /// Classifies the focused element, first matching rule first: Kleoth's own windows, an
    /// excluded app, a secure field, a terminal (before the role — Ghostty's screen reports
    /// `AXTextArea`), then editable text — `AXTextArea` spans lines, `AXTextField` and
    /// `AXComboBox` don't. Anything else isn't text to dictate into.
    public static func elementKind(
        bundleId: String?, role: String?, subrole: String?, isEditable: Bool, isKleoth: Bool
    ) -> ElementKind {
        if isKleoth { return .skip("Kleoth") }
        let app = normalized(bundleId)
        if excludedBundleIds.contains(app) { return .skip("excluded app") }
        if subrole == "AXSecureTextField" { return .skip("secure field") }
        if terminalBundleIds.contains(app) { return .terminal }
        guard isEditable else { return .skip("not editable text") }
        switch role {
        case "AXTextArea"?: return .text(singleLine: false)
        case "AXTextField"?, "AXComboBox"?: return .text(singleLine: true)
        default: return .skip("not editable text")
        }
    }

    /// The two windows to read around a caret or selection, in UTF-16 units: up to 1,500 before
    /// its start and 500 after its end, clamped to the field. A range past the field's end (a
    /// stale count, or `NSNotFound`) is clamped too, and no length is ever negative.
    public static func readPlan(selection: DictationTextRange, characterCount: Int)
        -> (before: DictationTextRange, after: DictationTextRange) {
        let count = max(0, characterCount)
        let start = min(max(0, selection.location), count)
        let end = min(max(start, selection.end), count)
        let beforeLength = min(start, DictationDefaults.contextBeforeCharacters)
        let afterLength = min(count - end, DictationDefaults.contextAfterCharacters)
        return (
            before: DictationTextRange(location: start - beforeLength, length: beforeLength),
            after: DictationTextRange(location: end, length: afterLength)
        )
    }

    /// The context for a dictation into this element, or nil when there is none to use.
    ///
    /// - A skipped element has none, and neither does a text field without a selection range, or a
    ///   caret whose text before it couldn't be read ("" there would read as a field start).
    /// - Every string read is cleaned first: U+FFFC (an attachment), U+FFFD (a failed decode, such
    ///   as a window edge splitting an emoji) and the zero-width U+200B and U+FEFF are removed —
    ///   they are no text to merge, and would otherwise count as visible text for the boundary and
    ///   the spacing (R7, R12).
    /// - A field whose text equals its placeholder is empty.
    /// - A window the read cut short is cut back to a word (dropping at most 40 characters of it,
    ///   else cut at a Character, R13) and marked "…" at the cut.
    /// - A terminal gives only its selection, as a capped reference; it has no cursor context.
    /// - A caret gives the text around it, unless that holds a fence delimiter: field text is
    ///   never escaped (escaping would alter text the model rewrites), so it isn't sent at all.
    /// - A selection is merged; appended to when it holds a delimiter, sits beside one, or is too
    ///   long to merge; replaced when it can't be read or is too long to read.
    /// - A password field (subrole `AXSecureTextField`) or an excluded app has none, whatever `kind`
    ///   says: ``elementKind(bundleId:role:subrole:isEditable:isKleoth:)`` already skips both, and
    ///   the facts are checked again here so a caller that got the kind wrong still never sends a
    ///   password manager's text.
    public static func context(from facts: DictationFieldFacts, kind: ElementKind) -> DictationFieldContext? {
        if facts.subrole == "AXSecureTextField" || excludedBundleIds.contains(normalized(facts.bundleId)) {
            return nil
        }
        switch kind {
        case .skip: return nil
        case .terminal: return reference(from: facts)
        case let .text(singleLine): return textContext(from: facts, singleLine: singleLine)
        }
    }

    /// Whether the field is as the snapshot found it: the same process, the same role, the same
    /// selection range and selected text. Those decide where ⌘V lands and what it replaces; the
    /// text around them may change without moving either.
    public static func isUnchanged(_ snapshot: DictationFieldFacts, _ now: DictationFieldFacts) -> Bool {
        snapshot.processIdentifier == now.processIdentifier
            && snapshot.role == now.role
            && snapshot.selection == now.selection
            && snapshot.selectedText == now.selectedText
    }

    /// `text` without U+FFFC (an attachment), U+FFFD (a failed decode), U+200B and U+FEFF (zero
    /// width), removed scalar by scalar — the cleaning every string read goes through in
    /// ``context(from:kind:)``.
    ///
    /// Public so the app's re-check cleans the live neighbours of the caret the same way: text the
    /// snapshot's windows lose must not count as a character at the caret at paste time, where
    /// ``DictationContextFit/fitted(_:before:after:singleLine:)`` would space or capitalize around it.
    public static func cleaned(_ text: String) -> String {
        FieldText.cleaned(text)
    }

    // MARK: - Rules

    private static let unreadableSelection = "Replaced the selection — it couldn't be read (⌘Z undoes)"
    private static let delimiterInField = "Couldn't merge this selection — added the dictation after it"
    private static let selectionTooLong = "Selection too long to merge — added the dictation after it"

    /// A bundle id as the lists hold it: trimmed and lowercased, as `AppStyle.classify` matches.
    private static func normalized(_ bundleId: String?) -> String {
        bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// A terminal's selection as a reference, capped (cut like a window) and marked. Only a
    /// selection with text in it: a drag over blank screen gives the model nothing to spell from.
    private static func reference(from facts: DictationFieldFacts) -> DictationFieldContext? {
        let selected = FieldText.cleaned(facts.selectedText ?? "")
        guard FieldText.hasText(selected) else { return nil }
        let limit = DictationDefaults.maxReferenceCharacters
        let reference = selected.count > limit ? FieldText.cutAtEnd(String(selected.prefix(limit))) : selected
        guard !DictationPrompt.containsFenceDelimiter(reference) else { return nil }
        return DictationFieldContext(
            placement: .reference, before: "", after: "", selection: reference,
            verdict: .merge, isSingleLine: false, boundary: .fieldStart
        )
    }

    /// A caret or a selection in an editable text field.
    ///
    /// Text before a caret that couldn't be read gives no context at all: as "" it would read as a
    /// field start (a capital, no space, a short dictation left unpolished), which is worse than
    /// today's plain paste. Any other unreadable window counts as no text: after a caret it costs
    /// only the trailing space, as today, and a merge doesn't need the text around its selection.
    private static func textContext(from facts: DictationFieldFacts, singleLine: Bool) -> DictationFieldContext? {
        guard let range = facts.selection else { return nil }
        let isCaret = range.length <= 0
        // Where the read plan put the windows, clamped the same way (UTF-16 units, as read).
        let count = facts.characterCount
        let start = min(max(0, range.location), count ?? .max)
        let end = min(max(start, range.end), count ?? .max)
        // An empty answer for the range before the caret, which isn't empty here, is a failed read too.
        if isCaret, start > 0, facts.textBefore?.isEmpty ?? true { return nil }

        let windowBefore = FieldText.cleaned(facts.textBefore ?? "")
        let windowAfter = FieldText.cleaned(facts.textAfter ?? "")
        let selected = facts.selectedText.map(FieldText.cleaned)

        if let placeholder = facts.placeholder.map(FieldText.cleaned), !placeholder.isEmpty,
           windowBefore + (isCaret ? "" : selected ?? "") + windowAfter == placeholder {
            return DictationFieldContext(
                placement: .cursor, before: "", after: "", selection: "",
                verdict: .merge, isSingleLine: singleLine, boundary: .fieldStart
            )
        }

        // Judged before the cut, whose "…" would read as a sentence end.
        let boundary = DictationContextFit.boundary(before: windowBefore)
        // A window was cut short when it stops before the field's edge; without a count, a full
        // window after the caret is taken as cut.
        let beforeWasCut = start > DictationDefaults.contextBeforeCharacters
        let afterWasCut = count.map { $0 - end > DictationDefaults.contextAfterCharacters }
            ?? ((facts.textAfter?.utf16.count ?? 0) >= DictationDefaults.contextAfterCharacters)
        let before = beforeWasCut ? FieldText.cutAtStart(windowBefore) : windowBefore
        let after = afterWasCut ? FieldText.cutAtEnd(windowAfter) : windowAfter

        func context(
            _ placement: DictationPlacement, before: String, after: String, selection: String,
            verdict: DictationFieldContext.SelectionVerdict
        ) -> DictationFieldContext {
            DictationFieldContext(
                placement: placement, before: before, after: after, selection: selection,
                verdict: verdict, isSingleLine: singleLine, boundary: boundary
            )
        }

        if isCaret {
            if DictationPrompt.containsFenceDelimiter(before) || DictationPrompt.containsFenceDelimiter(after) {
                return nil
            }
            return context(.cursor, before: before, after: after, selection: "", verdict: .merge)
        }
        // No text for a non-empty range (or only attachments) is a failed read.
        let length = selected?.count ?? 0
        guard let text = selected, length > 0, length <= DictationDefaults.maxReadableSelectionCharacters else {
            return context(.selection, before: before, after: after, selection: "", verdict: .replace(unreadableSelection))
        }
        if [text, before, after].contains(where: DictationPrompt.containsFenceDelimiter) {
            return context(.selection, before: "", after: "", selection: text, verdict: .append(delimiterInField))
        }
        if length > DictationDefaults.maxMergeSelectionCharacters {
            return context(.selection, before: before, after: after, selection: text, verdict: .append(selectionTooLong))
        }
        return context(.selection, before: before, after: after, selection: text, verdict: .merge)
    }
}

/// Cleaning and cutting the text read from a field — shared by the policy and the append
/// conversion, so both mark a cut the same way.
private enum FieldText {
    /// Scalars that carry no text: an attachment's placeholder (U+FFFC), a failed decode
    /// (U+FFFD), a zero-width space and a byte-order mark (U+200B, U+FEFF).
    static let nonText: Set<Unicode.Scalar> = ["\u{FFFC}", "\u{FFFD}", "\u{200B}", "\u{FEFF}"]

    /// `text` without ``nonText``, removed scalar by scalar: one carrying a combining mark is a
    /// different `Character`, but the same scalar.
    static func cleaned(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: nonText.contains) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter { !nonText.contains($0) })
        return String(scalars)
    }

    /// Whether `text` holds anything but whitespace.
    static func hasText(_ text: some StringProtocol) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    /// Whether `text` holds a letter or a digit: anything read as words, not only as punctuation.
    static func hasLetterOrDigit(_ text: some StringProtocol) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// A window that lost its beginning to the read limit: the partial word it starts with goes
    /// (through the first whitespace) and "…" marks the cut. An empty window has nothing to mark.
    ///
    /// The whole window stays, still marked, when:
    /// - that partial word is longer than `DictationDefaults.maxDroppedPartialWordCharacters` — text
    ///   written without spaces, or one long token such as a URL, would lose most of the window (R13);
    /// - what would be left holds no letter or digit. "…)" reads as a sentence end (the "…") where
    ///   the caret sits mid-sentence, and the paste fits the dictation to this text when the
    ///   re-check can't read the live one.
    static func cutAtStart(_ window: String) -> String {
        guard !window.isEmpty else { return window }
        let edge = window.prefix(DictationDefaults.maxDroppedPartialWordCharacters + 1)
        if let space = edge.firstIndex(where: \.isWhitespace) {
            let rest = window[window.index(after: space)...]
            if hasLetterOrDigit(rest) { return "…" + rest }
        }
        return "…" + window
    }

    /// A window, or a reference, that lost its end: the partial word it ends with goes (from the
    /// last whitespace) and "…" marks the cut. The whole window stays, still marked, when that word
    /// is longer than `DictationDefaults.maxDroppedPartialWordCharacters` (R13), or when nothing
    /// visible would be left. Unlike the start's cut, any visible text left will do: the paste reads
    /// only the first character after the caret, which this cut never changes.
    static func cutAtEnd(_ window: String) -> String {
        guard !window.isEmpty else { return window }
        let edge = window.suffix(DictationDefaults.maxDroppedPartialWordCharacters + 1)
        if let space = edge.lastIndex(where: \.isWhitespace) {
            let rest = window[..<space]
            if hasText(rest) { return String(rest) + "…" }
        }
        return window + "…"
    }
}
