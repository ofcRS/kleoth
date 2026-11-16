import Testing
@testable import KleothCore

@Suite struct UpdatePolicyTests {
    typealias Activity = UpdatePolicy.Activity

    @Test func relaunchesOnlyWhenNothingIsInFlight() {
        #expect(UpdatePolicy.mayRelaunch(.idle))
        #expect(!UpdatePolicy.mayRelaunch(Activity(meetingRecording: true)))
        #expect(!UpdatePolicy.mayRelaunch(Activity(meetingProcessing: true)))
        #expect(!UpdatePolicy.mayRelaunch(Activity(screenRecording: true)))
        // A saved screen recording is no longer "active", but its transcription has started.
        #expect(!UpdatePolicy.mayRelaunch(Activity(recordingTranscription: true)))
        #expect(!UpdatePolicy.mayRelaunch(Activity(dictation: true)))
        #expect(!UpdatePolicy.mayRelaunch(Activity(backgroundJobs: true)))
    }

    @Test func waitsForTheCaptureBeforeTheBackgroundWork() {
        #expect(Activity.idle.waitingFor == nil)
        #expect(Activity(meetingRecording: true, meetingProcessing: true).waitingFor == "the meeting recording")
        #expect(Activity(meetingProcessing: true, screenRecording: true).waitingFor == "the screen recording")
        #expect(Activity(meetingProcessing: true, dictation: true).waitingFor == "the dictation")
        #expect(Activity(meetingProcessing: true).waitingFor == "the transcription")
        #expect(Activity(recordingTranscription: true, backgroundJobs: true).waitingFor == "the transcription")
        #expect(Activity(backgroundJobs: true).waitingFor == "the background jobs")
    }

    @Test func sparkleShowsAScheduledUpdateOnlyInFocusAndIdle() {
        #expect(UpdatePolicy.sparkleShowsScheduledUpdate(immediateFocus: true, activity: .idle, firstRunOnScreen: false))
        // Away from launch its alert would open behind other apps: the popover shows it instead.
        #expect(!UpdatePolicy.sparkleShowsScheduledUpdate(immediateFocus: false, activity: .idle, firstRunOnScreen: false))
        // Never over a capture (a window mid-dictation takes the paste) or the welcome window.
        #expect(!UpdatePolicy.sparkleShowsScheduledUpdate(immediateFocus: true, activity: Activity(dictation: true), firstRunOnScreen: false))
        #expect(!UpdatePolicy.sparkleShowsScheduledUpdate(immediateFocus: true, activity: Activity(meetingRecording: true), firstRunOnScreen: false))
        #expect(!UpdatePolicy.sparkleShowsScheduledUpdate(immediateFocus: true, activity: .idle, firstRunOnScreen: true))
    }

    @Test func versionLabelShowsTheBuildSparkleCompares() {
        #expect(UpdatePolicy.versionLabel(shortVersion: "0.5.5", build: "10") == "0.5.5 (10)")
        #expect(UpdatePolicy.versionLabel(shortVersion: "0.5.5", build: nil) == "0.5.5")
        #expect(UpdatePolicy.versionLabel(shortVersion: "10", build: "10") == "10")
        #expect(UpdatePolicy.versionLabel(shortVersion: nil, build: "10") == "10")
        #expect(UpdatePolicy.versionLabel(shortVersion: " ", build: "") == "unknown")
    }
}
