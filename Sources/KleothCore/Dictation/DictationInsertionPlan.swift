import Foundation

/// What ⌘V pastes for a dictation, the warning the pill shows, the selection the row keeps and the
/// stored `field_context` — decided at paste time from the field context read at release, the
/// polish result, the raw transcript and a re-check of the field just before the paste (design
/// 2026-09-24-dictation-context §3.3–§3.5, §5).
///
/// Pure, so every row of the error matrix is pinned by tests and the controller only reads the
/// field, asks and pastes. By placement:
/// - no context: the polish result as it is, exactly as before field context existed;
/// - a terminal reference: the same — the paste goes to the program's input, never over the
///   highlighted text, so there is nothing around it to fit;
/// - a caret: the text fitted to the caret's live neighbours, since the caret may have moved since
///   the snapshot the model saw;
/// - a selection: the merged piece over it; the selection put back with the dictation after it when
///   it isn't merged or the merge failed (⌘V replaces the selection, so nothing selected is lost);
///   the dictation alone, as heard, when the selection changed before the paste; and the dictation
///   over a selection that couldn't be read, as before.
public struct DictationInsertionPlan: Sendable, Equatable {
    /// The focused field just before ⌘V, compared with the snapshot taken at release.
    ///
    /// The neighbours are up to 40 characters of live text on each side of the current caret or
    /// selection (R2): a single character can't tell a space after a word from a field start.
    /// "" always means there is no text there — the caret or selection sits at the field's start
    /// or end (R9) — so the plan uses the strings as given. A failed read never shows up as "" for
    /// an unchanged field: the reader answers `.unavailable` instead, and the snapshot's neighbours
    /// apply. Only a changed selection whose new neighbours couldn't be read comes with "" (accepted:
    /// on that double failure the spacing may be off). A moved caret whose neighbours couldn't be
    /// read is `.unavailable` too: at a caret `decide` treats `.changed` like `.unchanged`, so the
    /// snapshot's neighbours are the safe answer.
    public enum Recheck: Sendable, Equatable {
        /// No field context, so nothing to re-check. Given with a context, it counts as unavailable.
        case notNeeded
        /// The same process, role, selection range and selected text
        /// (`DictationContextPolicy.isUnchanged`), with the live text on either side.
        case unchanged(before: String, after: String)
        /// The caret or selection moved, or another field or app is focused; the live text on
        /// either side of the new caret or selection.
        case changed(before: String, after: String)
        /// The re-check ran out of time or couldn't read the field: treated as unchanged, with the
        /// snapshot's neighbours.
        case unavailable
    }

    /// How the field context was used. Raw value = the stored `field_context`.
    public enum Outcome: String, Sendable, Equatable {
        /// At a caret: the text was fitted to the words around it.
        case cursor
        /// The model merged the selection and the dictation, and the result replaced the selection.
        case merged
        /// The selection went back unchanged with the dictation after it.
        case appended
        /// The dictation replaced a selection that couldn't be read, as before field context existed.
        case replaced
        /// A terminal selection was a spelling reference; the dictation went to the terminal's input.
        case reference
        /// The selection changed before the paste: the dictation went in alone, at the new caret.
        case selectionChanged = "selection_changed"
    }

    /// What ⌘V pastes.
    public var text: String
    /// The pill's warning; nil → the polish result's own warning applies. When set, it outranks the
    /// polish's fallback reason: what happened to the selection matters more than why the polish
    /// fell back. The row keeps the polish's reason, except after a changed selection
    /// (`.selectionChanged`): that row is a raw-fallback row with this warning as its reason.
    public var warning: String?
    /// The selection a merge replaced, for the row's `replaced_text` — the way back once the app's
    /// undo history is gone. Merges only: any other paste leaves the selection in the field, or
    /// never read it.
    public var replacedText: String?
    /// nil = no field context.
    public var outcome: Outcome?

    public init(text: String, warning: String?, replacedText: String?, outcome: Outcome?) {
        self.text = text
        self.warning = warning
        self.replacedText = replacedText
        self.outcome = outcome
    }

