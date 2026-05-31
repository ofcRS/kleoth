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
    @State private var markdown: String = ""
    @State private var loadError: String?
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard

            if let loadError {
                ContentUnavailableCompat(
                    title: "Could not load meeting",
                    systemImage: "exclamationmark.triangle",
                    message: loadError
                )
            } else {
                ScrollView {
                    Text(markdown.isEmpty ? "_No content_" : markdown)
                        .font(.system(.body))
                        .textSelection(.enabled)
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
        let store = MeetingStore(baseDir: meeting.directory.deletingLastPathComponent())
        do {
            let loadedTranscript = try store.loadTranscript(in: meeting.directory)
            let loadedSummary = try store.loadSummary(in: meeting.directory)
            let loadedMeta = loadMetadata()

            transcript = loadedTranscript
            summary = loadedSummary
            metadata = loadedMeta
            markdown = MarkdownRenderer.render(
                summary: loadedSummary,
                transcript: loadedTranscript,
                metadata: loadedMeta,
                includeTranscript: true
            )
            loadError = nil
        } catch {
            // Fall back to any pre-rendered summary.md on disk.
            metadata = loadMetadata()
            if let onDisk = try? String(
                contentsOf: meeting.directory.appendingPathComponent("summary.md"),
                encoding: .utf8
            ) {
                markdown = onDisk
                loadError = nil
            } else {
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
