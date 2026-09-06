import Foundation
import KleothObjC

/// An Objective-C exception caught by ``catchingObjCExceptions(_:)`` and
/// surfaced as a Swift error.
public struct ObjCExceptionError: Error, Sendable, LocalizedError {
    public let name: String
    public let reason: String?

    public var errorDescription: String? {
        reason ?? name
    }
}

/// Runs `body` with `NSException`s caught and rethrown as ``ObjCExceptionError``.
///
/// Use it around every AVFoundation call that is documented to raise —
/// `AVAudioNode.installTap` (a format that no longer matches the hardware,
/// e.g. after the default input device changed while the engine was idle),
/// `AVAudioEngine.connect`. An exception that escapes into AppKit's run loop
/// is not fatal by itself, but it corrupts the Swift concurrency runtime's
/// executor tracking and the process dies on a later, unrelated main-actor
/// call (see `KleothObjC.h`).
public func catchingObjCExceptions(_ body: () -> Void) throws {
    if let exception = KLCatchObjCException(body) {
        throw ObjCExceptionError(name: exception.name.rawValue, reason: exception.reason)
    }
}
