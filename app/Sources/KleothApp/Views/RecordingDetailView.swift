import AppKit
import AVKit
import KleothCore
import SwiftUI

/// The Recordings viewer: the movie with its transcript beside it. The current
/// word highlights during playback, a click on a word seeks there, a
/// double-click edits it in place. The view owns playback only; every
/// persistent change goes out through the callbacks so the library stays the
/// single writer of the sidecar.
///
/// Layout is Loom-shaped — video left, transcript right — and stacks the
/// transcript underneath when the window is too narrow to hold both.
struct RecordingDetailView: View {
    let item: ScreenRecordingItem
    /// The user edited one word (or the title). The caller persists the record
    /// and republishes `item`.
    let onSaveRecord: (ScreenRecordingRecord) -> Void
    /// "Transcribe on device" / "Transcribe in cloud" (`TranscriptTier.local` /
    /// `.sotaScribe`).
    let onTranscribe: (String) -> Void
    /// True while a transcription job for this recording is queued or running.
    let isTranscribing: Bool
    let onReveal: () -> Void
    let onTrash: () -> Void

    /// Width of the transcript column beside the video.
    private static let transcriptWidth: CGFloat = 340
    /// Below this, the two panes stack instead of sitting side by side — the
    /// video would otherwise squeeze the transcript to an unreadable ribbon.
    private static let stackedLayoutWidth: CGFloat = 760

    @StateObject private var player = RecordingPlayerModel()

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    @State private var confirmTrash = false
    @State private var copied = false
    /// Reverts the copy button's checkmark; cancel-and-restart so rapid copies
    /// keep it a full beat from the most recent one (the house idiom).
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            headerCard
            GeometryReader { geometry in
                if geometry.size.width < Self.stackedLayoutWidth {
                    VStack(spacing: KleothMetrics.spacingM) {
                        videoPane
                            .frame(maxHeight: geometry.size.height * 0.55)
                        transcriptPane
                    }
                } else {
                    HStack(alignment: .top, spacing: KleothMetrics.spacingM) {
                        videoPane
                        transcriptPane
                            .frame(width: Self.transcriptWidth)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 360)
        .navigationTitle(item.displayTitle)
        .toolbar { toolbarContent }
        .onAppear { player.load(item.url, fallbackDuration: item.record?.durationSecs) }
        // The caller pins identity with `.id(item.id)`, but a re-render after a
        // save hands us the same view with a fresh record — reload only when the
        // file itself changed (`load` is idempotent per URL anyway).
        .onChange(of: item.url) { _, newURL in
            player.load(newURL, fallbackDuration: item.record?.durationSecs)
        }
        .onDisappear {
            player.teardown()
            copiedResetTask?.cancel()
            copied = false
        }
        .confirmationDialog(
            "Move “\(item.displayTitle)” to the Trash?",
            isPresented: $confirmTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { onTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The movie and its transcript go to the Trash.")
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
            titleField
            KleothFlowLayout(spacing: KleothMetrics.spacingS) {
                KleothPill(dateTimeChip, systemImage: "calendar")
                if let duration = MeetingFormat.duration(durationSeconds) {
                    KleothPill(duration, systemImage: "clock")
                }
                if let size = MeetingFormat.fileSize(item.sizeBytes) {
                    KleothPill(size, systemImage: "internaldrive")
                }
                if let tier = item.record?.transcriptTier, !tier.isEmpty {
                    KleothTierBadge(isSOTA: TranscriptTier.isSOTA(tier))
                        .help(item.record?.transcriptModel.map { "Transcribed with \($0)" } ?? "")
                }
                if case .untranscribed = item.transcriptState, !isTranscribing {
                    KleothPill("No transcript", systemImage: "text.bubble", tint: KleothPalette.pendingTint)
                }
            }
        }
        .kleothCard()
    }

    /// The title, editable in place: click to edit, Return commits, Esc cancels,
    /// click-away commits. Mirrors HistoryView's inline rename, including the
    /// clear-`isEditingTitle`-before-focus ordering that keeps the focus
    /// observer from double-committing.
    @ViewBuilder
    private var titleField: some View {
        if isEditingTitle {
            TextField("Recording title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { cancelTitle() }
                .onChange(of: titleFocused) { _, focused in
                    guard isEditingTitle, !focused else { return }
                    commitTitle()
                }
        } else {
            Text(item.displayTitle)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginTitleEdit() }
                .help("Click to rename this recording")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Renames this recording")
        }
    }

    /// "Sep 6, 2026 · 2:30 PM" — when the recording was made.
    private var dateTimeChip: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: item.recordedAt)
    }

