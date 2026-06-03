import SwiftUI
import AppKit
import KleothCore

/// Detail pane for a single meeting: a metadata + cost header card, the rendered
/// summary + transcript, and toolbar actions (play audio, reveal in Finder, copy
/// for Slack, rename speakers, delete).
struct MeetingDetailView: View {
    @EnvironmentObject private var controller: RecordingController

    let meeting: RecentMeeting

    @State private var transcript: Transcript?
    @State private var summary: MeetingSummary?
    @State private var metadata: MeetingMetadata?
    /// Used only on the rare error path: on-disk `summary.md` shown as plain text
    /// when the structured summary can't be loaded. Empty in the normal case
    /// (the structured `MeetingSummaryView` renders instead).
    @State private var fallbackMarkdown: String = ""
    @State private var loadError: String?
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var confirmFullTranscribe = false
    @State private var copied = false
    /// Whether this meeting has no transcript on disk yet (audio-only). Decided in
    /// `reload()` from the disk, not the (possibly stale) `meeting.isProcessed`
    /// flag, so an in-place transcribe surfaces the result without a relaunch.
    @State private var isUnprocessed = false

    var body: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            headerCard

            if let audio = audioURL {
                MeetingAudioPlayer(url: audio)
            }

            // Live progress while this (already-transcribed) meeting is being
            // upgraded with ElevenLabs Scribe or re-summarized: a determinate bar
            // during the audio upload, indeterminate while Scribe works server-side.
            if controller.isProcessing && !isUnprocessed {
                transcriptionProgressBanner
            }

