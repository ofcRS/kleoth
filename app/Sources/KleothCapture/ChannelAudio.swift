import Foundation
import AVFoundation
import Accelerate
import KleothCore

/// Audio mixing and energy-envelope helpers for the validated mono-Scribe path.
///
/// The two captured channels (`mic.m4a` = You, `system.m4a` = Them) are mixed to
/// a single mono track for a 1× (correct-duration) Scribe request, while their
/// per-channel energy envelopes drive `ChannelAttribution.assignSpeakers` to
/// label each transcribed word You/Them — Scribe's own diarization is not used.
///
/// All work is pure file IO over float32 PCM, so these helpers are safe to call
/// off the main actor. They mirror the decode-to-mono / chunked-write approach
/// in ``Recorder/combine(channel0:channel1:outputURL:)``.
public enum ChannelAudio {
    /// Errors thrown while mixing or probing channel audio.
    public enum AudioError: Error, Sendable {
        case missingSourceFile(URL)
        case formatUnavailable
        case bufferAllocationFailed
    }

    /// Mixes two sources down to a single peak-normalized mono AAC `.m4a`.
    ///
    /// Each source is decoded to mono float32, **resampled to a single common
    /// rate** (the higher of the two source rates), then summed sample-for-sample
    /// into one mono buffer (zero-padded to the longer source so the two stay
    /// aligned at the file start), peak-normalized to 0.97 when the summed peak
    /// exceeds it, and written as a 1-channel AAC file at that common rate. At
    /// least one source must exist. This is the file uploaded to Scribe (1× cost,
    /// correct duration). Returns `outputURL`.
    ///
    /// The common-rate step matters because the two channels are captured at
    /// independent clocks — `MicCapture` at the mic node's native rate,
    /// `SystemAudioTap` at the tap's native rate — which can differ (e.g. a
    /// 44.1 kHz Bluetooth mic vs a 48 kHz system tap). Summing per-sample without
    /// reconciling the rates would time-warp the slower/faster channel and make
    /// the mono file's duration (frames ÷ rate) wrong for it, corrupting both the
    /// duration Scribe/`AudioProbe` read and the word timestamps speaker
    /// attribution relies on. In practice both often resolve to 48 kHz.
    @discardableResult
    public static func mixToMono(channel0: URL, channel1: URL, outputURL: URL) throws -> URL {
        var mono0 = try decodeToMono(channel0)
        var mono1 = try decodeToMono(channel1)

        guard mono0 != nil || mono1 != nil else {
            throw AudioError.missingSourceFile(channel0)
        }

        // Reconcile the two independently-clocked channels onto one common rate
        // (the higher of the two, so the faster channel is never downsampled)
        // before summing sample-for-sample, then write the mono file at that rate.
        let maxRate = max(mono0?.format.sampleRate ?? 0, mono1?.format.sampleRate ?? 0)
        let targetRate = maxRate > 0 ? maxRate : AudioFormat.defaultSampleRate
        mono0 = try resample(mono0, toSampleRate: targetRate)
        mono1 = try resample(mono1, toSampleRate: targetRate)

        let frames0 = mono0?.frameLength ?? 0
        let frames1 = mono1?.frameLength ?? 0
        let totalFrames = max(frames0, frames1)

        // Sum both channels into a single mono buffer, tracking the peak so we can
        // normalize if mixing pushed the signal past full scale.
        guard let monoFormat = AudioFormat.pcmFloat32(sampleRate: targetRate, channels: 1) else {
            throw AudioError.formatUnavailable
        }
        let settings = AudioFormat.aacSettings(sampleRate: targetRate, channels: 1)
        let outFile = try AVAudioFile(forWriting: outputURL, settings: settings)
        if totalFrames == 0 { return outputURL }

        guard let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: totalFrames),
              let mix = mixed.floatChannelData else {
            throw AudioError.bufferAllocationFailed
        }
        mixed.frameLength = totalFrames
        memset(mix[0], 0, Int(totalFrames) * MemoryLayout<Float>.size)

        var peak: Float = 0
        addChannel(mono0, into: mix[0], frames: totalFrames, peak: &peak)
        addChannel(mono1, into: mix[0], frames: totalFrames, peak: &peak)

        // Peak-normalize to 0.97 if the summed signal clipped.
        if peak > 0.97 {
            var gain = Float(0.97) / peak
            vDSP_vsmul(mix[0], 1, &gain, mix[0], 1, vDSP_Length(totalFrames))
        }

