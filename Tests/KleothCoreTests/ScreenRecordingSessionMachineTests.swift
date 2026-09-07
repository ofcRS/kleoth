import Testing
import Foundation
@testable import KleothCore

/// The screen-recording session machine (design §3.1, §2.1, §2.4, §2.7).
///
/// The contract these tests defend is the same one `DictationChordMachine` has:
/// `apply` is TOTAL, every rejection leaves the state untouched, and the
/// returned `Effect` is the only instruction the controller acts on. A stop
/// must never be lost — that is the difference between a saved file and a
/// half-written one.
@Suite struct ScreenRecordingSessionMachineTests {
    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    private func summary(duration: TimeInterval = 134, bytes: Int64 = 48_000_000) -> ScreenRecordingSummary {
        ScreenRecordingSummary(
            url: URL(fileURLWithPath: "/tmp/screen-2026-09-06-143012.mp4"),
            duration: duration,
            fileSizeBytes: bytes,
            videoFramesAppended: 4_020,
            droppedFrames: 0,
            micCaptured: true,
            micGaps: [],
            stopReason: .user
        )
    }

    // MARK: - The happy path

    @Test func happyPathWalksTheWholeSession() {
        var machine = ScreenRecordingSessionMachine()
        #expect(machine.state == .idle)
        #expect(machine.isActive == false)

        #expect(machine.apply(.startRequested(start)) == .requestPermission)
        #expect(machine.state == .checkingPermission)
        #expect(machine.isActive)

        #expect(machine.apply(.permissionOK) == .presentPicker)
        #expect(machine.state == .pickingRegion)

        // The pill shows `.recording` from HERE (§2.1 step 5), so the start
        // instant has to survive the permission + picker legs.
        #expect(machine.apply(.regionPicked) == .startCapture)
        #expect(machine.state == .starting(since: start))
        #expect(machine.since == start)

        #expect(machine.apply(.captureStarted) == .showRecording)
        #expect(machine.state == .recording(since: start))
        #expect(machine.since == start)

        #expect(machine.apply(.stopRequested(.user)) == .stopCapture)
        #expect(machine.state == .stopping(reason: .user))
        #expect(machine.since == nil)

        #expect(machine.apply(.captureStopped) == .finalize)
        #expect(machine.state == .saving)

        let done = summary()
        #expect(machine.apply(.finalized(done)) == .showSaved)
        #expect(machine.state == .saved(done))
        #expect(machine.isActive == false)

        #expect(machine.apply(.dismissed) == .reset)
        #expect(machine.state == .idle)
    }

    // MARK: - Cancellation and refusal

    /// Esc in the region picker is a full cancel — no file, no capture, and the
    /// remembered start instant is dropped so the next session gets its own.
    @Test func escapeInThePickerReturnsToIdleWithNoFileEffect() {
        var machine = ScreenRecordingSessionMachine()
        machine.apply(.startRequested(start))
        machine.apply(.permissionOK)

        #expect(machine.apply(.regionCancelled) == .reset)
        #expect(machine.state == .idle)
        #expect(machine.since == nil)

        // A fresh start carries the NEW instant, not the abandoned one.
        let later = start.addingTimeInterval(60)
        machine.apply(.startRequested(later))
        machine.apply(.permissionOK)
        machine.apply(.regionPicked)
        #expect(machine.state == .starting(since: later))
    }

    /// Quit (or any stop) before there is anything to stop unwinds to idle
    /// rather than pretending a file is being finalized — §2.7.
    @Test func quitBeforeCaptureStartsUnwindsWithNoFinalize() {
        for state in [ScreenRecordingSessionMachine.State.checkingPermission, .pickingRegion] {
            var machine = ScreenRecordingSessionMachine()
            machine.apply(.startRequested(start))
            if state == .pickingRegion { machine.apply(.permissionOK) }
            #expect(machine.state == state)

            #expect(machine.apply(.stopRequested(.quit)) == .reset)
            #expect(machine.state == .idle)
        }
    }

    /// A stop that arrives while the capture is still coming up must not be
    /// dropped on the floor — the user clicked stop and expects a file.
    @Test func stopWhileStartingIsNeverLost() {
        var machine = ScreenRecordingSessionMachine()
        machine.apply(.startRequested(start))
        machine.apply(.permissionOK)
        machine.apply(.regionPicked)
        #expect(machine.state == .starting(since: start))

        #expect(machine.apply(.stopRequested(.user)) == .stopCapture)
        #expect(machine.state == .stopping(reason: .user))

        // And a late `captureStarted` from the racing start does NOT resurrect
        // the recording.
        #expect(machine.apply(.captureStarted) == nil)
        #expect(machine.state == .stopping(reason: .user))

        #expect(machine.apply(.captureStopped) == .finalize)
        #expect(machine.state == .saving)
    }

