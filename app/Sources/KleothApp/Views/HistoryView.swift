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
        // Become a regular, ⌘-Tab-able app while this window is open, then revert
        // to a pure menu-bar agent when it closes. Without this, an LSUIElement
        // (.accessory) app's windows don't show in the ⌘-Tab switcher.
        .onAppear { AppActivation.shared.windowOpened() }
        .onDisappear { AppActivation.shared.windowClosed() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.meetings) { meeting in
                        MeetingSidebarRow(meeting: meeting)
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
                message: "Choose a meeting from the list to read its transcript and summary.",
                illustration: .selectMeeting
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

/// One row in the history sidebar: a title with clear hierarchy over a secondary
/// "time · duration" line and a color-coded tier badge (or an "Untranscribed"
/// chip). Built from the shared Kleoth design system so it reads as one product
/// with the rest of the app. No costs here — provider usage lives in
/// Settings → Usage only.
private struct MeetingSidebarRow: View {
    let meeting: RecentMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Primary: the meeting title carries the row's weight.
            Text(meeting.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .truncationMode(.tail)

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

    /// "5:26 PM · 12m 03s", dropping whichever piece is unknown.
    private var timeAndDuration: String? {
        let parts = [MeetingFormat.time(meeting), MeetingFormat.duration(meeting.durationSecs)]
            .compactMap { $0 }
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
        } else if meeting.isProcessed {
            KleothTierBadge(isSOTA: TranscriptTier.isSOTA(meeting.transcriptTier))
        } else {
            KleothPill("Untranscribed", systemImage: "waveform.badge.exclamationmark", tint: KleothPalette.pendingTint)
        }
    }
}
