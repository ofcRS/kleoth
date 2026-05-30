import Foundation
import AVFoundation

/// Owns the microphone and system-audio capture, writing `mic.m4a` and
/// `system.m4a` separately, and can also build a single 2-channel `.m4a`
/// suitable for Scribe multi-channel transcription.
///
/// Requires macOS 14.4+ (it owns a `SystemAudioTap`).
@available(macOS 14.4, *)
public final class Recorder {
    private let mic: MicCapture
    private let systemTap: SystemAudioTap

    public init() {
        self.mic = MicCapture()
        self.systemTap = SystemAudioTap()
    }

    /// Begins recording mic and system audio into `outputDir`.
    public func start(outputDir: URL) throws {
        fatalError("unimplemented")
    }

    /// Stops recording and finalizes the output files.
    public func stop() throws {
        fatalError("unimplemented")
    }

    /// Combines `mic.m4a` and `system.m4a` into a single 2-channel `.m4a`
    /// (channel 0 = mic, channel 1 = system) for multi-channel transcription.
    public func buildTwoChannelFile(outputURL: URL) throws -> URL {
        fatalError("unimplemented")
    }
}
