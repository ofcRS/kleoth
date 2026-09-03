import SwiftUI
import AppKit
import KleothCore

/// Which history the window is showing. Meetings and dictations are different
/// enough — a Finder-like folder list vs. a text-only log — that each gets its
/// own `NavigationSplitView` behind a scope picker, rather than one list over a
/// union ID type threaded through the meetings sidebar.
enum HistoryScope: String, CaseIterable, Identifiable {
    case meetings, dictations

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meetings: return "Meetings"
        case .dictations: return "Dictations"
        }
    }
}

/// The scope switch. It lives in the sidebar's top safe area — not the window
/// toolbar, where it would read as a window-level mode switch rather than a
/// filter over the list beneath it.
struct HistoryScopePicker: View {
    @Binding var scope: HistoryScope

    var body: some View {
        Picker("", selection: $scope) {
            ForEach(HistoryScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, KleothMetrics.spacingS)
        .padding(.vertical, KleothMetrics.spacingS)
        .background(.bar)
    }
}

/// Resizable window for browsing ALL meetings: a searchable, day-grouped
/// sidebar plus a detail pane. This is the "full scale" history; the menu-bar
/// popover stays a control surface. A segmented picker above the sidebar swaps
/// it for the dictation log (`DictationsListView`).
///
/// The meetings sidebar behaves like Finder: ⌘-click / ⇧-click multi-select, ⌫
/// (or the context menu) moves the selection to the Trash with no confirmation
/// (it's recoverable — per the HIG, undoable actions don't get alerts), and
/// double-click renames the meeting inline.
struct HistoryView: View {
    @EnvironmentObject private var controller: RecordingController
    @State private var scope: HistoryScope = .meetings
    @State private var selection = Set<RecentMeeting.ID>()
    @State private var search = ""

    // Inline rename (Finder-style): which row is editing, and the draft title.
    @State private var renamingID: RecentMeeting.ID?
    @State private var renameDraft = ""
    @FocusState private var renameFocus: RecentMeeting.ID?

    var body: some View {
        // The window-lifetime hooks live HERE, above the scope switch — not on
        // the meetings split view. Attached to a branch they would tear that
        // branch down on every scope flip: `windowClosed()` (a needless
        // activation-policy flip) plus a re-run of the meetings reload on the way
        // back. Up here they fire once per window, as intended.
        Group {
            switch scope {
            case .meetings: meetingsScope
            case .dictations: DictationsListView(scope: $scope)
            }
        }
        .task {
            controller.loadRecentMeetings()
            if selection.isEmpty,
               let initial = controller.selectedMeetingID ?? controller.recentMeetings.first?.id {
                selection = [initial]
            }
        }
        // Become a regular, ⌘-Tab-able app while this window is open, then revert
        // to a pure menu-bar agent when it closes. Without this, an LSUIElement
        // (.accessory) app's windows don't show in the ⌘-Tab switcher.
        .onAppear { AppActivation.shared.windowOpened() }
        .onDisappear { AppActivation.shared.windowClosed() }
        // The popover's deep links live up here too, NOT on the meetings
        // branch: that branch isn't mounted while the scope is Dictations, so
        // a row click in the popover would bring the window forward still
        // showing dictations and select nothing. Both observers force the
        // scope; the request counter also covers "Show all meetings…" (no id)
        // and a repeat click on the already-selected meeting (no id change).
        .onChange(of: controller.meetingsHistoryRequest) { _, _ in
            scope = .meetings
            if let id = controller.selectedMeetingID { selection = [id] }
        }
        .onChange(of: controller.selectedMeetingID) { _, newValue in
            guard let newValue else { return }
            scope = .meetings
            selection = [newValue]
        }
    }

