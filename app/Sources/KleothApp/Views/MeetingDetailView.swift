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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard

            if !meeting.isProcessed {
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
                        .font(.system(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .kleothSoftScrollEdge()
            } else {
                ScrollView {
                    MeetingSummaryView(summary: summary, transcript: transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .kleothSoftScrollEdge()
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 380)
        .navigationTitle(meeting.title)
        .toolbar { toolbarContent }
        .onAppear(perform: reload)
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(metaChips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let cost = metadata?.cost {
                HStack(spacing: 16) {
                    costItem("Total", cost.totalUSD)
                    costItem("Transcription", cost.transcriptionUSD)
                    if cost.summaryUSD > 0 { costItem("Summary", cost.summaryUSD) }
                    Spacer()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var metaChips: [String] {
        var chips: [String] = []
        let dateStr = metadata?.date ?? meeting.date
        if let time = MeetingFormat.time(meeting) {
            chips.append("\(dateStr) · \(time)")
        } else {
            chips.append(dateStr)
        }
        if let duration = MeetingFormat.duration(meeting.durationSecs ?? metadata?.cost?.audioDurationSecs) {
            chips.append(duration)
        }
        if let model = metadata?.model, !model.isEmpty {
            chips.append(model)
        }
        if let tier = metadata?.transcriptTier {
            chips.append(TranscriptTier.isSOTA(tier) ? "SOTA · diarized" : "Local · free")
        }
        if summary == nil {
            chips.append("no summary yet")
        }
        return chips
    }

    private func costItem(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(MeetingFormat.usd(value)).font(.caption.monospacedDigit())
        }
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

    // MARK: - Unprocessed (audio-only) state

    private var unprocessedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
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
                    .padding(.horizontal, 6)
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
            if let audio = audioURL {
                Button { NSWorkspace.shared.open(audio) } label: {
                    Label("Play audio", systemImage: "play.circle")
                }
            }
            Button { revealInFinder() } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button { copyForSlack() } label: {
                Label(copied ? "Copied!" : "Copy for Slack", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .disabled(summary == nil)
            Button { showRename = true } label: {
                Label("Rename speakers", systemImage: "person.2")
            }
            .disabled(transcript == nil || (transcript?.utterances.isEmpty ?? true))
            if !TranscriptTier.isSOTA(metadata?.transcriptTier) {
                Button { confirmFullTranscribe = true } label: {
                    Label("Fully transcribe", systemImage: "sparkles")
                }
                .disabled(controller.isProcessing || !controller.hasElevenLabsKey)
                .help(controller.hasElevenLabsKey
                      ? "Re-transcribe with ElevenLabs Scribe (SOTA, diarized)."
                      : "Add an ElevenLabs API key in Settings to enable.")
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The best available audio file co-located with the meeting, if any.
    private var audioURL: URL? {
        let fm = FileManager.default
        for name in ["meeting.m4a", "combined.m4a", "mic.m4a", "system.m4a"] {
            let url = meeting.directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.directory])
    }

    // MARK: - Loading

    private func reload() {
        copied = false
        guard meeting.isProcessed else {
            // Audio-only recording (processing didn't finish): nothing to load.
            metadata = loadMetadata()
            transcript = nil
            summary = nil
            fallbackMarkdown = ""
            loadError = nil
            return
        }
        let store = MeetingStore(baseDir: meeting.directory.deletingLastPathComponent())
        do {
            // `loadTranscript` applies speakers.json, so utterances already carry
            // You/Them names — the structured view renders them natively.
            transcript = try store.loadTranscript(in: meeting.directory)
            summary = try store.loadSummary(in: meeting.directory)
            metadata = loadMetadata()
            fallbackMarkdown = ""
            loadError = nil
        } catch {
            // Fall back to any pre-rendered summary.md on disk (plain text).
            metadata = loadMetadata()
            transcript = nil
            summary = nil
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
