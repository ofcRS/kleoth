import Testing
import Foundation
@testable import KleothCore

/// Asserts the normative transition table in design §5.1 — events AND the
/// `deadline` the monitor must schedule — one test per row group.
@Suite struct DictationChordMachineTests {
    private let minHold = DictationDefaults.minHold
    private let tapWindow = DictationDefaults.doubleTapWindow
    /// An arbitrary monotonic base; the machine only ever reads differences.
    private let t0: TimeInterval = 1_000

    // MARK: idle → pressed

    @Test func chordDownArmsAndSetsHoldDeadline() {
        var machine = DictationChordMachine()
        #expect(machine.deadline == nil)
        #expect(machine.handle(.chordDown, at: t0) == [.armed])
        #expect(machine.deadline == t0 + minHold)
        #expect(machine.isCapturing)
    }

    // MARK: pressed → holding → idle

    @Test func holdPastDeadlineBeginsThenEnds() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        #expect(machine.handle(.deadline, at: t0 + minHold) == [.began])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing)
        #expect(machine.handle(.chordUp, at: t0 + 2.0) == [.ended])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing == false)
    }

    // MARK: pressed → tapWindow

    @Test func shortTapCancelsTooShortAndOpensTapWindow() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        let release = t0 + 0.1
        #expect(machine.handle(.chordUp, at: release) == [.cancelled(.tooShort)])
        #expect(machine.deadline == release + tapWindow)
        // The tap window is not a capturing state — the mic is already off.
        #expect(machine.isCapturing == false)
    }

    // MARK: tapWindow → hands-free

    @Test func doubleTapTogglesOnAndReleaseDoesNotEnd() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        #expect(machine.handle(.chordDown, at: t0 + 0.2) == [.armed, .toggledOn])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing)
        // Releasing the second tap must NOT end the session — that is what
        // "hands-free" means.
        #expect(machine.handle(.chordUp, at: t0 + 0.3) == [])
        #expect(machine.isCapturing)
    }

    @Test func handsFreeTapTogglesOffAndReleaseDoesNotArm() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        _ = machine.handle(.chordDown, at: t0 + 0.2)
        _ = machine.handle(.chordUp, at: t0 + 0.3)
        // A single tap ends the hands-free session…
        #expect(machine.handle(.chordDown, at: t0 + 5) == [.toggledOff])
        #expect(machine.isCapturing)
        // …and its release must not arm a new capture.
        #expect(machine.handle(.chordUp, at: t0 + 5.1) == [])
        #expect(machine.isCapturing == false)
        #expect(machine.deadline == nil)
    }

    @Test func tapWindowExpiryThenNewPressArms() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        let release = t0 + 0.1
        _ = machine.handle(.chordUp, at: release)
        #expect(machine.handle(.deadline, at: release + tapWindow) == [])
        #expect(machine.deadline == nil)
        // Back in idle: the next chord is an ordinary push-to-talk, not a toggle.
        let second = release + tapWindow + 1
        #expect(machine.handle(.chordDown, at: second) == [.armed])
        #expect(machine.deadline == second + minHold)
    }

    // MARK: External hands-free (the pill's Dictate field / stop click)

    @Test func externalHandsFreeParksInHandsFreeAndNextPressTogglesOff() {
        var machine = DictationChordMachine()
        #expect(machine.handle(.externalHandsFreeOn, at: t0) == [])
        #expect(machine.isCapturing)
        #expect(machine.deadline == nil)
        // The keyboard can end a click-started session, like any hands-free one.
        #expect(machine.handle(.chordDown, at: t0 + 5) == [.toggledOff])
        #expect(machine.handle(.chordUp, at: t0 + 5.1) == [])
        #expect(machine.isCapturing == false)
    }

    @Test func externalHandsFreeOffReturnsToIdleSilently() {
        var machine = DictationChordMachine()
        _ = machine.handle(.externalHandsFreeOn, at: t0)
        #expect(machine.handle(.externalHandsFreeOff, at: t0 + 3) == [])
        #expect(machine.isCapturing == false)
        // Idle again: the next chord is an ordinary push-to-talk.
        #expect(machine.handle(.chordDown, at: t0 + 4) == [.armed])
    }

    @Test func externalHandsFreeIsIgnoredWhileTheChordCaptures() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        #expect(machine.handle(.externalHandsFreeOn, at: t0 + 0.05) == [])
        // Still the keyboard's session: the hold confirms and ends normally.
        #expect(machine.handle(.deadline, at: t0 + minHold) == [.began])
        #expect(machine.handle(.chordUp, at: t0 + 1) == [.ended])
    }

    @Test func externalHandsFreeOffOutsideHandsFreeIsANoOp() {
        var machine = DictationChordMachine()
        #expect(machine.handle(.externalHandsFreeOff, at: t0) == [])
        _ = machine.handle(.chordDown, at: t0 + 1)
        #expect(machine.handle(.externalHandsFreeOff, at: t0 + 1.05) == [])
        #expect(machine.isCapturing)
    }

    @Test func externalHandsFreeFromTapWindowWinsOverTheTap() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        #expect(machine.handle(.externalHandsFreeOn, at: t0 + 0.2) == [])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing)
    }

    @Test func abortEndsAnExternalHandsFreeSessionInIdle() {
        var machine = DictationChordMachine()
        _ = machine.handle(.externalHandsFreeOn, at: t0)
        // Esc / pill ✕: the keys are already up, so there is no release to
        // swallow — the next press arms cleanly.
        #expect(machine.handle(.abort, at: t0 + 1) == [.cancelled(.external)])
        #expect(machine.handle(.chordDown, at: t0 + 2) == [.armed])
    }

    // MARK: otherKey

    @Test func otherKeyWhilePressedCancelsAndBlocksUntilRelease() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        #expect(machine.handle(.otherKey, at: t0 + 0.05) == [.cancelled(.otherKey)])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing == false)
        // Further keys while the chord is still down stay swallowed…
        #expect(machine.handle(.otherKey, at: t0 + 0.06) == [])
        // …and the release is silent (no .ended, no tap window).
        #expect(machine.handle(.chordUp, at: t0 + 0.2) == [])
        #expect(machine.deadline == nil)
        // Idle again: the next chord arms normally.
        #expect(machine.handle(.chordDown, at: t0 + 1) == [.armed])
    }

    @Test func otherKeyWhileHoldingCancels() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.deadline, at: t0 + minHold)
        #expect(machine.handle(.otherKey, at: t0 + 0.5) == [.cancelled(.otherKey)])
        #expect(machine.isCapturing == false)
        #expect(machine.handle(.chordUp, at: t0 + 0.6) == [])
    }

    @Test func otherKeyWhileHandsFreeIsIgnored() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        _ = machine.handle(.chordDown, at: t0 + 0.2)
        // Typing while the second tap is still held is still hands-free.
        #expect(machine.handle(.otherKey, at: t0 + 0.25) == [])
        #expect(machine.isCapturing)
        _ = machine.handle(.chordUp, at: t0 + 0.3)
        // And typing during the hands-free session itself is expected.
        #expect(machine.handle(.otherKey, at: t0 + 1) == [])
        #expect(machine.isCapturing)
        #expect(machine.handle(.chordDown, at: t0 + 2) == [.toggledOff])
    }

    // MARK: missed timer

    @Test func missedDeadlineOnReleaseEmitsBeganAndEnded() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        // The timer never fired (busy run loop), yet the hold was real.
        #expect(machine.handle(.chordUp, at: t0 + minHold + 0.01) == [.began, .ended])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing == false)
        // Exactly at the boundary counts as a hold, not a tap. (Timed from 0 so
        // the comparison is exact — `t0 + minHold - t0` loses a bit to binary
        // floating point and would land just under the threshold.)
        var boundary = DictationChordMachine()
        _ = boundary.handle(.chordDown, at: 0)
        #expect(boundary.handle(.chordUp, at: minHold) == [.began, .ended])
    }

    // MARK: abort

    @Test func abortWhileHoldingCancelsExternalAndSwallowsRelease() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.deadline, at: t0 + minHold)
        #expect(machine.handle(.abort, at: t0 + 1) == [.cancelled(.external)])
        #expect(machine.isCapturing == false)
        #expect(machine.deadline == nil)
        // The physical release of the aborted chord produces nothing.
        #expect(machine.handle(.chordUp, at: t0 + 1.1) == [])
        #expect(machine.handle(.chordDown, at: t0 + 2) == [.armed])
    }

    @Test func abortWhileHoldingStillBlocksUntilRelease() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.deadline, at: t0 + minHold)
        _ = machine.handle(.abort, at: t0 + 1)
        // Keys are still physically down: a second abort (e.g. `stop()` right
        // after `cancel()`) and a stray deadline keep it blocked; a chordDown
        // is impossible here, but it must not arm either.
        #expect(machine.handle(.abort, at: t0 + 1.01) == [])
        #expect(machine.handle(.chordDown, at: t0 + 1.02) == [])
        #expect(machine.isCapturing == false)
        #expect(machine.handle(.chordUp, at: t0 + 1.1) == [])
        #expect(machine.handle(.chordDown, at: t0 + 2) == [.armed])
    }

    @Test func abortWhileHandsFreeReturnsToIdleAndNextPressArms() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        _ = machine.handle(.chordDown, at: t0 + 0.2)              // [.armed, .toggledOn]
        _ = machine.handle(.chordUp, at: t0 + 0.25)               // handsFree, keys up
        // Esc / pill ✕ mid hands-free: the controller aborts. The keys are
        // already up, so there is no release to swallow — the machine must
        // settle in idle, NOT blocked/handsFree.
        #expect(machine.handle(.abort, at: t0 + 2) == [.cancelled(.external)])
        #expect(machine.isCapturing == false)
        #expect(machine.deadline == nil)
        // The very next press is a fresh push-to-talk, never `.toggledOff`.
        #expect(machine.handle(.chordDown, at: t0 + 3) == [.armed])
        #expect(machine.deadline == t0 + 3 + minHold)
    }

    @Test func abortWhileHandsFreeArmingBlocksUntilRelease() {
        // A refused double-tap while the pipeline runs: the second tap's keys
        // are still down when the controller aborts, so the release is
        // swallowed and no tap window opens.
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        _ = machine.handle(.chordDown, at: t0 + 0.2)              // handsFreeArming
        #expect(machine.handle(.abort, at: t0 + 0.21) == [.cancelled(.external)])
        #expect(machine.handle(.chordUp, at: t0 + 0.3) == [])
        #expect(machine.handle(.chordDown, at: t0 + 0.35) == [.armed])
    }

    @Test func abortWhileIdleEmitsNothing() {
        var machine = DictationChordMachine()
        #expect(machine.handle(.abort, at: t0) == [])
        #expect(machine.deadline == nil)
        #expect(machine.isCapturing == false)
        // An abort during the tap window closes it without an event.
        var tapping = DictationChordMachine()
        _ = tapping.handle(.chordDown, at: t0)
        _ = tapping.handle(.chordUp, at: t0 + 0.1)
        #expect(tapping.handle(.abort, at: t0 + 0.15) == [])
        #expect(tapping.deadline == nil)
        // …so the next press is a fresh push-to-talk, never a toggle.
        #expect(tapping.handle(.chordDown, at: t0 + 0.2) == [.armed])
    }

    // MARK: no-ops

    @Test func repeatedChordDownIsIgnored() {
        var machine = DictationChordMachine()
        #expect(machine.handle(.chordDown, at: t0) == [.armed])
        // A duplicate chordDown must not restart the hold deadline.
        #expect(machine.handle(.chordDown, at: t0 + 0.2) == [])
        #expect(machine.deadline == t0 + minHold)
        // A stray deadline after the state moved on is likewise inert.
        _ = machine.handle(.deadline, at: t0 + minHold)
        #expect(machine.handle(.deadline, at: t0 + 1) == [])
        #expect(machine.handle(.chordDown, at: t0 + 1.1) == [])
        #expect(machine.isCapturing)
    }

    @Test func isCapturingReflectsState() {
        var machine = DictationChordMachine()
        #expect(machine.isCapturing == false)                    // idle
        _ = machine.handle(.chordDown, at: t0)
        #expect(machine.isCapturing)                             // pressed
        _ = machine.handle(.deadline, at: t0 + minHold)
        #expect(machine.isCapturing)                             // holding
        _ = machine.handle(.otherKey, at: t0 + 0.4)
        #expect(machine.isCapturing == false)                    // blocked
        _ = machine.handle(.chordUp, at: t0 + 0.5)
        #expect(machine.isCapturing == false)                    // idle
        _ = machine.handle(.chordDown, at: t0 + 1)
        _ = machine.handle(.chordUp, at: t0 + 1.05)
        #expect(machine.isCapturing == false)                    // tapWindow
        _ = machine.handle(.chordDown, at: t0 + 1.1)
        #expect(machine.isCapturing)                             // handsFreeArming
        _ = machine.handle(.chordUp, at: t0 + 1.15)
        #expect(machine.isCapturing)                             // handsFree
        _ = machine.handle(.chordDown, at: t0 + 3)
        #expect(machine.isCapturing)                             // handsFreeEnding
        _ = machine.handle(.chordUp, at: t0 + 3.05)
        #expect(machine.isCapturing == false)                    // idle
    }

    @Test func toggledOnIsPrecededByArmed() {
        var machine = DictationChordMachine()
        _ = machine.handle(.chordDown, at: t0)
        _ = machine.handle(.chordUp, at: t0 + 0.1)
        // The controller's "armed starts the mic" rule must hold for hands-free
        // too: the events arrive in one array, .armed first.
        let events = machine.handle(.chordDown, at: t0 + 0.2)
        #expect(events == [.armed, .toggledOn])
        #expect(events.first == .armed)
    }
}