            if isUnprocessed {
                unprocessedState
            } else if let loadError {
                ContentUnavailableCompat(
                    title: "Could not load meeting",
                    systemImage: "exclamationmark.triangle",
                    message: loadError
                )
            } else if !fallbackMarkdown.isEmpty {
                // Rare error path: the structured summary couldn't be loaded, but a
                // pre-rendered summary.md exists on disk — show it as plain text.
                ScrollView {
                    Text(fallbackMarkdown)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, KleothMetrics.spacingXS)
                }
                .kleothSoftScrollEdge()
            } else {
                ScrollView {
                    MeetingSummaryView(summary: summary, transcript: transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, KleothMetrics.spacingXS)
                }
                .kleothSoftScrollEdge()
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 320)
        .navigationTitle(meeting.title)
        .toolbar { toolbarContent }
        .onAppear(perform: reload)
        // Reload from disk when this meeting's content changes in place (speaker
        // rename, re-transcribe, re-summarize). The detail's view identity is
        // pinned with `.id(meeting.id)`, so `onAppear` fires only once and a pure
        // rename changes no `RecentMeeting` field — without this reactive signal
        // the new names would surface only after the app is relaunched.
        .onChange(of: controller.contentRevision) { _, _ in reload() }
        .sheet(isPresented: $showRename) {
            if let transcript {
                SpeakerRenameView(
                    meetingDir: meeting.directory,
                    transcript: transcript,
                    onSaved: { reload() }
                )
                .environmentObject(controller)
            }
        }
        .confirmationDialog(
            "Move “\(meeting.title)” to the Trash?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { controller.deleteMeeting(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The whole meeting folder — audio, transcript, and summary — goes to the Trash.")
        }
        .confirmationDialog(
            "Fully transcribe with ElevenLabs Scribe?",
            isPresented: $confirmFullTranscribe,
            titleVisibility: .visible
        ) {
            Button(fullTranscribeButtonTitle) { Task { await controller.fullyTranscribe(meeting) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(fullTranscribeMessage)
        }
    }

    // MARK: - Header

    /// Metadata header for the meeting, in a Kleoth content card: the prominent
    /// title and a wrapping row of metadata chips (date · time, duration, model,
    /// color-coded tier badge, and a "No summary yet" hint). Deliberately
    /// money-free — per-meeting costs stay in `meta.json`, and account usage
    /// lives in Settings → Usage.
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            Text(meeting.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            metaChipRow
        }
        .kleothCard()
    }

    /// The wrapping row of metadata chips that sits under the title.
    @ViewBuilder
    private var metaChipRow: some View {
        KleothFlowLayout(spacing: KleothMetrics.spacingS) {
            KleothPill(dateTimeChip, systemImage: "calendar")
            if let duration = MeetingFormat.duration(meeting.durationSecs ?? metadata?.cost?.audioDurationSecs) {
                KleothPill(duration, systemImage: "clock")
            }
            if let model = metadata?.model, !model.isEmpty {
                KleothPill(model, systemImage: "sparkles")
            }
            if let tier = metadata?.transcriptTier {
                KleothTierBadge(isSOTA: TranscriptTier.isSOTA(tier))
            }
            if summary == nil {
                KleothPill("No summary yet", systemImage: "doc.text", tint: KleothPalette.pendingTint)
            }
        }
    }

    /// "May 31, 2026 · 5:26 PM" (or just the date when the start time is unknown).
    private var dateTimeChip: String {
        let dateStr = metadata?.date ?? meeting.date
        if let time = MeetingFormat.time(meeting) {
            return "\(dateStr) · \(time)"
        }
        return dateStr
    }

    /// "Transcribe (~$X)" using the known audio duration, when available.
    private var fullTranscribeButtonTitle: String {
        if let secs = meeting.durationSecs ?? metadata?.cost?.audioDurationSecs, secs > 0 {
            return "Transcribe (~\(MeetingFormat.usd(0.22 * secs / 3600)))"
        }
        return "Transcribe"
    }

    private var fullTranscribeMessage: String {
        "Sends this meeting's audio to ElevenLabs for a higher-accuracy, diarized transcript, then re-summarizes. Replaces the current transcript and incurs ElevenLabs cost (~$0.22 per hour of audio)."
    }

    // MARK: - Transcription progress

    /// Progress banner for an in-flight SOTA transcription / re-summarization:
    /// a determinate bar during the multipart upload (`transcriptionProgress`),
    /// otherwise an indeterminate spinner while Scribe transcribes server-side.
    /// Mirrors the popover's status line so progress reads consistently.
    private var transcriptionProgressBanner: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            HStack(spacing: KleothMetrics.spacingS) {
                if controller.transcriptionProgress == nil {
                    ProgressView().controlSize(.small)
                }
                Text(controller.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            if let progress = controller.transcriptionProgress {
                ProgressView(value: progress)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kleothCard(padding: KleothMetrics.spacingM)
    }

    // MARK: - Unprocessed (audio-only) state

    private var unprocessedState: some View {
        VStack(spacing: KleothMetrics.spacingM) {
            if let image = KleothAssets.illustration(.notTranscribed) {
                KleothIllustration(image: image, size: 120)
            } else {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            Text("Not transcribed yet")
                .font(.headline)
            Text("The audio for this recording is saved, but transcription didn't finish. Transcribe it now — free and on-device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await controller.transcribeSaved(meeting) }
            } label: {
                Label("Transcribe (free, on-device)", systemImage: "sparkles")
                    .padding(.horizontal, KleothMetrics.spacingS)
            }
            .kleothProminentButton()
            .controlSize(.large)
            .disabled(controller.isProcessing)
            if controller.isProcessing {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // Playback is handled by the inline MeetingAudioPlayer; the toolbar
            // keeps the file/share/edit actions. `.help` gives every icon-only
            // button an accessible hint.
            Button { revealInFinder() } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show the meeting folder in Finder")
            Button { copyForSlack() } label: {
                Label(copied ? "Copied!" : "Copy for Slack", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .disabled(summary == nil)
            .help("Copy a Slack-formatted summary to the clipboard")
            Button { showRename = true } label: {
                Label("Rename speakers", systemImage: "person.2")
            }
            .disabled(transcript == nil || (transcript?.utterances.isEmpty ?? true))
            .help("Assign names to the detected speakers")
            if !TranscriptTier.isSOTA(metadata?.transcriptTier) {
                Button { confirmFullTranscribe = true } label: {
                    Label("Fully transcribe", systemImage: "sparkles")
                }
                .disabled(controller.isProcessing || !controller.hasElevenLabsKey)
                .help(controller.hasElevenLabsKey
                      ? "Re-transcribe in the cloud with ElevenLabs Scribe — higher accuracy, diarized."
                      : "Add an ElevenLabs API key in Settings to enable.")
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Move this meeting to the Trash")
        }
    }

    /// The best available audio file co-located with the meeting, if any. Shares
    /// the single lookup in `RecordingController` so the two never diverge.
    private var audioURL: URL? {
        RecordingController.meetingAudioURL(in: meeting.directory)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.directory])
    }

    // MARK: - Loading

    private func reload() {
        copied = false
        metadata = loadMetadata()
        let store = MeetingStore(baseDir: meeting.directory.deletingLastPathComponent())

        // Decide from the disk, not the handed-in `meeting.isProcessed` flag:
        // transcribing an audio-only meeting in place writes transcript.json, and
        // the reactive `contentRevision` reload must reflect that immediately even
        // if the RecentMeeting value we were passed is momentarily stale. No
        // transcript file → genuinely audio-only ("Not transcribed yet").
        let transcriptURL = meeting.directory.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            transcript = nil
            summary = nil
            fallbackMarkdown = ""
            loadError = nil
            isUnprocessed = true
            return
        }

        do {
            // `loadTranscript` applies speakers.json, so utterances already carry
            // You/Them names — the structured view renders them natively.
            transcript = try store.loadTranscript(in: meeting.directory)
            summary = try store.loadSummary(in: meeting.directory)
            fallbackMarkdown = ""
            loadError = nil
            isUnprocessed = false
        } catch {
            // transcript.json exists but couldn't be decoded: fall back to any
            // pre-rendered summary.md (plain text), else surface the error.
            transcript = nil
            summary = nil
            isUnprocessed = false
            if let onDisk = try? String(
                contentsOf: meeting.directory.appendingPathComponent("summary.md"),
                encoding: .utf8
            ) {
                fallbackMarkdown = onDisk
                loadError = nil
            } else {
                fallbackMarkdown = ""
                loadError = error.localizedDescription
            }
        }
    }

    private func loadMetadata() -> MeetingMetadata {
        let url = meeting.directory.appendingPathComponent("meta.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(MeetingMetadata.self, from: data) {
            return decoded
        }
        return MeetingMetadata(title: meeting.title, date: meeting.date)
    }

    // MARK: - Slack

    private func copyForSlack() {
        guard let summary, let metadata else { return }
        let text = SlackRenderer.render(summary: summary, metadata: metadata)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
    }
}