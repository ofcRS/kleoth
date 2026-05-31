import SwiftUI
import AppKit
import KleothCore

/// The menu-bar popover: a lean control surface — record, live status, session
/// cost, and the few most recent meetings. Full browsing lives in the History
/// window (opened from here), not in this cramped popover.
struct MenuView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !controller.consentAcknowledged {
                ConsentView()
                    .environmentObject(controller)
                Divider()
            }

            recordControl
            statusLine

            Divider()
            recentSection

            Divider()
            footer
        }
        .padding()
        .frame(width: 340)
        .onAppear { controller.loadRecentMeetings() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "waveform")
                .foregroundStyle(controller.isRecording ? Color.red : Color.accentColor)
            Text("Kleoth")
                .font(.headline)
            Spacer()
            if controller.isRecording {
                RecordingIndicator()
            }
        }
    }

    // MARK: - Record control

    @ViewBuilder
    private var recordControl: some View {
        Button {
            Task {
                if controller.isRecording {
                    await controller.stop()
                } else {
                    await controller.start()
                }
            }
        } label: {
            Label(
                controller.isRecording ? "Stop Recording" : "Start Recording",
                systemImage: controller.isRecording ? "stop.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .kleothProminentButton()
        .tint(controller.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(!controller.consentAcknowledged || controller.isProcessing)

        HStack {
            Text("Session cost")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(MeetingFormat.usd(controller.currentCostUSD))
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            if controller.isProcessing {
                ProgressView().controlSize(.small)
            }
            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    // MARK: - Recent meetings (quick links into the History window)

    @ViewBuilder
    private var recentSection: some View {
        Text("Recent meetings")
            .font(.subheadline.bold())

        if controller.recentMeetings.isEmpty {
            Text("No meetings yet. Record a call, or run `kleoth transcribe` — they show up here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(controller.recentMeetings.prefix(5))) { meeting in
                    Button { openHistory(select: meeting.id) } label: {
                        recentRow(meeting)
                    }
                    .buttonStyle(.plain)
                }
                if controller.recentMeetings.count > 5 {
                    Button("Show all \(controller.recentMeetings.count) meetings…") {
                        openHistory(select: nil)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func recentRow(_ meeting: RecentMeeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(rowSubtitle(meeting))
                Spacer()
                Text(MeetingFormat.usd(meeting.costUSD))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func rowSubtitle(_ meeting: RecentMeeting) -> String {
        var head = meeting.date
        if let time = MeetingFormat.time(meeting) { head += " · \(time)" }
        if let duration = MeetingFormat.duration(meeting.durationSecs) { head += " · \(duration)" }
        return head
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                openHistory(select: nil)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            Spacer()

            Button {
                // LSUIElement agents must activate before opening a window/panel.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .font(.callout)
    }

    private func openHistory(select id: RecentMeeting.ID?) {
        controller.selectedMeetingID = id
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "kleoth-history")
    }
}

/// A small animated red dot + "Recording" label.
private struct RecordingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            Text("Recording")
                .font(.caption2)
                .foregroundStyle(.red)
        }
        .onAppear { pulsing = true }
    }
}
