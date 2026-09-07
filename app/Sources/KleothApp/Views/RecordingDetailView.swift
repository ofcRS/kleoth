import KleothCore
import SwiftUI

/// The Recordings viewer: the movie with its transcript beside it. The current
/// word highlights during playback, a click on a word seeks there, a
/// double-click edits it in place. The view owns playback only; every
/// persistent change goes out through the callbacks so the library stays the
/// single writer of the sidecar.
///
/// Contract stub — lane L5 builds the real view. Lane L4 mounts it from the
/// Recordings list with these exact parameters.
struct RecordingDetailView: View {
    let item: ScreenRecordingItem
    /// The user edited one word (or the title). The caller persists the record
    /// and republishes `item`.
    let onSaveRecord: (ScreenRecordingRecord) -> Void
    /// "Transcribe on device" / "Transcribe in cloud" (`TranscriptTier.local` /
    /// `.sotaScribe`).
    let onTranscribe: (String) -> Void
    /// True while a transcription job for this recording is queued or running.
    let isTranscribing: Bool
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        VStack(spacing: KleothMetrics.spacingM) {
            Text(item.displayTitle).font(.title3)
            Text("Viewer not built yet.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
