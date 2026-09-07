import AVFoundation
import SwiftUI

/// Playback state for one screen recording, owned by `RecordingDetailView` and
/// read by the transcript beside it.
///
/// Thin on purpose: AVKit's `VideoPlayer` draws the movie and its own transport,
/// so this model exists to (a) hand that view an `AVPlayer`, and (b) publish the
/// play head at a rate the transcript can highlight against. Everything is
/// main-actor confined — `AVPlayer` is not `Sendable`, and the periodic observer
/// is registered on `.main` so its callback is already on the main thread.
///
/// Lifetime: `load(_:)` is idempotent per URL, `teardown()` is called from the
/// view's `onDisappear`, and `deinit` carries a belt-and-braces removal (an
/// `AVPlayer` deallocated with a live periodic observer still attached trips an
/// AVFoundation assertion).
@MainActor
final class RecordingPlayerModel: ObservableObject {
    /// The player AVKit renders. Published so the view mounts `VideoPlayer` only
    /// once an item exists.
    @Published private(set) var player: AVPlayer?
    /// Mirrors the player's rate — the user can also press play in AVKit's own
    /// transport, so this is derived from the player, never assumed.
    @Published private(set) var isPlaying = false
    /// Play head in seconds, republished at `tickInterval` while time moves.
    @Published private(set) var currentTime: Double = 0
    /// Movie duration in seconds; seeded from the sidecar when it knows one, then
    /// corrected from the asset as soon as the item reports it.
    @Published private(set) var duration: Double = 0

    /// How often the play head is republished. 0.1 s is well under the shortest
    /// spoken word, so the transcript highlight never visibly lags.
    private static let tickInterval = 0.1

    private var timeObserver: Any?
    private var loadedURL: URL?
    /// A non-isolated mirror of (player, observer) purely so `deinit` — which
    /// cannot touch main-actor state — can still unregister. Kept in lockstep
    /// with `timeObserver`; `teardown()` clears both.
    private nonisolated(unsafe) var observerTeardown: (player: AVPlayer, token: Any)?

    var isLoaded: Bool { player != nil }

    deinit {
        if let observerTeardown {
            observerTeardown.player.removeTimeObserver(observerTeardown.token)
        }
    }

    // MARK: - Loading

    /// Loads `url` (idempotent per URL). `fallbackDuration` is the sidecar's
    /// stored duration, used until the asset reports its own so the scrubber and
    /// the header chip aren't blank on the first frame.
    func load(_ url: URL, fallbackDuration: Double? = nil) {
        guard loadedURL != url else { return }
        teardown()
        loadedURL = url

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Stop at the end rather than freezing on the last frame with rate 0 but
        // `timeControlStatus` still "waiting"; the pause keeps `isPlaying` honest.
        player.actionAtItemEnd = .pause
        self.player = player

        if let fallbackDuration, fallbackDuration.isFinite, fallbackDuration > 0 {
            duration = fallbackDuration
        }
        currentTime = 0
        isPlaying = false

        // `.main` queue → the callback is already on the main thread, so the hop
        // is an assumption, not a `Task` (which would land a frame late and make
        // the highlight stutter). `[weak self]` only: capturing `player` here
        // would close the retain cycle player → observer → player.
        let interval = CMTime(seconds: Self.tickInterval, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
        timeObserver = token
        observerTeardown = (player, token)
    }

    /// Removes the observer, pauses, and drops the player. Safe to call twice.
    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observerTeardown = nil
        player?.pause()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    // MARK: - Transport

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Replay from the top when the head is parked at the end.
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    /// Seeks to `seconds`, exactly — `toleranceBefore/After: .zero` so clicking a
    /// word lands on that word and not on the nearest keyframe (up to 10 s away
    /// with our fragmented 30 fps H.264).
    func seek(to seconds: Double) {
        guard let player else { return }
        let upperBound = duration > 0 ? duration : seconds
        let clamped = max(0, min(seconds, upperBound))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Internals

    /// The periodic observer's body. AVFoundation calls it at `tickInterval`
    /// while time advances *and* whenever playback starts, stops or jumps — which
    /// is why `isPlaying` can be derived here instead of KVO-observing the rate.
    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite {
            currentTime = max(0, seconds)
        }
        guard let player else { return }
        isPlaying = player.rate != 0
        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0,
           abs(itemDuration - duration) > 0.01 {
            duration = itemDuration
        }
    }
}
