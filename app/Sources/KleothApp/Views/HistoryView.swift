import SwiftUI
import KleothCore

/// Resizable window for browsing ALL meetings: a searchable, day-grouped
/// sidebar plus a detail pane. This is the "full scale" history; the menu-bar
/// popover stays a control surface.
struct HistoryView: View {
    @EnvironmentObject private var controller: RecordingController
    @State private var selection: RecentMeeting.ID?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            controller.loadRecentMeetings()
            if selection == nil {
                selection = controller.selectedMeetingID ?? controller.recentMeetings.first?.id
            }
        }
        .onChange(of: controller.selectedMeetingID) { _, newValue in
            if let newValue { selection = newValue }
        }
        .onChange(of: controller.recentMeetings) { _, meetings in
            // Keep selection valid as the list reloads (e.g. after a delete or a
            // background scan); fall back to the newest meeting.
            if selection == nil || !meetings.contains(where: { $0.id == selection }) {
                selection = meetings.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.meetings) { meeting in
                        MeetingSidebarRow(meeting: meeting)
                            .tag(meeting.id)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
        .navigationTitle("Meetings")
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .overlay {
            if controller.recentMeetings.isEmpty {
                ContentUnavailableCompat(
                    title: "No meetings yet",
                    systemImage: "waveform",
                    message: "Record a call from the menu bar, or run `kleoth transcribe`. Meetings appear here automatically."
                )
            } else if filtered.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    message: "No meetings match “\(search)”."
                )
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let meeting = controller.recentMeetings.first(where: { $0.id == selection }) {
            MeetingDetailView(meeting: meeting)
                .environmentObject(controller)
                .id(meeting.id) // rebuild (and reload) when the selection changes
        } else {
            ContentUnavailableCompat(
                title: "Select a meeting",
                systemImage: "doc.text",
                message: "Choose a meeting from the list to read its transcript and summary."
            )
        }
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

/// One row in the history sidebar: title plus a secondary time · duration line
/// and the meeting cost.
private struct MeetingSidebarRow: View {
    let meeting: RecentMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let time = MeetingFormat.time(meeting) {
                    Text(time)
                }
                if let duration = MeetingFormat.duration(meeting.durationSecs) {
                    Text("· \(duration)")
                }
                Spacer()
                Text(MeetingFormat.usd(meeting.costUSD))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
