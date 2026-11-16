import Foundation

/// The in-app updater's two decisions, pure so they are tested here; the Sparkle glue is the app's
/// `UpdaterController` (design: `docs/plans/2026-11-16-updater.md`).
///
/// 1. **Never relaunch over work in flight.** Installing an update quits and relaunches Kleoth, which
///    would cut off a meeting (its recording, or the transcription that follows it), a screen
///    recording or a dictation. Sparkle asks before it relaunches; the answer is "not yet" until
///    `Activity.isIdle`.
/// 2. **Who shows a scheduled update.** Sparkle's own alert comes forward only when it would take
///    focus anyway (near launch: `immediateFocus`) and nothing is in flight and no first-run flow is
///    on screen. Every other find is shown gently: the popover's "New version of Kleoth is
///    available" with an Update button. A window that pops up mid-dictation would take the paste;
///    one mid-meeting could be on a shared screen.
public enum UpdatePolicy {
    /// What Kleoth is doing, as far as a relaunch is concerned.
    public struct Activity: Equatable, Sendable {
        /// A meeting is recording.
        public var meetingRecording: Bool
        /// A meeting is finalizing, transcribing or summarizing (`RecordingController.isProcessing`):
        /// set in the same main-actor turn the recording stops, so there is no idle gap between the two.
        public var meetingProcessing: Bool
        /// A screen recording is starting, recording or saving.
        public var screenRecording: Bool
        /// A dictation is listening or in its pipeline, or a saved one is being retried (the retry pastes).
        public var dictation: Bool

        public init(
            meetingRecording: Bool = false,
            meetingProcessing: Bool = false,
            screenRecording: Bool = false,
            dictation: Bool = false
        ) {
            self.meetingRecording = meetingRecording
            self.meetingProcessing = meetingProcessing
            self.screenRecording = screenRecording
            self.dictation = dictation
        }

        public static let idle = Activity()

        public var isIdle: Bool {
            !meetingRecording && !meetingProcessing && !screenRecording && !dictation
        }

        /// What an update waits for, for "installs after …": the capture the user is in first, the
        /// background work last. Nil when idle.
        public var waitingFor: String? {
            if meetingRecording { return "the meeting recording" }
            if screenRecording { return "the screen recording" }
            if dictation { return "the dictation" }
            if meetingProcessing { return "the transcription" }
            return nil
        }
    }

    /// Whether Sparkle may quit and relaunch Kleoth to install an update now.
    public static func mayRelaunch(_ activity: Activity) -> Bool {
        activity.isIdle
    }

    /// Whether Sparkle shows a scheduled update with its own alert (true) or Kleoth shows it in the
    /// popover (false). `immediateFocus` is Sparkle's: for a menu-bar app it is true only near launch,
    /// and otherwise its alert would open behind other apps' windows.
    public static func sparkleShowsScheduledUpdate(
        immediateFocus: Bool,
        activity: Activity,
        firstRunOnScreen: Bool
    ) -> Bool {
        immediateFocus && activity.isIdle && !firstRunOnScreen
    }

    /// "0.5.5 (10)": the marketing version with the build Sparkle compares.
    public static func versionLabel(shortVersion: String?, build: String?) -> String {
        let short = shortVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        let number = build?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (short.isEmpty, number.isEmpty) {
        case (false, false) where short != number: return "\(short) (\(number))"
        case (false, _): return short
        case (true, false): return number
        case (true, true): return "unknown"
        }
    }
}
