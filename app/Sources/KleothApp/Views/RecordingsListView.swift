import AppKit
import KleothCore
import SwiftUI

/// The **Recordings** scope of the History window: a day-grouped, searchable
/// sidebar of every screen recording in `~/Kleoth/screen-recordings`, plus the
/// viewer (`RecordingDetailView`) beside it.
///
/// Its own `NavigationSplitView`, like `DictationsListView` — a recording row is
/// a movie file with a transcript sidecar, which has nothing in common with a
/// meeting folder or a line of dictated text.
///
/// Reads `ScreenRecordingController` through `@EnvironmentObject` only; the
/// controller is the single writer of a sidecar, so every persistent change the
/// viewer makes comes back out through `onSaveRecord`.
struct RecordingsListView: View {
    @EnvironmentObject private var screenRecording: ScreenRecordingController

    /// The History window's scope, so this list can carry the same picker above
    /// its own sidebar (the `DictationsListView` arrangement).
    @Binding var scope: HistoryScope

    @State private var selection: ScreenRecordingItem.ID?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            screenRecording.reloadRecordings()
            // A deep link from the popover sets the id BEFORE this list is
            // mounted, so `onChange` below never sees it — pick it up here.
            if let deepLink = screenRecording.selectedRecordingID {
                selection = deepLink
                screenRecording.selectedRecordingID = nil
            }
        }
        .onChange(of: screenRecording.recordings) { _, items in
            // Keep the selection valid across a reload (a trash, a finished
            // transcription), falling back to the newest recording.
            let valid = Set(items.map(\.id))
            if let current = selection, valid.contains(current) { return }
            selection = items.first?.id
        }
        // The popover's deep link: it sets the id, then bumps the counter that
        // flipped the scope to Recordings. Both land in the same turn, so this
        // observer is what actually selects the row.
        .onChange(of: screenRecording.selectedRecordingID) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            // Consumed, so the NEXT click on the same recording is a change
            // again — and a stale id can't hijack the selection when this
            // window is closed and reopened.
            screenRecording.selectedRecordingID = nil
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.items) { item in
                        RecordingSidebarRow(
                            item: item,
                            isTranscribing: screenRecording.isTranscribing(item)
                        )
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(
                            top: KleothMetrics.spacingXS,
                            leading: KleothMetrics.spacingS,
                            bottom: KleothMetrics.spacingXS,
                            trailing: KleothMetrics.spacingS
                        ))
                        .contextMenu {
                            Button("Show in Finder") { screenRecording.reveal(item) }
                            Divider()
                            Button(role: .destructive) {
                                screenRecording.trash(item)
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search recordings")
        .navigationTitle("Recordings")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .overlay {
            if screenRecording.recordings.isEmpty {
                ContentUnavailableCompat(
                    title: "No screen recordings yet",
                    systemImage: "record.circle",
                    message: "Record the screen from the menu-bar popover or the pill. Recordings land in your Kleoth folder and are transcribed on device."
                )
            } else if filtered.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    message: "No recordings match “\(search)”."
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { HistoryScopePicker(scope: $scope) }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            RecordingDetailView(
                item: item,
                onSaveRecord: { screenRecording.saveRecord($0, for: item) },
                onTranscribe: { screenRecording.transcribe(item, tier: $0) },
                isTranscribing: screenRecording.isTranscribing(item),
                onReveal: { screenRecording.reveal(item) },
                onTrash: { screenRecording.trash(item) }
            )
            .id(item.id)
        } else {
            ContentUnavailableCompat(
                title: "Select a recording",
                systemImage: "play.rectangle",
                message: "Choose a recording to watch it with its transcript beside it."
            )
        }
    }

    // MARK: - Data

    private var selectedItem: ScreenRecordingItem? {
        guard let selection else { return nil }
        return screenRecording.recordings.first { $0.id == selection }
    }

    /// Newest-first already (the store sorts by recording date); search matches
    /// the title and the transcript itself.
    private var filtered: [ScreenRecordingItem] {
        guard !search.isEmpty else { return screenRecording.recordings }
        let query = search.lowercased()
        return screenRecording.recordings.filter {
            $0.displayTitle.lowercased().contains(query)
                || ($0.record?.text.lowercased().contains(query) ?? false)
        }
    }

    private var groups: [(label: String, items: [ScreenRecordingItem])] {
        var result: [(String, [ScreenRecordingItem])] = []
        for item in filtered {
            let label = RecordingFormat.dayLabel(item.recordedAt)
            if let index = result.firstIndex(where: { $0.0 == label }) {
                result[index].1.append(item)
            } else {
                result.append((label, [item]))
            }
        }
        return result.map { (label: $0.0, items: $0.1) }
    }
}

// MARK: - Row

/// One recording in the sidebar: its name, then when · how long · how big, then
/// the state of its transcript.
private struct RecordingSidebarRow: View {
    let item: ScreenRecordingItem
    let isTranscribing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.displayTitle)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(RecordingFormat.metadata(item))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            badge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, KleothMetrics.spacingXS)
    }

    @ViewBuilder
    private var badge: some View {
        if isTranscribing {
            HStack(spacing: KleothMetrics.spacingXS) {
                ProgressView()
                    .controlSize(.mini)
                KleothPill("Transcribing…", tint: KleothPalette.pendingTint)
            }
            .padding(.top, 1)
        } else {
            switch item.transcriptState {
            case .untranscribed:
                KleothPill("Untranscribed", systemImage: "text.badge.plus", tint: KleothPalette.pendingTint)
                    .padding(.top, 1)
            case .failed(let message):
                KleothPill("Failed", systemImage: "exclamationmark.triangle", tint: KleothPalette.failureTint)
                    .help(message)
                    .padding(.top, 1)
            case .transcribed:
                EmptyView()
            }
        }
    }
}

// MARK: - Formatting

/// Date / duration / size formatting for the recordings surfaces, kept next to
/// them (`MeetingFormat` and `DictationFormat` are the equivalents).
enum RecordingFormat {
    /// "Today" / "Yesterday" / "September 6, 2026" — the sidebar's day sections.
    static func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "3:14 PM · 02:14 · 48 MB". The duration is dropped until it is known —
    /// probing an `.mp4` per row would be file I/O inside a `List`, and a fresh
    /// recording's sidecar carries the measured value anyway.
    ///
    /// Reuses `ElapsedFormatter` so the row, the pill and the popover can never
    /// disagree about what "02:14" means.
    static func metadata(_ item: ScreenRecordingItem) -> String {
        var parts: [String] = []
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        parts.append(time.string(from: item.recordedAt))
        if let seconds = item.record?.durationSecs, seconds > 0 {
            parts.append(ElapsedFormatter.string(seconds: Int(seconds.rounded())))
        }
        parts.append(ScreenRecordingFileNaming.sizeText(bytes: item.sizeBytes))
        return parts.joined(separator: " · ")
    }
}
