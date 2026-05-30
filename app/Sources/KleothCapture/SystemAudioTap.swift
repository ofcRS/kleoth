import Foundation
import AVFoundation
import CoreAudio
import os

/// Errors thrown by ``SystemAudioTap`` when the Core Audio process-tap flow
/// fails. Each case carries the originating `OSStatus` where applicable.
public enum SystemAudioTapError: Error, Sendable {
    case createProcessTapFailed(OSStatus)
    case readTapUIDFailed(OSStatus)
    case readTapFormatFailed(OSStatus)
    case invalidTapFormat
    case createAggregateDeviceFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startFailed(OSStatus)
}

/// Captures system audio using a Core Audio process tap that feeds a private
/// aggregate device, with an `IOProc` delivering buffers each render cycle.
///
/// The tap excludes the current process and mixes every *other* process down to
/// a stereo stream, so the host app's own playback is not captured. The tap's
/// real stream format is read from the kernel (never assumed to be 48 kHz /
/// stereo) and used to construct the `AVAudioFile` writer and the per-cycle
/// `AVAudioPCMBuffer`.
///
/// Teardown in ``stop()`` is idempotent and ordered:
/// `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
/// `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
///
/// Requires macOS 14.4+. Live capture additionally requires a signed app bundle
/// and the audio-capture TCC grant; this type compiles without them but the
/// call to ``start(writingTo:)`` / ``start(handler:)`` will fail at runtime when
/// the entitlement or permission is missing.
@available(macOS 14.4, *)
public final class SystemAudioTap {
    /// Receives one `AVAudioPCMBuffer` per IO cycle. Marked `@Sendable` because
    /// it is invoked on the Core Audio IO thread.
    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    /// The tap's stream format, resolved on `start`. Retained so callers (e.g.
    /// `Recorder`) can match writer formats and so the IO thread can wrap each
    /// buffer list without recomputing.
    private var streamFormat: AVAudioFormat?

    /// Dedicated serial queue for the IO block (Core Audio dispatches the block
    /// here). Created once; never mutated.
    private let ioQueue = DispatchQueue(label: "com.kleoth.systemaudiotap.io", qos: .userInteractive)

    /// Diagnostics: logs Core Audio setup + IO-thread activity to the unified
    /// log (subsystem `dev.kleoth`) so an empty capture can be pinpointed.
    private let log = Logger(subsystem: "dev.kleoth", category: "SystemAudioTap")
    private let ioStats = OSAllocatedUnfairLock<(cycles: Int, nilBuffers: Int, frames: Int64)>(initialState: (0, 0, 0))

    public init() {}

    /// Starts the process tap and writes captured system audio to a freshly
    /// created file at `outputURL`.
    ///
    /// - Note: requires signed bundle + TCC grant at runtime.
    public func start(writingTo outputURL: URL) throws {
        try start { resolvedFormat in
            // Build the writer using the resolved tap format.
            guard let format = resolvedFormat else { return nil }
            let settings = AudioFormat.aacSettings(
                sampleRate: format.sampleRate,
                channels: Int(format.channelCount)
            )
            // Match the file's processing format to the tap's buffers
            // (interleaved float32). The default AVAudioFile(forWriting:settings:)
            // uses a DEINTERLEAVED processing format, so writing the tap's
            // interleaved buffers throws on every cycle — which is exactly why
            // system.m4a came out empty (writeFailed=true in the diagnostics).
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            // Write-only @Sendable handler; AVAudioFile.write is the only work.
            let fileBox = SendableAudioFileBox(file)
            let failed = self.writeFailed
            return { @Sendable buffer in
                do {
                    try fileBox.file.write(from: buffer)
                } catch {
                    failed.raise()
                }
            }
        }
    }

    /// Starts the process tap and forwards each cycle's buffer to `handler`.
    ///
    /// - Note: requires signed bundle + TCC grant at runtime.
    public func start(handler: @escaping BufferHandler) throws {
        try start { _ in handler }
    }

    /// `true` if a file-backed session reported a write failure on the IO thread.
    public var didEncounterWriteFailure: Bool { writeFailed.isRaised }

    /// The resolved tap stream format from the last `start`, if available.
    public var resolvedFormat: AVAudioFormat? { streamFormat }

    // MARK: - Core flow

    /// Shared start path. `makeHandler` is given the resolved tap `AVAudioFormat`
    /// and returns the buffer handler to install (or `nil` to abort silently);
    /// it may throw when opening a writer.
    private func start(makeHandler: (AVAudioFormat?) throws -> BufferHandler?) throws {
        guard !isRunning else { return }
        writeFailed.reset()

        // 1. Build the tap description: exclude *this* process, stereo mixdown of
        //    all others, private (no system-wide visibility), unmuted so the user
        //    still hears audio while it is captured. The init takes Core Audio
        //    process *object* IDs, so translate our pid first; if translation
        //    fails we fall back to a global stereo mixdown (which would include
        //    our own output) rather than failing the whole capture.
        let excluded = Self.audioProcessObjects(forPID: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excluded
        )
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Kleoth System Audio Tap"

        // 2. Create the process tap.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw SystemAudioTapError.createProcessTapFailed(tapStatus)
        }
        tapID = newTapID

