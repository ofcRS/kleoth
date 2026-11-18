import SwiftUI
import AVFoundation

/// A compact, native audio transport for a meeting recording: play/pause, a
/// draggable scrubber, and elapsed / remaining time. Backed by `AVAudioEngine`
/// (no third-party dependencies) so the hard-panned 2-channel `meeting.m4a` is
/// downmixed to mono live — both voices in both ears; progress is driven by a
/// lightweight timer the owning view pumps via `tick()`. Replaces the old
/// "open in QuickTime" toolbar action so a recording can be auditioned inline.
struct MeetingAudioPlayer: View {
    let url: URL
    /// `RecordingController.contentRevision`: on a bump the player reloads its
    /// file IF the one on disk was replaced (the launch repair renames a
    /// rebuilt `meeting.m4a` over it); otherwise nothing, so playback of any
    /// other meeting goes on. A page that mounts later loads the new file in
    /// `onAppear` — `onChange` never fires for the value a view mounts with.
    var revision: Int = 0

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
        .onChange(of: revision) { _, _ in model.reloadIfReplaced() }
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

/// Engine-backed player model exposed as observable state. Main-actor confined;
/// the view pumps `tick()` to publish progress and detect end-of-playback (no
/// delegate needed, which keeps it free of `NSObject`/`Sendable` friction).
///
/// Uses `AVAudioEngine` + `AVAudioPlayerNode` instead of `AVAudioPlayer` so the
/// hard-panned 2-channel `meeting.m4a` (ch0 = mic exclusively left, ch1 = system
/// exclusively right, per `Recorder.combine`) is downmixed to mono **live at
/// playback** — both voices in both ears. The file itself is never re-encoded or
/// re-panned: its discrete L/R layout is load-bearing for `localtranscribe`'s
/// Scribe multichannel recovery.
///
/// Graph: playerNode —(file.processingFormat)→ monoMixer —(1-ch format at the
/// file's sample rate)→ mainMixer → output. The mono hop sums L+R, then the
/// output stage upmixes that mono signal to both speakers. The player→mixer hop
/// MUST stay in the file's own format; forcing mono there is silence or a crash.
/// Legacy mono files (mic.m4a fallback) pass through unchanged — the downmix is
/// the identity for a 1-channel source.
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// True while the user drags the scrubber, so `tick()` doesn't fight the drag.
    var isScrubbing = false

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    /// Intermediate mixer whose mono output connection performs the downmix.
    private var monoMixer: AVAudioMixerNode?
    private var file: AVAudioFile?
    private var loadedURL: URL?
    /// Which file on disk `file` is: a rebuilt `meeting.m4a` renamed over the
    /// old one is a new inode at the same URL.
    private var loadedIdentity: FileIdentity?
    /// Observer for `.AVAudioEngineConfigurationChange` (output-device switches
    /// stop the engine mid-render); removed on teardown.
    private var configObserver: NSObjectProtocol?
    /// Start position (seconds) of the currently scheduled segment. The player
    /// node's `playerTime` restarts at 0 on every `stop()`/reschedule, so the
    /// published `currentTime` is `seekOffset + playerTime`.
    private var seekOffset: Double = 0

    var isLoaded: Bool { file != nil }

    /// Loads `url` once (idempotent per URL and file on disk). Failure leaves
    /// the transport disabled rather than crashing.
    func load(_ url: URL) {
        let identity = FileIdentity(url)
        guard loadedURL != url || loadedIdentity != identity else { return }
        teardown()
        loadedURL = url
        loadedIdentity = identity

        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0,
              let monoFormat = AVAudioFormat(
                  standardFormatWithSampleRate: format.sampleRate,
                  channels: 1
              ) else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: monoFormat)
        engine.prepare()

