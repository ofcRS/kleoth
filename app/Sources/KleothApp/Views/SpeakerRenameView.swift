import SwiftUI
import KleothCore

/// Sheet for assigning human-readable names to diarized speakers.
///
/// For each speaker id it shows representative sample utterances (from
/// `SpeakerMapper.samples`) and a text field; Save builds a `SpeakerMap` and
/// hands it to the controller, which re-renders and persists the meeting.
struct SpeakerRenameView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.dismiss) private var dismiss

    let meetingDir: URL
    let transcript: Transcript
    /// Invoked after a successful save so the parent can refresh.
    var onSaved: () -> Void = {}

    /// Speaker ids in order of first appearance.
    @State private var speakerIds: [String] = []
    /// Sample utterances per speaker id.
    @State private var samples: [String: [String]] = [:]
    /// Editable name per speaker id.
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename speakers")
                .font(.headline)

            if speakerIds.isEmpty {
                Text("No speakers were detected in this transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(speakerIds, id: \.self) { speakerId in
                            speakerRow(speakerId)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(speakerIds.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear(perform: load)
    }

    // MARK: - Rows

    private func speakerRow(_ speakerId: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                speakerId,
                text: Binding(
                    get: { names[speakerId] ?? "" },
                    set: { names[speakerId] = $0 }
                ),
                prompt: Text("Name for \(speakerId)")
            )
            .textFieldStyle(.roundedBorder)

            ForEach(Array((samples[speakerId] ?? []).enumerated()), id: \.offset) { _, sample in
                Text("“\(sample)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        // Preserve first-appearance order for the ids.
        var seen = Set<String>()
        var ordered: [String] = []
        for utterance in transcript.utterances where !seen.contains(utterance.speakerId) {
            seen.insert(utterance.speakerId)
            ordered.append(utterance.speakerId)
        }
        speakerIds = ordered
        samples = SpeakerMapper.samples(from: transcript, perSpeaker: 3)

        // Seed any names already present on the transcript.
        var seeded: [String: String] = [:]
        for utterance in transcript.utterances {
            if let name = utterance.speakerName, !name.isEmpty {
                seeded[utterance.speakerId] = name
            }
        }
        names = seeded
    }

    private func save() {
        var mapped: [String: String] = [:]
        for (speakerId, rawName) in names {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                mapped[speakerId] = trimmed
            }
        }
        controller.rename(meetingDir: meetingDir, map: SpeakerMap(names: mapped))
        onSaved()
        dismiss()
    }
}