        // From here, any failure must tear the tap back down.
        do {
            // 3. Read the tap's UID (needed to reference it from the aggregate).
            let tapUID = try readTapUID(tapID)

            // 4. Read the tap's real stream format. Do NOT assume 48k/stereo.
            let asbd = try readTapStreamFormat(tapID)
            var mutableASBD = asbd
            guard let format = AVAudioFormat(streamDescription: &mutableASBD) else {
                throw SystemAudioTapError.invalidTapFormat
            }
            streamFormat = format
            ioStats.withLock { $0 = (0, 0, 0) }
            log.info("tap format sr=\(asbd.mSampleRate, privacy: .public) ch=\(asbd.mChannelsPerFrame, privacy: .public) flags=\(asbd.mFormatFlags, privacy: .public) bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public) framesPerPacket=\(asbd.mFramesPerPacket, privacy: .public) interleaved=\(format.isInterleaved, privacy: .public)")

            // 5. Create a private aggregate device that contains only the tap.
            let aggregateUID = "com.kleoth.systemaudiotap.\(UUID().uuidString)"
            let aggDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Kleoth Aggregate",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            var newAggID = AudioObjectID(kAudioObjectUnknown)
            let aggStatus = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAggID)
            guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
                throw SystemAudioTapError.createAggregateDeviceFailed(aggStatus)
            }
            aggregateID = newAggID

            // 6. Resolve the handler (this is also where a file writer opens).
            guard let handler = try makeHandler(format) else {
                // Nothing to deliver to; tear down cleanly.
                stop()
                return
            }

            // 7. Install the IOProc. The block runs on the Core Audio IO thread:
            //    it wraps the input buffer list (no copy) in an AVAudioPCMBuffer
            //    and forwards it. No allocation of the audio data, no locks,
            //    no await.
            let capturedFormat = format
            let stats = ioStats
            var newProcID: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(
                &newProcID,
                aggregateID,
                ioQueue
            ) { @Sendable _, inInputData, _, _, _ in
                // inInputData points at the live buffer list for this cycle.
                let pcm = AVAudioPCMBuffer(
                    pcmFormat: capturedFormat,
                    bufferListNoCopy: inInputData
                )
                stats.withLock { s in
                    s.cycles += 1
                    if let pcm { s.frames += Int64(pcm.frameLength) } else { s.nilBuffers += 1 }
                }
                guard let pcm else { return }
                handler(pcm)
            }
            guard procStatus == noErr, let procID = newProcID else {
                throw SystemAudioTapError.createIOProcFailed(procStatus)
            }
            ioProcID = procID

            // 8. Start IO.
            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else {
                throw SystemAudioTapError.startFailed(startStatus)
            }
            isRunning = true
            log.info("tap started tapID=\(self.tapID, privacy: .public) aggregateID=\(self.aggregateID, privacy: .public) procStatus=\(procStatus, privacy: .public)")
        } catch {
            // Unwind whatever was created, in the documented order.
            teardown()
            throw error
        }
    }

    /// Stops the tap and tears everything down. Idempotent.
    public func stop() {
        teardown()
    }

    /// Ordered teardown: stop IO → destroy IOProc → destroy aggregate → destroy
    /// tap. Safe to call repeatedly; each step is guarded.
    private func teardown() {
        if isRunning {
            let s = ioStats.withLock { $0 }
            log.info("tap teardown ioCycles=\(s.cycles, privacy: .public) nilBuffers=\(s.nilBuffers, privacy: .public) framesSeen=\(s.frames, privacy: .public) writeFailed=\(self.writeFailed.isRaised, privacy: .public)")
        }
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        isRunning = false
    }

    deinit {
        teardown()
    }

    // MARK: - Property reads

    private func readTapUID(_ tap: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw SystemAudioTapError.readTapUIDFailed(status)
        }
        return uid as String
    }

    private func readTapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw SystemAudioTapError.readTapFormatFailed(status)
        }
        return asbd
    }

    // MARK: - PID translation

    /// Translates a POSIX `pid` to the Core Audio process *object* ID(s) that
    /// `CATapDescription` expects. Returns an empty array if translation fails
    /// (the caller then forms a global mixdown with no exclusions).
    private static func audioProcessObjects(forPID pid: pid_t) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &outSize,
            &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return [] }
        return [object]
    }

    // MARK: - Render-safe failure flag

    /// Flag the file-writing IO block raises on a write failure. Read by the
    /// control thread after ``stop()`` (which joins the IO thread), so it needs
    /// no lock and the IO thread never blocks. See `RenderFlag`.
    private let writeFailed = RenderFlag()
}