    /// The "Stop Sharing" chip / display asleep path: the system ends the
    /// stream, and the file is still finalized and shown.
    @Test func systemStoppedStreamSavesLikeAUserStop() {
        var machine = ScreenRecordingSessionMachine()
        machine.apply(.startRequested(start))
        machine.apply(.permissionOK)
        machine.apply(.regionPicked)
        machine.apply(.captureStarted)

        #expect(machine.apply(.stopRequested(.systemStoppedStream)) == .stopCapture)
        #expect(machine.state == .stopping(reason: .systemStoppedStream))
        #expect(machine.apply(.captureStopped) == .finalize)
        #expect(machine.state == .saving)

        let done = summary()
        #expect(machine.apply(.finalized(done)) == .showSaved)
        #expect(machine.state == .saved(done))
    }

    /// A second stop (the user clicks the pill twice) is a no-op, not a second
    /// `stopCapture` on a writer that is already finishing.
    @Test func aSecondStopIsIgnored() {
        var machine = ScreenRecordingSessionMachine()
        machine.apply(.startRequested(start))
        machine.apply(.permissionOK)
        machine.apply(.regionPicked)
        machine.apply(.captureStarted)
        machine.apply(.stopRequested(.user))

        #expect(machine.apply(.stopRequested(.user)) == nil)
        #expect(machine.state == .stopping(reason: .user))

        machine.apply(.captureStopped)
        #expect(machine.apply(.stopRequested(.quit)) == nil)
        #expect(machine.state == .saving)
    }

    /// `alreadyActive` (§7) is the CONTROLLER's message; the machine's job is
    /// simply to refuse and change nothing.
    @Test func startRequestedWhileActiveIsRefusedAndChangesNothing() {
        let active: [ScreenRecordingSessionMachine.State] = [
            .checkingPermission, .pickingRegion, .starting(since: Date(timeIntervalSince1970: 1)),
            .recording(since: Date(timeIntervalSince1970: 1)), .stopping(reason: .user), .saving,
        ]
        for state in active {
            var machine = machine(in: state)
            let before = machine
            #expect(machine.apply(.startRequested(start.addingTimeInterval(999))) == nil)
            #expect(machine == before, "startRequested mutated \(state)")
        }
    }

    /// From a terminal state a start is allowed and REPLACES the old result —
    /// the pill's `.saved` confirmation must not block the next recording.
    @Test func startRequestedFromATerminalStateIsAccepted() {
        var afterSaved = machine(in: .saved(summary()))
        #expect(afterSaved.apply(.startRequested(start)) == .requestPermission)
        #expect(afterSaved.state == .checkingPermission)

        var afterFailed = machine(in: .failed(.permissionNeeded))
        #expect(afterFailed.apply(.startRequested(start)) == .requestPermission)
        #expect(afterFailed.state == .checkingPermission)
    }

    // MARK: - Failures

    @Test func everyFailureLegLandsInFailedWithItsOwnReason() {
        var noPermission = ScreenRecordingSessionMachine()
        noPermission.apply(.startRequested(start))
        #expect(noPermission.apply(.permissionMissing(.permissionStale)) == .showFailed)
        #expect(noPermission.state == .failed(.permissionStale))
        #expect(noPermission.isActive == false)

        var noStart = ScreenRecordingSessionMachine()
        noStart.apply(.startRequested(start))
        noStart.apply(.permissionOK)
        noStart.apply(.regionPicked)
        #expect(noStart.apply(.captureDidNotStart(.captureFailed("SCStream -3801"))) == .showFailed)
        #expect(noStart.state == .failed(.captureFailed("SCStream -3801")))

        var noFile = ScreenRecordingSessionMachine()
        noFile.apply(.startRequested(start))
        noFile.apply(.permissionOK)
        noFile.apply(.regionPicked)
        noFile.apply(.captureStarted)
        noFile.apply(.stopRequested(.writerFailed))
        noFile.apply(.captureStopped)
        #expect(noFile.apply(.finalizeFailed(.nothingCaptured)) == .showFailed)
        #expect(noFile.state == .failed(.nothingCaptured))
    }

    @Test func dismissingATerminalStateResets() {
        var saved = machine(in: .saved(summary()))
        #expect(saved.apply(.dismissed) == .reset)
        #expect(saved.state == .idle)

        var failed = machine(in: .failed(.diskFull))
        #expect(failed.apply(.dismissed) == .reset)
        #expect(failed.state == .idle)

        // Dismissing an in-flight session is NOT a cancel — the pill's auto-hide
        // must never silently abandon a running capture.
        var recording = machine(in: .recording(since: start))
        #expect(recording.apply(.dismissed) == nil)
        #expect(recording.state == .recording(since: start))
    }

    // MARK: - Derived properties