        // Write in capped chunks so the encoder never sees an unbounded buffer.
        let chunk: AVAudioFrameCount = 16384
        var offset: AVAudioFrameCount = 0
        while offset < totalFrames {
            let thisChunk = min(chunk, totalFrames - offset)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: thisChunk),
                  let out = outBuffer.floatChannelData else {
                throw AudioError.bufferAllocationFailed
            }
            outBuffer.frameLength = thisChunk
            out[0].update(from: mix[0].advanced(by: Int(offset)), count: Int(thisChunk))
            try outFile.write(from: outBuffer)
            offset += thisChunk
        }

        return outputURL
    }

    /// Returns a per-hop RMS energy envelope of an audio file (one `Float` per
    /// window of `round(hopSeconds * sampleRate)` samples), decoded to mono.
    ///
    /// These envelopes feed `ChannelAttribution.assignSpeakers`, which compares
    /// channel 0 (mic) vs channel 1 (system) energy over each word's time span.
    /// An empty or unreadable file yields an empty envelope.
    public static func envelope(of url: URL, hopSeconds: Double) throws -> [Float] {
        guard let mono = try decodeToMono(url), let data = mono.floatChannelData else {
            return []
        }
        let total = Int(mono.frameLength)
        let sampleRate = mono.format.sampleRate
        let hop = max(1, Int((hopSeconds * sampleRate).rounded()))
        guard total > 0, hop > 0 else { return [] }

        let samples = data[0]
        var envelope: [Float] = []
        envelope.reserveCapacity(total / hop + 1)
        var start = 0
        while start < total {
            let count = min(hop, total - start)
            var meanSquare: Float = 0
            vDSP_measqv(samples.advanced(by: start), 1, &meanSquare, vDSP_Length(count))
            envelope.append(meanSquare > 0 ? sqrt(meanSquare) : 0)
            start += hop
        }
        return envelope
    }

    // MARK: - Helpers

    /// Adds `source`'s mono samples into `destination` (sized `frames`), updating
    /// `peak` with the running absolute maximum. Frames past the source's end are
    /// left untouched (the destination is pre-zeroed).
    private static func addChannel(
        _ source: AVAudioPCMBuffer?,
        into destination: UnsafeMutablePointer<Float>,
        frames: AVAudioFrameCount,
        peak: inout Float
    ) {
        guard let source, let src = source.floatChannelData else { return }
        let count = Int(min(frames, source.frameLength))
        guard count > 0 else { return }
        vDSP_vadd(destination, 1, src[0], 1, destination, 1, vDSP_Length(count))
        var localPeak: Float = 0
        vDSP_maxmgv(destination, 1, &localPeak, vDSP_Length(count))
        peak = max(peak, localPeak)
    }

    /// Returns `buffer` resampled to `toSampleRate` (mono float32), or `buffer`
    /// unchanged when it is already at that rate (or is `nil`). Used to put the
    /// two independently-clocked channels on a common timebase before they are
    /// summed sample-for-sample in `mixToMono`.
    ///
    /// Sample-rate conversion changes the frame count, so this uses
    /// `AVAudioConverter`'s pull-based form (the one-shot `convert(to:from:)`
    /// throws for sample-rate conversion). The whole input buffer is already in
    /// memory, so it is supplied in a single pull and `.endOfStream` thereafter.
    private static func resample(
        _ buffer: AVAudioPCMBuffer?,
        toSampleRate target: Double
    ) throws -> AVAudioPCMBuffer? {
        guard let buffer else { return nil }
        let sourceFormat = buffer.format
        // Float comparison is exact here: both rates come from concrete audio
        // formats, and equal rates should skip conversion entirely.
        if sourceFormat.sampleRate == target { return buffer }

        guard let targetFormat = AudioFormat.pcmFloat32(sampleRate: target, channels: 1),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioError.formatUnavailable
        }

        // Output frame count scales with the rate ratio; round up and add a small
        // margin so the resampler is never starved of output capacity.
        let ratio = target / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioError.bufferAllocationFailed
        }

        // The converter's input block is typed `@Sendable`, so the "already
        // supplied" state is held in a box rather than a captured `var`. The
        // block is in fact pulled synchronously on this thread (no real
        // concurrency), and the whole buffer is handed over in one pull.
        let pending = ConsumableBuffer(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let next = pending.take() else {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        if let conversionError { throw conversionError }
        guard status != .error else { throw AudioError.formatUnavailable }
        return output
    }

    /// A one-shot holder for the single input buffer handed to an
    /// `AVAudioConverter` pull block: ``take()`` returns the buffer on the first
    /// call and `nil` after. `@unchecked Sendable` is sound because the block
    /// that drains it is pulled synchronously on a single thread during one
    /// `convert(to:error:withInputFrom:)` call.
    private final class ConsumableBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    /// Reads the whole file and converts it to a single mono float32 buffer, or
    /// returns `nil` if the file does not exist. Mirrors the shared decode-to-mono
    /// step used when combining channels.
    private static func decodeToMono(_ url: URL) throws -> AVAudioPCMBuffer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        if frameCount == 0 { return nil }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw AudioError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer)

        // Already mono float32? Use as-is.
        if sourceFormat.channelCount == 1, sourceFormat.commonFormat == .pcmFormatFloat32 {
            return sourceBuffer
        }

        guard let monoFormat = AudioFormat.pcmFloat32(sampleRate: sourceFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: sourceFormat, to: monoFormat) else {
            throw AudioError.formatUnavailable
        }
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: sourceBuffer.frameLength) else {
            throw AudioError.bufferAllocationFailed
        }
        // Same sample rate, so the one-shot converter consumes the whole buffer.
        try converter.convert(to: monoBuffer, from: sourceBuffer)
        return monoBuffer
    }
}
