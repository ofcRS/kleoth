import Accelerate
import Foundation

/// A lock-free, single-word `Float` slot holding the most recent RMS level
/// measured on a screen recording's audio lane.
///
/// The heap word lets a `@Sendable` capture callback — the mic tap on the
/// render thread, the ScreenCaptureKit `.audio` output on the audio queue —
/// store into it without boxing, allocating or blocking. It is read at ~20 Hz
/// by the `@MainActor` pill poll through ``ScreenRecorder/levels``
/// **while those threads are storing into it**: there is no synchronization
/// edge, so this is a **deliberate, benign data race**, not a synchronized
/// read. It is tolerated because a naturally-aligned 32-bit store does not
/// tear on arm64/x86_64 and a stale or momentarily odd meter value is
/// inconsequential — but a ThreadSanitizer build WILL report it. The proper
/// fix is a relaxed atomic (`Atomic<UInt32>` + `bitPattern`, macOS 15+, or a
/// stdatomic shim) once the package floor allows it.
///
/// This is a deliberate copy of ``RenderLevel`` (`AudioFormat.swift`) rather
/// than a reuse: that word belongs to the dictation capture session and is
/// reset by its lifecycle, and the two must never share a slot when a
/// dictation runs *inside* a screen recording (which is the supported case).
final class LevelWord: @unchecked Sendable {
    private let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init() {
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    /// Drops the meter to silence. Called from the control thread when the lane
    /// stops or gives up, so a dead lane never leaves a frozen bar on the pill.
    func reset() {
        pointer.pointee = 0
    }

    /// Stores the latest RMS. Real-time safe (single non-blocking store).
    func store(_ rms: Float) {
        pointer.pointee = rms
    }

    /// Measures and stores the RMS of `count` interleaved Float32 samples.
    /// Real-time safe: `vDSP_measqv` allocates nothing.
    ///
    /// `vDSP_measqv` returns the MEAN of squares, so `sqrt` of it IS the RMS —
    /// no divide-by-N is missing (see CLAUDE.md; `vDSP_svesq` is the
    /// sum-of-squares one).
    func storeRMS(of samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(count))
        pointer.pointee = meanSquare > 0 ? sqrt(meanSquare) : 0
    }

    /// The most recently stored RMS.
    var value: Float {
        pointer.pointee
    }

    /// The most recently stored RMS as the `0…1` linear level `AudioLevels`
    /// carries. Clamped: a hot mic can push a converted block past full scale.
    var level: Double {
        Double(min(max(pointer.pointee, 0), 1))
    }
}
