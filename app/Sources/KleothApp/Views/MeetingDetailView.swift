import SwiftUI
import AppKit
import KleothCore

/// Detail screen for a single processed meeting: shows the rendered summary +
/// transcript markdown, offers a Copy-for-Slack action, and lets the user
/// rename diarized speakers.
struct MeetingDetailView: View {
    @EnvironmentObject private var controller: RecordingController

    let meeting: RecentMeeting

    @State private var transcript: Transcript?
    @State private var summary: MeetingSummary?
    @State private var metadata: MeetingMetadata?
    @State private var markdown: String = ""
    @State private var loadError: String?
    @State private var showRename = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar

            if let loadError {
                ContentUnavailableViewCompat(
                    title: "Could not load meeting",
                    systemImage: "exclamationmark.triangle",
                    description: loadError
                )
            } else {
                ScrollView {
                    Text(markdown.isEmpty ? "_No content_" : markdown)
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle(meeting.title)
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
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(meeting.title).font(.headline)
                Text(meeting.date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                copyForSlack()
            } label: {
                Label(copied ? "Copied!" : "Copy for Slack", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .disabled(summary == nil)

            Button {
                showRename = true
            } label: {
                Label("Rename speakers", systemImage: "person.2")
            }
            .disabled(transcript == nil || (transcript?.utterances.isEmpty ?? true))
        }
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

/// Minimal stand-in for `ContentUnavailableView` so the view compiles on
/// toolchains where that symbol may be unavailable; renders a centered glyph,
/// title, and description.
private struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