    /// The sidecar's duration until the asset reports its own.
    private var durationSeconds: Double? {
        if player.duration > 0 { return player.duration }
        return item.record?.durationSecs
    }

    // MARK: - Panes

    private var videoPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                .fill(Color.black)
            if let avPlayer = player.player {
                // AVKit letterboxes inside whatever frame it gets, so the movie
                // keeps its aspect ratio without us having to load the track's
                // natural size just to lay the pane out.
                VideoPlayer(player: avPlayer)
                    .clipShape(RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(KleothPalette.hairlineStroke, lineWidth: KleothMetrics.hairline)
        )
        // Space toggles playback when the pane holds focus. AVKit's own transport
        // handles it while the video view itself is focused; this covers the
        // click-anywhere-then-hit-space case.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            player.togglePlay()
            return .handled
        }
        .accessibilityLabel("Screen recording")
    }

    /// The word under the play head. Resolved here (a binary search in
    /// KleothCore) rather than inside the transcript, so the pane's stored
    /// properties change only when the highlight moves — not 10× a second with
    /// every `currentTime` tick.
    private var highlightIndex: Int? {
        item.record?.wordIndex(at: player.currentTime)
    }

    private var transcriptPane: some View {
        RecordingTranscriptView(
            record: item.record,
            state: item.transcriptState,
            isTranscribing: isTranscribing,
            highlightIndex: highlightIndex,
            isPlaying: player.isPlaying,
            onSeek: { player.seek(to: $0) },
            onSaveRecord: onSaveRecord,
            onTranscribe: onTranscribe
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { copyTranscript() } label: {
                Label(copied ? "Copied!" : "Copy transcript", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .disabled(!hasTranscript)
            .help("Copy the whole transcript as plain text")

            Button { onReveal() } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show this recording in Finder")

            Menu {
                Button("On device") { onTranscribe(TranscriptTier.local) }
                Button("In cloud") { onTranscribe(TranscriptTier.sotaScribe) }
            } label: {
                Label("Re-transcribe", systemImage: "sparkles")
            }
            .disabled(!hasTranscript || isTranscribing)
            .help("Transcribe this recording again with the other engine — the current words are replaced")

            Button(role: .destructive) { confirmTrash = true } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move this recording and its transcript to the Trash")
        }
    }

    private var hasTranscript: Bool {
        item.record?.hasTranscript ?? false
    }

    // MARK: - Actions

    private func copyTranscript() {
        guard let text = item.record?.text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedResetTask?.cancel()
        copied = true
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    // MARK: - Title editing

    private func beginTitleEdit() {
        titleDraft = item.displayTitle
        isEditingTitle = true
        // One runloop tick so the field exists before it is asked to become
        // first responder (it then select-alls its text).
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        let draft = titleDraft
        endTitleEdit()
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.displayTitle else { return }
        // No sidecar yet (an untranscribed recording) → the title creates one.
        var record = item.record ?? ScreenRecordingRecord()
        record.title = trimmed.isEmpty ? nil : trimmed
        onSaveRecord(record)
    }

    private func cancelTitle() {
        endTitleEdit()
    }

    private func endTitleEdit() {
        isEditingTitle = false
        titleFocused = false
        titleDraft = ""
    }
}