    @Test func isActiveAndSinceCoverEveryState() {
        let expectations: [(ScreenRecordingSessionMachine.State, Bool, Date?)] = [
            (.idle, false, nil),
            (.checkingPermission, true, nil),
            (.pickingRegion, true, nil),
            (.starting(since: start), true, start),
            (.recording(since: start), true, start),
            (.stopping(reason: .user), true, nil),
            (.saving, true, nil),
            (.saved(summary()), false, nil),
            (.failed(.diskFull), false, nil),
        ]
        for (state, active, since) in expectations {
            let machine = machine(in: state)
            #expect(machine.isActive == active, "isActive wrong for \(state)")
            #expect(machine.since == since, "since wrong for \(state)")
        }
    }

    // MARK: - Totality

    /// `apply` must be total: every state × every event has a defined answer, a
    /// rejection leaves the machine byte-identical, and nothing traps. The
    /// controller drives this machine from callback threads and a terminating
    /// process — an unhandled pair would be a crash on quit.
    @Test func applyIsTotalOverEveryStateAndEvent() {
        var pairs = 0
        for state in Self.allStates {
            for event in Self.allEvents {
                var machine = machine(in: state)
                let before = machine
                let effect = machine.apply(event)
                pairs += 1

                if effect == nil {
                    #expect(machine == before, "rejected \(event) mutated \(state)")
                } else {
                    // Every accepted transition moves: there is no legal no-op.
                    #expect(machine.state != state, "accepted \(event) left \(state) unchanged")
                }
            }
        }
        #expect(pairs == Self.allStates.count * Self.allEvents.count)
        #expect(pairs == 9 * 12)
    }

    /// A rejected event must not consume the remembered start instant either —
    /// otherwise a stray callback mid-picker would silently produce a session
    /// with no elapsed clock.
    @Test func rejectedEventsDoNotEatTheRememberedStart() {
        var machine = ScreenRecordingSessionMachine()
        machine.apply(.startRequested(start))
        machine.apply(.permissionOK)

        for stray in [ScreenRecordingSessionMachine.Event.captureStarted, .captureStopped, .dismissed, .permissionOK] {
            #expect(machine.apply(stray) == nil)
        }
        machine.apply(.regionPicked)
        #expect(machine.state == .starting(since: start))
    }

    // MARK: - Helpers

    /// Drives a fresh machine into `state` through legal events only — the
    /// machine has no state setter, and building the fixture out of real
    /// transitions is also a second pass over the table.
    private func machine(in state: ScreenRecordingSessionMachine.State) -> ScreenRecordingSessionMachine {
        var machine = ScreenRecordingSessionMachine()
        switch state {
        case .idle:
            return machine
        case .checkingPermission:
            machine.apply(.startRequested(start))
        case .pickingRegion:
            machine.apply(.startRequested(start))
            machine.apply(.permissionOK)
        case .starting(let since):
            machine.apply(.startRequested(since))
            machine.apply(.permissionOK)
            machine.apply(.regionPicked)
        case .recording(let since):
            machine.apply(.startRequested(since))
            machine.apply(.permissionOK)
            machine.apply(.regionPicked)
            machine.apply(.captureStarted)
        case .stopping(let reason):
            machine.apply(.startRequested(start))
            machine.apply(.permissionOK)
            machine.apply(.regionPicked)
            machine.apply(.captureStarted)
            machine.apply(.stopRequested(reason))
        case .saving:
            machine = self.machine(in: .stopping(reason: .user))
            machine.apply(.captureStopped)
        case .saved(let summary):
            machine = self.machine(in: .saving)
            machine.apply(.finalized(summary))
        case .failed(let failure):
            machine.apply(.startRequested(start))
            machine.apply(.permissionMissing(failure))
        }
        #expect(machine.state == state, "fixture failed to reach \(state)")
        return machine
    }

    private static let allStates: [ScreenRecordingSessionMachine.State] = [
        .idle,
        .checkingPermission,
        .pickingRegion,
        .starting(since: Date(timeIntervalSince1970: 1_757_000_000)),
        .recording(since: Date(timeIntervalSince1970: 1_757_000_000)),
        .stopping(reason: .user),
        .saving,
        .saved(ScreenRecordingSummary(
            url: URL(fileURLWithPath: "/tmp/screen.mp4"), duration: 1, fileSizeBytes: 1,
            videoFramesAppended: 1, droppedFrames: 0, micCaptured: false, micGaps: [], stopReason: .user
        )),
        .failed(.permissionNeeded),
    ]

    private static let allEvents: [ScreenRecordingSessionMachine.Event] = [
        .startRequested(Date(timeIntervalSince1970: 1_757_000_500)),
        .permissionOK,
        .permissionMissing(.permissionNeeded),
        .regionPicked,
        .regionCancelled,
        .captureStarted,
        .captureDidNotStart(.noDisplay),
        .stopRequested(.user),
        .captureStopped,
        .finalized(ScreenRecordingSummary(
            url: URL(fileURLWithPath: "/tmp/screen.mp4"), duration: 2, fileSizeBytes: 2,
            videoFramesAppended: 2, droppedFrames: 0, micCaptured: true, micGaps: [], stopReason: .user
        )),
        .finalizeFailed(.writerFailed("-11800")),
        .dismissed,
    ]
}
