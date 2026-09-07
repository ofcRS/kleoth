import AppKit
import KleothCore
import SwiftUI

/// The transcript pane of the Recordings viewer: the words as running text, the
/// spoken one highlighted, a click to seek and a double-click to fix a
/// mistranscription.
///
/// Stateless with respect to the sidecar — every edit leaves through
/// `onSaveRecord`, so the library stays the single writer of the `.json` next to
/// the movie (and this view re-renders from the republished `record`).
struct RecordingTranscriptView: View {
    let record: ScreenRecordingRecord?
    let state: ScreenRecordingItem.TranscriptState
    /// True while a transcription job for this recording is queued or running.
    let isTranscribing: Bool
    /// The word being spoken right now, resolved by the *caller* from the play
    /// head. Deliberately not the raw `currentTime`: that changes 10× a second
    /// and would re-evaluate every word view with it, where this changes only
    /// when the highlight actually moves.
    let highlightIndex: Int?
    /// Auto-scroll follows the highlight only while the movie is actually
    /// playing, so a paused reader can scroll wherever they like in peace.
    let isPlaying: Bool
    let onSeek: (Double) -> Void
    let onSaveRecord: (ScreenRecordingRecord) -> Void
    /// `TranscriptTier.local` / `.sotaScribe`.
    let onTranscribe: (String) -> Void

    /// Silence (in seconds) between two words that reads as a paragraph break.
    static let paragraphGapSeconds: Double = 1.5

    /// The word currently being edited in place, if any.
    @State private var editingIndex: Int?
    @State private var editDraft = ""
    /// Width the inline field is pinned to, measured from the word it replaces —
    /// without it the paragraph reflows the moment an edit begins.
    @State private var editWidth: CGFloat = 40
    @FocusState private var editFocus: Int?

    private var words: [RecordingWord] { record?.words ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            if isTranscribing {
                transcribingRow
            }
            switch state {
            case .transcribed:
                paragraph
            case .untranscribed:
                emptyState
            case let .failed(message):
                failedState(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Click-away commits, Finder-style. Keyed on the field that *lost* focus
        // and only while that same word is still the open edit: a Return, an Esc
        // or a jump to another word have all already committed and cleared
        // `editingIndex`, so none of them can arrive here as a second commit.
        .onChange(of: editFocus) { oldValue, newValue in
            guard let lost = oldValue, lost != newValue, editingIndex == lost else { return }
            commitEdit()
        }
        // The word list changed under an open edit (our own save, or a
        // re-transcription landing) — the pinned index no longer means what it
        // meant when the edit began, so drop it rather than write to the wrong
        // word. A no-op right after our own commit, which already ended it.
        .onChange(of: words.count) { _, _ in endEdit() }
        .onDisappear { endEdit() }
    }

    // MARK: - The paragraph

    private var paragraph: some View {
        ScrollViewReader { proxy in
            ScrollView {
                WordFlowLayout {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        wordView(index: index, word: word)
                            .id(index)
                            .recordingParagraphBreak(startsParagraph(at: index))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(KleothMetrics.spacingM)
            }
            .kleothSoftScrollEdge()
            .onChange(of: highlightIndex) { _, newValue in
                // Only while playing, and never while the user is typing into a
                // word — otherwise the scroll fights them for the viewport.
                guard isPlaying, editingIndex == nil, let newValue else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(
            .quaternary.opacity(0.25),
            in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(KleothPalette.hairlineStroke, lineWidth: KleothMetrics.hairline)
        )
    }

    /// One word: a tappable chip in normal state, an inline field while edited.
    @ViewBuilder
    private func wordView(index: Int, word: RecordingWord) -> some View {
        if editingIndex == index {
            TextField("", text: $editDraft)
                .textFieldStyle(.plain)
                .font(Self.wordFont)
                .frame(width: editWidth)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    Color.accentColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: KleothMetrics.hairline)
                )
                .focused($editFocus, equals: index)
                .onSubmit { commitEdit() }
                .onExitCommand { cancelEdit() }
        } else {
            let isCurrent = highlightIndex == index
            Text(word.text)
                .font(Self.wordFont)
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous))
                // Double first: SwiftUI resolves the higher count before the
                // single tap, so an edit doesn't also count as a seek.
                .onTapGesture(count: 2) { beginEdit(index: index, word: word) }
                .onTapGesture { onSeek(word.start) }
                .help("\(Self.timestamp(word.start)) — click to jump here, double-click to correct")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(word.text)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isCurrent ? "Now playing" : "")
                .accessibilityHint("Jumps playback to \(Self.timestamp(word.start))")
                .accessibilityAction { onSeek(word.start) }
        }
    }