    /// The paste for one dictation.
    ///
    /// - Parameters:
    ///   - context: The paste context: the policy's, or a merge demoted with
    ///     `appendingInstead(because:)` when the provider can't merge; nil when there is none.
    ///   - polish: The polish step's result: the dictation, or for a merge the merged piece. A merge
    ///     never gets `.polished("")` — the polisher refuses an empty answer — so the merged branch
    ///     doesn't guard it.
    ///   - rawText: The transcript as heard. It is what goes in when the selection changed: a merge's
    ///     polish holds the old selection, which would then land twice.
    ///   - recheck: The field just before ⌘V.
    public static func decide(
        context: DictationFieldContext?, polish: DictationPolishResult, rawText: String, recheck: Recheck
    ) -> DictationInsertionPlan {
        guard let context else {
            return DictationInsertionPlan(text: polish.text, warning: nil, replacedText: nil, outcome: nil)
        }
        switch context.placement {
        case .reference:
            return DictationInsertionPlan(text: polish.text, warning: nil, replacedText: nil, outcome: .reference)
        case .cursor:
            return atCaret(context, polish: polish, recheck: recheck)
        case .selection:
            return overSelection(context, polish: polish, rawText: rawText, recheck: recheck)
        }
    }

    // MARK: - Rules

    private static let selectionChanged = "The selection changed — pasted the dictation on its own"

    /// A caret, whatever verdict its context carries (only the prompt's copy of an appended
    /// selection has another, and that one is never the paste's): the text goes between the live
    /// neighbours, or the snapshot's when the re-check has none. A failed or skipped polish is
    /// fitted the same way and keeps its own warning.
    private static func atCaret(
        _ context: DictationFieldContext, polish: DictationPolishResult, recheck: Recheck
    ) -> DictationInsertionPlan {
        let (before, after) = neighbours(recheck, snapshot: context)
        let text = DictationContextFit.fitted(polish.text, before: before, after: after, singleLine: context.isSingleLine)
        return DictationInsertionPlan(text: text, warning: nil, replacedText: nil, outcome: .cursor)
    }

    /// A selection, in order: one that couldn't be read is replaced whatever the re-check says
    /// (there is nothing of it to keep or duplicate, R6); one that changed gets the dictation alone,
    /// as heard (R6); an unchanged one gets the merge when the model made one; any other goes back
    /// with the dictation after it.
    private static func overSelection(
        _ context: DictationFieldContext, polish: DictationPolishResult, rawText: String, recheck: Recheck
    ) -> DictationInsertionPlan {
        if case let .replace(reason) = context.verdict {
            return DictationInsertionPlan(text: polish.text, warning: reason, replacedText: nil, outcome: .replaced)
        }
        if case let .changed(before, after) = recheck {
            // ⌘V lands somewhere else now: the merged piece, or the selection put back before the
            // dictation, would copy the old selection there.
            let text = DictationContextFit.fitted(rawText, before: before, after: after, singleLine: context.isSingleLine)
            return DictationInsertionPlan(text: text, warning: selectionChanged, replacedText: nil, outcome: .selectionChanged)
        }
        if context.verdict == .merge, case let .polished(merged, _, _) = polish {
            let text = DictationContextFit.insideSelectionWhitespace(merged, selection: context.selection)
            return DictationInsertionPlan(text: text, warning: nil, replacedText: context.selection, outcome: .merged)
        }
        // Not merged. An appended selection says why; a merge that failed leaves it to the polisher's
        // reason, which already ends "added the dictation after the selection.", and one cut short
        // with Esc shows none (the controller turns it into a skip).
        var warning: String?
        if case let .append(reason) = context.verdict { warning = reason }
        let text = DictationContextFit.appended(polish.text, to: context.selection)
        return DictationInsertionPlan(text: text, warning: warning, replacedText: nil, outcome: .appended)
    }

    /// The text on either side of where the paste lands: the re-check's live text when it has some,
    /// else the snapshot's.
    private static func neighbours(
        _ recheck: Recheck, snapshot context: DictationFieldContext
    ) -> (before: String, after: String) {
        switch recheck {
        case let .unchanged(before, after), let .changed(before, after):
            return (before, after)
        case .unavailable, .notNeeded:
            return (context.before, context.after)
        }
    }
}
