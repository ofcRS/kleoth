import SwiftUI
import AppKit
import KleothCore

/// The menu-bar popover: a lean control surface — record, live status, session
/// cost, and the few most recent meetings. Full browsing lives in the History
/// window (opened from here), not in this cramped popover.
///
/// Visual direction is the shared "refined native macOS 26 Tahoe" system: the
/// record button is the single Liquid Glass hero (`kleothProminentButton`),
/// everything else sits on system materials and pulls spacing, color, and
/// building blocks from `KleothTheme` so the popover reads as one product with
/// the History/Detail windows.
struct MenuView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// How many recent meetings the popover surfaces before "Show all …".
    private let recentLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingL) {
            header

            if !controller.consentAcknowledged {
                ConsentView()
                    .environmentObject(controller)
            }

            recordControl

            recentSection

            footer
        }
        .padding(KleothMetrics.spacingL)
        .frame(width: 340)
        .onAppear { controller.loadRecentMeetings() }
    }

    // MARK: - Header

    /// App mark + wordmark with a one-line state subtitle, and the animated
    /// recording indicator pinned to the trailing edge while capturing.
    private var header: some View {
        HStack(spacing: KleothMetrics.spacingM) {
            appMark
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Kleoth")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: KleothMetrics.spacingS)

            if controller.isRecording {
                RecordingIndicator()
            }
        }
    }

    /// The Kleoth lyre brand mark for the popover header — the same identity as
    /// the Dock/Finder icon. Falls back to a tinted waveform tile if the bundled
    /// mark can't be loaded, so the header never renders empty.
    @ViewBuilder
    private var appMark: some View {
        if let mark = KleothAssets.appMark() {
            Image(nsImage: mark)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    /// One quiet line under the wordmark reflecting the current state.
    private var headerSubtitle: String {
        if controller.isRecording { return "Recording in progress" }
        return "Local-first meeting recorder"
    }

    // MARK: - Record control

    /// The hero record button (the single glass element), the session-cost line,
    /// and the transient status / model-download lines, grouped on one card so
    /// the popover's primary action reads as a distinct block.
    @ViewBuilder
    private var recordControl: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
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
            .tint(controller.isRecording ? KleothPalette.recordingTint : .accentColor)
            .controlSize(.large)
            .disabled(!controller.consentAcknowledged || controller.isProcessing)

            sessionCostLine

            statusLine

            if let progress = controller.modelDownloadProgress {
                modelDownloadLine(progress)
            }
        }
        .kleothCard(padding: KleothMetrics.spacingM)
    }

    /// "Session cost" with a monospaced-digit total, styled like a compact stat
    /// row so it aligns with the cost language used elsewhere.
    private var sessionCostLine: some View {
        HStack {
            Label("Session cost", systemImage: "dollarsign.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Spacer()
            Text(MeetingFormat.usd(controller.currentCostUSD))
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Status

    /// Transient status text; shows a small spinner while the pipeline runs.
    /// Hidden when there's nothing meaningful to say (idle, no download).
    @ViewBuilder
    private var statusLine: some View {
        if controller.isProcessing || !isIdleStatus {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
                HStack(spacing: KleothMetrics.spacingS) {
                    // Indeterminate spinner only when there's no determinate
                    // upload progress to show (the bar below covers uploading).
                    if controller.isProcessing && controller.transcriptionProgress == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(controller.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                if let progress = controller.transcriptionProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Whether the status message is just the resting "Idle" placeholder, so we
    /// can suppress an otherwise-empty status row.
    private var isIdleStatus: Bool {
        controller.statusMessage.trimmingCharacters(in: .whitespaces).lowercased() == "idle"
    }

    /// First-run / background model download progress — a determinate bar plus a
    /// quiet percentage caption.
    private func modelDownloadLine(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            ProgressView(value: progress)
                .controlSize(.small)
            Text("Downloading transcription model… \(Int(progress * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Recent meetings (quick links into the History window)

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
            KleothSectionHeader("Recent meetings", systemImage: "clock.arrow.circlepath")

            if controller.recentMeetings.isEmpty {
                Text("No meetings yet. Record a call, or run `kleoth transcribe` — they show up here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kleothCard(padding: KleothMetrics.spacingM)
            } else {
                VStack(spacing: 0) {
                    let shown = Array(controller.recentMeetings.prefix(recentLimit))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, meeting in
                        Button { openHistory(select: meeting.id) } label: {
                            RecentMeetingRow(meeting: meeting)
                        }
                        .buttonStyle(.plain)

                        if index < shown.count - 1 {
                            Divider().padding(.leading, KleothMetrics.spacingM)
                        }
                    }
                }
                .kleothCard(padding: KleothMetrics.spacingXS)

                if controller.recentMeetings.count > recentLimit {
                    Button("Show all \(controller.recentMeetings.count) meetings…") {
                        openHistory(select: nil)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .padding(.leading, KleothMetrics.spacingXS)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: KleothMetrics.spacingM) {
            Button {
                openHistory(select: nil)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Open the History window to browse all meetings")

            Spacer(minLength: 0)

            Button {
                // LSUIElement agents must activate before opening a window/panel.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .help("Open Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit Kleoth")
        }
        .font(.callout)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func openHistory(select id: RecentMeeting.ID?) {
        controller.selectedMeetingID = id
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "kleoth-history")
    }
}

// MARK: - Recent meeting row

/// One tappable row in the popover's recent list: a speaker-style status dot, the
/// title, a secondary time · duration line, and a trailing tier badge / cost (or
/// an "Untranscribed" chip). Highlights on hover so it reads as actionable, and
/// matches the History sidebar's badge/cost language.
private struct RecentMeetingRow: View {
    let meeting: RecentMeeting
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: KleothMetrics.spacingM) {
            // A small status dot: accent for processed meetings, orange for
            // audio-only folders still awaiting transcription.
            Circle()
                .fill(meeting.isProcessed ? Color.accentColor : KleothPalette.pendingTint)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: KleothMetrics.spacingS)

            trailing
        }
        .padding(.vertical, KleothMetrics.spacingS)
        .padding(.horizontal, KleothMetrics.spacingS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusChip, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .onHover { isHovering = $0 }
    }

    /// "5:26 PM · 12m 03s" — falls back to the day when no clock time is known.
    private var subtitle: String {
        var parts: [String] = []
        if let time = MeetingFormat.time(meeting) {
            parts.append(time)
        } else {
            parts.append(meeting.date)
        }
        if let duration = MeetingFormat.duration(meeting.durationSecs) {
            parts.append(duration)
        }
        return parts.joined(separator: " · ")
    }

    /// Trailing accessory: a tier badge for SOTA meetings then the cost, or an
    /// "Untranscribed" chip for audio-only folders.
    @ViewBuilder
    private var trailing: some View {
        if !meeting.isProcessed {
            KleothPill("Untranscribed", tint: KleothPalette.pendingTint)
        } else {
            HStack(spacing: KleothMetrics.spacingS) {
                if TranscriptTier.isSOTA(meeting.transcriptTier) {
                    KleothTierBadge(isSOTA: true)
                }
                Text(MeetingFormat.usd(meeting.costUSD))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recording indicator

/// A small animated red dot + "Recording" label. The pulse respects Reduce
/// Motion: when motion is reduced it stays a steady, fully-opaque dot.
private struct RecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: KleothMetrics.spacingXS) {
            Circle()
                .fill(KleothPalette.recordingTint)
                .frame(width: 8, height: 8)
                .opacity(reduceMotion ? 1.0 : (pulsing ? 0.3 : 1.0))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulsing
                )
            Text("Recording")
                .font(.caption2.weight(.medium))
                .foregroundStyle(KleothPalette.recordingTint)
        }
        .onAppear { pulsing = true }
    }
}
