import SwiftUI
import KleothCore

/// The root menu-bar popover content: recording control, live status, cost,
/// and a list of recent meetings.
struct MenuView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationStack {
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

                recentMeetingsSection

                Divider()

                footer
            }
            .padding()
            .frame(width: 340)
            .navigationTitle("Kleoth")
            .onAppear { controller.loadRecentMeetings() }
        }
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
        .buttonStyle(.borderedProminent)
        .tint(controller.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(!controller.consentAcknowledged || controller.isProcessing)

        HStack {
            Text("Session cost")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "$%.4f", controller.currentCostUSD))
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            if controller.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }
            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    // MARK: - Recent meetings

    @ViewBuilder
    private var recentMeetingsSection: some View {
        Text("Recent meetings")
            .font(.subheadline.bold())

        if controller.recentMeetings.isEmpty {
            Text("No meetings yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.recentMeetings) { meeting in
                        NavigationLink {
                            MeetingDetailView(meeting: meeting)
                                .environmentObject(controller)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(.body)
                                HStack {
                                    Text(meeting.date)
                                    Spacer()
                                    Text(String(format: "$%.4f", meeting.costUSD))
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                // An LSUIElement agent must activate itself, or the Settings
                // window opens unfocused behind everything (looks like nothing
                // happened). Activate, then open.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .font(.callout)
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
