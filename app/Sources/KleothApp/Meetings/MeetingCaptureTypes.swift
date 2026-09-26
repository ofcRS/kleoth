import Foundation

/// What `RecordingController.start()` did (meetings-in-the-pill design §4.4).
/// Existing callers ignore it (`@discardableResult`); the pill's bridge shows
/// a fault only for `.failed` — `.needsConsent` is answered by the "Before you
/// record" window the menu-bar label opens on `consentRequest`, and
/// `.alreadyRecording` means the bar is already up.
public enum MeetingStartOutcome: Equatable, Sendable {
    case started(since: Date)
    case alreadyRecording
    case needsConsent
    case failed(String)
}

/// The meeting capture's life, as `RecordingController` reports it to
/// observers that have no pill knowledge of their own (the bridge, phase 2's
/// detection controller). Fired on the main actor, in this order per meeting:
/// `started` → `finalizing` → `saved` | `stopFailed`. The one exception is a
/// `stopFailed` with no directory: `stop()`'s "no active recording" guard
/// sends it with no `finalizing` before it.
public enum MeetingCaptureEvent: Equatable, Sendable {
    case started(since: Date, directory: URL)
    /// The capture slot is free; the two files are being combined.
    case finalizing(directory: URL)
    /// `seconds` is the wall clock from `since` to the stop; `transcribing`
    /// mirrors `auto_transcribe`.
    case saved(directory: URL, seconds: TimeInterval, transcribing: Bool)
    case stopFailed(message: String, directory: URL?)
}
