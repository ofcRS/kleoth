import Foundation
import AVFoundation
import CoreAudio

/// Captures system audio using a Core Audio process tap feeding an
/// aggregate device with an `IOProc`.
///
/// Requires macOS 14.4+. Live capture is exercised only from a signed,
/// bundled app.
@available(macOS 14.4, *)
public final class SystemAudioTap {
    public init() {}

    /// Starts the process tap and begins delivering audio buffers.
    public func start() throws {
        fatalError("unimplemented")
    }

    /// Stops the tap and tears down the aggregate device.
    public func stop() {
        fatalError("unimplemented")
    }
}
