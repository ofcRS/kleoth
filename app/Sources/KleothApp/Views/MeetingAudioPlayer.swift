import SwiftUI
import AVFoundation

/// A compact, native audio transport for a meeting recording: play/pause, a
/// draggable scrubber, and elapsed / remaining time. Backed by `AVAudioPlayer`
/// (no third-party dependencies); progress is driven by a lightweight timer the
/// owning view pumps via `tick()`. Replaces the old "open in QuickTime" toolbar
/// action so a recording can be auditioned inline.
struct MeetingAudioPlayer: View {
    let url: URL

    @StateObject private var model = AudioPlayerModel()
    /// Pumps `currentTime` while playing. Fires on the main run loop; cheap.
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: KleothMetrics.spacingM) {
            Button(action: model.toggle) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.isLoaded)
            .help(model.isPlaying ? "Pause" : "Play the meeting audio")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Text(Self.time(model.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)

            Slider(
                value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                in: 0...max(model.duration, 0.01),
                onEditingChanged: { model.isScrubbing = $0 }
            )
            .controlSize(.small)
            .disabled(!model.isLoaded)
            .accessibilityLabel("Playback position")

            Text("-" + Self.time(max(model.duration - model.currentTime, 0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .kleothCard(padding: KleothMetrics.spacingS)
        .onAppear { model.load(url) }
        .onDisappear { model.stop() }
        .onChange(of: url) { _, newURL in model.load(newURL) }
        .onReceive(ticker) { _ in model.tick() }
    }

    /// Formats seconds as `m:ss` (or `h:mm:ss` for long recordings).
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Thin `AVAudioPlayer` wrapper exposed as observable state. Main-actor confined;
/// the view pumps `tick()` to publish progress and detect end-of-playback (no
/// delegate needed, which keeps it free of `NSObject`/`Sendable` friction).
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// True while the user drags the scrubber, so `tick()` doesn't fight the drag.
    var isScrubbing = false

    private var player: AVAudioPlayer?
    private var loadedURL: URL?

    var isLoaded: Bool { player != nil }

    /// Loads `url` once (idempotent per URL). Failure leaves the transport
    /// disabled rather than crashing.
    func load(_ url: URL) {
        guard loadedURL != url else { return }
        player?.stop()
        let next = try? AVAudioPlayer(contentsOf: url)
        next?.prepareToPlay()
        player = next
        loadedURL = url
        duration = next?.duration ?? 0
        currentTime = 0
        isPlaying = false
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Polls the player while playing; resets to the start when playback ends.
    func tick() {
        guard let player, isPlaying, !isScrubbing else { return }
        if player.isPlaying {
            currentTime = player.currentTime
        } else {
            // Reached the end: rewind so the next Play starts over.
            isPlaying = false
            currentTime = 0
            player.currentTime = 0
        }
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
    }
}