    /// A gap longer than `paragraphGapSeconds` since the previous word starts a
    /// new paragraph — the transcript then reads as speech, not as one wall.
    private func startsParagraph(at index: Int) -> Bool {
        guard index > 0, words.indices.contains(index) else { return false }
        return words[index].start - words[index - 1].end > Self.paragraphGapSeconds
    }

    /// A word's position as the rest of the screen-recording surfaces write it
    /// ("02:14") — `ElapsedFormatter` is the one formatter for these digits.
    private static func timestamp(_ seconds: Double) -> String {
        ElapsedFormatter.string(seconds: Int(seconds.rounded(.down)))
    }

    /// `.body` as an explicit point size, so `measuredWidth(for:)` can size the
    /// inline field with the same font AppKit will actually draw.
    private static let wordFont = Font.system(size: NSFont.systemFontSize)

    // MARK: - Inline word editing
    //
    // Commit paths are Return (`onSubmit`) and click-away (the focus observer);
    // Esc cancels. `endEdit()` clears `editingIndex` *before* focus, so the
    // observer can never turn a commit or a cancel into a second commit —
    // the same discipline as HistoryView's inline rename.

    private func beginEdit(index: Int, word: RecordingWord) {
        guard record != nil, words.indices.contains(index) else { return }
        // Clicking straight from one open field into another word normally
        // resigns focus first (which commits); commit explicitly so the pending
        // draft can never be silently overwritten if it doesn't.
        if let editing = editingIndex, editing != index { commitEdit() }
        editDraft = word.text
        editWidth = Self.measuredWidth(for: word.text)
        editingIndex = index
        // One runloop tick: the field has to exist before it can be made first
        // responder (it then select-alls, like Finder's rename).
        DispatchQueue.main.async { editFocus = index }
    }

    private func commitEdit() {
        guard let index = editingIndex, let record else { return }
        let draft = editDraft
        endEdit()
        guard record.words.indices.contains(index) else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged text writes nothing; an empty one deletes the word
        // (`replacingWord` does the removal).
        guard trimmed != record.words[index].text else { return }
        onSaveRecord(record.replacingWord(at: index, with: trimmed))
    }

    private func cancelEdit() {
        endEdit()
    }

    private func endEdit() {
        editingIndex = nil
        editFocus = nil
        editDraft = ""
    }

    /// Rendered width of `text` in the word font, plus the chip's padding — so
    /// swapping a word for a field doesn't reflow the paragraph under the cursor.
    private static func measuredWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return max(32, ceil(width) + 10)
    }

    // MARK: - Non-transcript states

    private var transcribingRow: some View {
        HStack(spacing: KleothMetrics.spacingS) {
            ProgressView().controlSize(.small)
            Text("Transcribing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .kleothCard(padding: KleothMetrics.spacingM)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: KleothMetrics.spacingM) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No transcript yet")
                .font(.headline)
            Text("Transcribe the recording to read along, jump to any word, and fix what the engine misheard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            transcribeButtons(retry: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(KleothMetrics.spacingL)
    }

    private func failedState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            errorCard(message)
            transcribeButtons(retry: true)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)
        }
        .padding(KleothMetrics.spacingL)
    }

    /// Same shape as `MeetingDetailView`'s per-meeting failure card — a
    /// transcription that fell over should read the same everywhere.
    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: KleothMetrics.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(KleothPalette.failureTint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
                Text("Transcription failed")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(KleothMetrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            KleothPalette.failureTint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(KleothPalette.failureTint.opacity(0.25), lineWidth: KleothMetrics.hairline)
        )
    }

    /// The two engines, worded the way the meeting detail pane words them.
    private func transcribeButtons(retry: Bool) -> some View {
        VStack(spacing: KleothMetrics.spacingS) {
            Button {
                onTranscribe(TranscriptTier.local)
            } label: {
                Label(retry ? "Try again on device" : "Transcribe on device", systemImage: "desktopcomputer")
                    .padding(.horizontal, KleothMetrics.spacingS)
            }
            .kleothProminentButton()
            .controlSize(.large)
            .disabled(isTranscribing)
            .help("Transcribe with the free on-device engine — nothing leaves this Mac.")

            Button {
                onTranscribe(TranscriptTier.sotaScribe)
            } label: {
                Label(retry ? "Try again in cloud" : "Transcribe in cloud", systemImage: "cloud")
                    .padding(.horizontal, KleothMetrics.spacingS)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isTranscribing)
            .help("Transcribe in the cloud with ElevenLabs Scribe — higher accuracy, needs an API key.")
        }
    }
}