        self.engine = engine
        self.playerNode = player
        self.monoMixer = mixer
        self.file = file
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
        duration = Double(file.length) / format.sampleRate
        currentTime = 0
        isPlaying = false
        scheduleSegment(from: 0)
    }

    /// Reloads the loaded URL when the file behind it was replaced, keeping the
    /// position (seconds mean the same in the rebuilt file) and playing on if
    /// it was. A stat when nothing changed: no reload, no gap.
    func reloadIfReplaced() {
        guard let url = loadedURL, FileIdentity(url) != loadedIdentity else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        load(url)
        guard isLoaded else { return }
        if position > 0 { seek(to: position) }
        if wasPlaying { toggle() }
    }

    func toggle() {
        guard let engine, let player = playerNode else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if !engine.isRunning {
                guard (try? engine.start()) != nil else { return }
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        guard isLoaded, let player = playerNode else { return }
        // Clamp just short of the end so there is always a (possibly tiny)
        // segment left to schedule — seeking never ends playback; EOF detection
        // stays `tick()`'s job.
        let clamped = max(0, min(time, max(0, duration - 0.05)))
        let wasPlaying = isPlaying
        // stop() clears the scheduled segment (and resets the node's playerTime);
        // a fresh segment from the new position restores the invariant that one
        // segment starting at `seekOffset` is always queued.
        player.stop()
        isPlaying = false

        scheduleSegment(from: clamped)
        currentTime = clamped
        if wasPlaying, let engine {
            if !engine.isRunning {
                guard (try? engine.start()) != nil else { return }
            }
            player.play()
            isPlaying = true
        }
    }

    /// Polls the player node while playing; rewinds to the start at EOF. The
    /// node keeps rendering (silence) after its segment drains, so EOF is
    /// detected by the play head passing `duration`. `lastRenderTime` /
    /// `playerTime` are nil before the first render — keep the last time then.
    func tick() {
        guard let player = playerNode, isPlaying, !isScrubbing else { return }
        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime),
           playerTime.sampleRate > 0 {
            let elapsed = seekOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
            currentTime = min(max(elapsed, 0), duration)
            if elapsed >= duration {
                finishPlayback()
            }
        }
    }

    func stop() {
        teardown()
    }

    // MARK: - Internals

    /// Queues one segment from `seconds` to the end of the file and records it
    /// as the new `seekOffset`. No-op when nothing remains past `seconds`.
    private func scheduleSegment(from seconds: Double) {
        guard let file, let player = playerNode else { return }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((seconds * sampleRate).rounded())
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil
        )
        seekOffset = seconds
    }

    /// An output-device switch (AirPods connect/disconnect, display speakers)
    /// stops the engine and invalidates its connection formats. Rebuild the
    /// graph, reschedule from where playback was, and resume if it was playing —
    /// otherwise the transport freezes with `isPlaying` stuck true.
    private func handleConfigurationChange() {
        guard let engine, let player = playerNode, let mixer = monoMixer, let file else { return }
        let wasPlaying = isPlaying
        let resumeTime = max(0, min(currentTime, max(0, duration - 0.05)))
        player.stop()
        engine.stop()
        isPlaying = false

        let format = file.processingFormat
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: 1
        ) else { return }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(mixer)
        engine.connect(player, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: monoFormat)
        engine.prepare()

        scheduleSegment(from: resumeTime)
        currentTime = resumeTime
        if wasPlaying {
            guard (try? engine.start()) != nil else { return }
            player.play()
            isPlaying = true
        }
    }

    /// EOF: rewind to the start (segment re-queued, ready for the next Play) and
    /// pause the engine so an idle transport doesn't keep the render thread hot.
    private func finishPlayback() {
        playerNode?.stop()
        isPlaying = false
        currentTime = 0
        scheduleSegment(from: 0)
        engine?.pause()
    }

    private func teardown() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        monoMixer = nil
        engine = nil
        file = nil
        loadedURL = nil
        loadedIdentity = nil
        seekOffset = 0
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

/// A file on disk as `stat` names it: device, inode, size and modification
/// time. A file renamed over the old one at the same path differs; reading it
/// costs one `stat`, never a download.
struct FileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    /// nil when there is no file at `url`.
    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}