    /// The meetings scope, unchanged. Its two remaining `.onChange` handlers
    /// stay here: they maintain meetings-only state (selection validity, the
    /// rename field), and neither fires on mount, so a scope flip costs nothing.
    private var meetingsScope: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onChange(of: controller.recentMeetings) { _, meetings in
            // Keep selection valid as the list reloads (e.g. after a delete or a
            // background scan): drop vanished ids, fall back to the newest meeting.
            let valid = Set(meetings.map(\.id))
            selection = selection.intersection(valid)
            if selection.isEmpty, let first = meetings.first?.id {
                selection = [first]
            }
            // A row that disappeared mid-edit can't keep its rename field.
            if let renaming = renamingID, !valid.contains(renaming) {
                cancelRename()
            }
        }
        .onChange(of: renameFocus) { _, newValue in
            // Click-away commits, Finder-style. Cancel (Esc) clears `renamingID`
            // BEFORE focus resigns, so this observer sees nil and does nothing.
            if let renaming = renamingID, newValue != renaming {
                commitRename()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.meetings) { meeting in
                        MeetingSidebarRow(
                            meeting: meeting,
                            errorMessage: controller.meetingError(for: meeting.directory),
                            isRenaming: renamingID == meeting.id,
                            renameDraft: $renameDraft,
                            renameFocus: $renameFocus,
                            onCommit: commitRename,
                            onCancel: cancelRename
                        )
                        .tag(meeting.id)
                        .listRowInsets(EdgeInsets(
                            top: KleothMetrics.spacingXS,
                            leading: KleothMetrics.spacingS,
                            bottom: KleothMetrics.spacingXS,
                            trailing: KleothMetrics.spacingS
                        ))
                    }
                }
            }
        }
        // Right-click menu + double-click, attached to the List (the selection
        // container). The closure's set reflects what was actually clicked — the
        // full selection, or just the row under the pointer when it sits outside
        // the selection — so never read `selection` in here.
        .contextMenu(forSelectionType: RecentMeeting.ID.self) { ids in
            contextMenuItems(for: ids)
        } primaryAction: { ids in
            // Double-click (and Return) on a single row → inline rename, like Finder.
            guard ids.count == 1, let id = ids.first, let meeting = meeting(for: id) else { return }
            beginRename(meeting)
        }
        // ⌫ moves the current selection to the Trash (needs List keyboard focus).
        .onDeleteCommand { deleteMeetings(with: selection) }
        .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
        .navigationTitle("Meetings")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .overlay {
            if controller.recentMeetings.isEmpty {
                ContentUnavailableCompat(
                    title: "No meetings yet",
                    systemImage: "waveform",
                    message: "Record a call from the menu bar, or run `kleoth transcribe`. Meetings appear here automatically.",
                    illustration: .noMeetings
                )
            } else if filtered.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    message: "No meetings match “\(search)”."
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { HistoryScopePicker(scope: $scope) }
    }

    /// Context-menu body for a right-clicked set of rows. Rename only offers
    /// itself for a single meeting with a `meta.json` to hold the title (a
    /// never-transcribed folder has none yet; a reverted one keeps its).
    @ViewBuilder
    private func contextMenuItems(for ids: Set<RecentMeeting.ID>) -> some View {
        if !ids.isEmpty {
            if ids.count == 1, let id = ids.first, let meeting = meeting(for: id),
               meeting.hasMetadata, !meeting.isTranscribing {
                Button("Rename") { beginRename(meeting) }
            }
            Button("Show in Finder") {
                let urls = ids.compactMap { meeting(for: $0)?.directory }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            // Revert to audio-only (artifacts go to the Trash; title/audio stay).
            // `ids` is authoritative here — never read `selection` in this closure.
            let revertible = ids.compactMap { meeting(for: $0) }
                .filter { $0.isProcessed && !$0.isTranscribing }
            if !revertible.isEmpty {
                Button("Remove Transcription") {
                    controller.removeTranscriptions(revertible)
                }
            }
            Divider()
            Button(role: .destructive) {
                deleteMeetings(with: ids)
            } label: {
                Label(
                    ids.count > 1 ? "Move \(ids.count) to Trash" : "Move to Trash",
                    systemImage: "trash"
                )
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let selected = controller.recentMeetings.filter { selection.contains($0.id) }
        if selected.count > 1 {
            multiSelectionState(selected)
        } else if let meeting = selected.first {
            MeetingDetailView(meeting: meeting)
                .environmentObject(controller)
                .id(meeting.id) // rebuild (and reload) when the selection changes
        } else {
            ContentUnavailableCompat(
                title: "Select a meeting",
                systemImage: "doc.text",
                message: "Choose a meeting from the list to read its transcript and summary.",
                illustration: .selectMeeting
            )
        }
    }

    /// "N selected" placeholder with the bulk action, shown while ⌘-selecting
    /// several rows (Mail/Finder norm for a multi-selection detail pane).
    private func multiSelectionState(_ meetings: [RecentMeeting]) -> some View {
        VStack(spacing: KleothMetrics.spacingM) {
            Image(systemName: "square.stack.3d.up")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(meetings.count) meetings selected")
                .font(.headline)
            Text(multiSelectionSubtitle(meetings))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(role: .destructive) {
                controller.deleteMeetings(meetings)
            } label: {
                Label("Move \(meetings.count) to Trash", systemImage: "trash")
            }
            .padding(.top, KleothMetrics.spacingS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// "Combined length: 42m 10s · 214 MB on disk." when durations/sizes are
    /// known, plus the recoverability note for the bulk delete. Sizes resolve in
    /// the background, so the disk total covers whichever rows have one so far.
    private func multiSelectionSubtitle(_ meetings: [RecentMeeting]) -> String {
        let total = meetings.compactMap(\.durationSecs).reduce(0, +)
        let bytes = meetings.compactMap(\.sizeBytes).reduce(0, +)
        let recoverable = "Deleting moves the meeting folders to the Trash."
        var parts: [String] = []
        if total > 0, let formatted = MeetingFormat.duration(total) {
            parts.append("Combined length: \(formatted)")
        }
        if let size = MeetingFormat.fileSize(bytes) {
            parts.append("\(size) on disk")
        }
        guard !parts.isEmpty else { return recoverable }
        return "\(parts.joined(separator: " · ")). \(recoverable)"
    }

    // MARK: - Actions

    private func meeting(for id: RecentMeeting.ID) -> RecentMeeting? {
        controller.recentMeetings.first { $0.id == id }
    }

    private func deleteMeetings(with ids: Set<RecentMeeting.ID>) {
        let meetings = controller.recentMeetings.filter { ids.contains($0.id) }
        guard !meetings.isEmpty else { return }
        controller.deleteMeetings(meetings)
        // onChange(of: recentMeetings) re-points the selection at the newest row.
    }

    // MARK: - Inline rename

    private func beginRename(_ meeting: RecentMeeting) {
        // In-flight rows and folders without a meta.json (never transcribed)
        // can't hold a title yet; a reverted meeting keeps its meta and renames.
        guard meeting.hasMetadata, !meeting.isTranscribing else { return }
        renameDraft = meeting.title
        renamingID = meeting.id
        selection = [meeting.id]
        // Defer focus one runloop tick so the TextField exists before it's asked
        // to become first responder (it then select-alls its text, like Finder).
        DispatchQueue.main.async { renameFocus = meeting.id }
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        let draft = renameDraft
        endRename() // clears focus first so the focus observer can't double-commit
        if let meeting = meeting(for: id) {
            controller.renameMeeting(meeting, to: draft) // trims; ignores empty/unchanged
        }
    }

    private func cancelRename() {
        endRename()
    }

    private func endRename() {
        renamingID = nil
        renameFocus = nil
        renameDraft = ""
    }

    // MARK: - Filtering / grouping

    private var filtered: [RecentMeeting] {
        guard !search.isEmpty else { return controller.recentMeetings }
        let query = search.lowercased()
        return controller.recentMeetings.filter {
            $0.title.lowercased().contains(query) || $0.date.contains(query)
        }
    }

    /// Filtered meetings grouped into day sections, preserving the existing
    /// reverse-chronological order.
    private var groups: [(label: String, meetings: [RecentMeeting])] {
        var result: [(String, [RecentMeeting])] = []
        for meeting in filtered {
            let label = MeetingFormat.dayLabel(meeting)
            if let index = result.firstIndex(where: { $0.0 == label }) {
                result[index].1.append(meeting)
            } else {
                result.append((label, [meeting]))
            }
        }
        return result.map { (label: $0.0, meetings: $0.1) }
    }
}

/// One row in the history sidebar: a title with clear hierarchy over a secondary
/// "time · duration" line and a color-coded tier badge (or an "Untranscribed"
/// chip). While renaming, the title swaps to an inline plain TextField (Enter
/// commits, Esc cancels — wiring lives in the parent). Built from the shared
/// Kleoth design system so it reads as one product with the rest of the app.
/// No costs here — provider usage lives in Settings → Usage only.
private struct MeetingSidebarRow: View {
    let meeting: RecentMeeting
    /// The last failed run's error for this meeting, if any — shows a "Failed"
    /// chip so a reverted row explains itself (full text in the detail pane).
    let errorMessage: String?
    let isRenaming: Bool
    @Binding var renameDraft: String
    var renameFocus: FocusState<RecentMeeting.ID?>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Primary: the meeting title carries the row's weight.
            if isRenaming {
                TextField("Meeting title", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused(renameFocus, equals: meeting.id)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
            } else {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            // Secondary: when it started and how long it ran.
            if let metadata = timeAndDuration {
                Text(metadata)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Status / quality: an "Untranscribed" chip for audio-only folders,
            // otherwise the transcription-tier badge (On-device / Cloud).
            statusBadge
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, KleothMetrics.spacingXS)
    }

    /// "5:26 PM · 12m 03s · 214 MB", dropping whichever pieces are unknown.
    private var timeAndDuration: String? {
        let parts = [
            MeetingFormat.time(meeting),
            MeetingFormat.duration(meeting.durationSecs),
            MeetingFormat.fileSize(meeting.sizeBytes),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if meeting.isTranscribing {
            HStack(spacing: KleothMetrics.spacingXS) {
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing…")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: KleothMetrics.spacingXS) {
                if meeting.isProcessed {
                    KleothTierBadge(isSOTA: TranscriptTier.isSOTA(meeting.transcriptTier))
                } else {
                    KleothPill("Untranscribed", systemImage: "waveform.badge.exclamationmark", tint: KleothPalette.pendingTint)
                }
                if let errorMessage {
                    KleothPill("Failed", systemImage: "exclamationmark.triangle", tint: KleothPalette.failureTint)
                        .help(errorMessage)
                }
            }
        }
    }
}
