import Testing
import Foundation
@testable import KleothCore

/// The pill's motion beats and its content reveal (2026-11-19, the user: an
/// EMPTY grey capsule at the top of the screen right after stopping a
/// 47-minute meeting). The pill had collapsed from "Meeting saved" into the
/// edge under a parked pointer, and the dock peeked out 50 ms into that sink.
/// The sink's reveal had faded the content to nothing and HELD it there until
/// the next beat; the peek, landing mid-sink, replayed the sink's keyframes
/// (SwiftUI hands a retriggered keyframe animator its in-flight value, which
/// carried the old beat). So the dock's surface came out with no fields, for
/// as long as the pointer stayed.
@Suite struct PillRevealTests {
    private let beats: [PillBeat] = [.rise, .sink, .morph, .peek]

    private func total(_ keyframes: [PillRevealKeyframe]) -> TimeInterval {
        keyframes.reduce(0) { $0 + $1.duration }
    }

    // MARK: The content is always shown at rest

    /// Whatever beat played last, once it has ended the content is fully
    /// shown: a phase that lands later without a beat of its own (a settle, a
    /// drag start) or a beat that misses its keyframes can never be blank.
    @Test func everyBeatEndsWithTheContentShown() {
        for beat in beats {
            #expect(PillReveal.opacity(for: beat).last?.value == 1, "\(beat) opacity")
            #expect(PillReveal.scale(for: beat).last?.value == 1, "\(beat) scale")
        }
    }

    /// A sink still hides the outgoing content at once — and keeps it hidden
    /// until the capsule has settled in the edge, where the resting sliver has
    /// nothing to show, so showing it again there is invisible.
    @Test func aSinkHidesTheOutgoingContentUntilItHasSettled() {
        let opacity = PillReveal.opacity(for: .sink)
        #expect(opacity.first?.value == 0)
        #expect((opacity.first?.duration ?? 1) <= 0.1)
        let hidden = opacity.dropLast()
        #expect(hidden.allSatisfy { $0.value == 0 })
        let sinkEnd = PillMotion.settleDelay(moves: true, reshapes: true, staggeredMove: true, peek: false)
        #expect(total(Array(hidden)) >= sinkEnd - 0.001)
        #expect(total(opacity) <= sinkEnd + 0.05)
        // Scale rides with it: shrunk while hidden, full size at the end.
        let scale = PillReveal.scale(for: .sink)
        #expect(scale.dropLast().allSatisfy { $0.value < 1 })
        #expect(abs(total(scale) - total(opacity)) < 0.001)
    }

    /// A rise leaves the edge as a plain blob and blooms its content in — from
    /// HIDDEN on its first frame: it jumps to nothing (no fade out of whatever
    /// the reveal was showing), holds while the capsule leaves the edge, then
    /// fades and springs in. The animator starts every beat from its current
    /// value (fully shown at rest), so without the jump a rise faded 1 → 0
    /// first.
    @Test func aRiseStartsHiddenAndBloomsItsContentIn() {
        let opacity = PillReveal.opacity(for: .rise)
        let scale = PillReveal.scale(for: .rise)
        #expect(opacity.first == PillRevealKeyframe(0, 0, .jump))
        #expect(scale.first == PillRevealKeyframe(0.6, 0, .jump))
        #expect(opacity.dropFirst().first?.value == 0)
        #expect(total(opacity) <= 0.3)
        #expect(opacity.last?.value == 1)
        #expect(scale.last?.value == 1)
    }

    /// A jump is the only keyframe with no duration, and only a rise opens
    /// with one.
    @Test func onlyARiseJumps() {
        for beat in beats {
            for keyframe in PillReveal.opacity(for: beat) + PillReveal.scale(for: beat) {
                #expect((keyframe.curve == .jump) == (keyframe.duration == 0), "\(beat)")
            }
            let jumps = (PillReveal.opacity(for: beat) + PillReveal.scale(for: beat)).contains { $0.curve == .jump }
            #expect(jumps == (beat == .rise), "\(beat)")
        }
    }

    /// Unchanged: a morph or a peek shows the content at once.
    @Test func aMorphOrAPeekShowsTheContentAtOnce() {
        for beat in [PillBeat.morph, .peek] {
            #expect(PillReveal.opacity(for: beat).allSatisfy { $0.value == 1 })
            #expect(total(PillReveal.opacity(for: beat)) <= 0.02)
        }
    }

    // MARK: Which beat a transition plays

    /// An active phase collapsing STRAIGHT onto the peek dock — the pill's
    /// menu open over a confirmation when it auto-hides, or a hover landing in
    /// the same main-queue turn as the collapse. The dock is ON screen, so this
    /// is no sink into the edge: its fields show at once. (Not the reported
    /// flow: there the collapse sank first and the dock peeked out of the sink
    /// 40–56 ms later — a sink, then a peek, which the reveal now plays
    /// right.)
    @Test func theDockComingStraightOutOfAnActivePhaseIsNoSink() {
        #expect(PillMotion.beat(moves: true, toResting: true, toDock: true, fromResting: false, toArmed: false) == .morph)
    }

    /// The rest of the table, as it was.
    @Test func theOtherTransitionsKeepTheirBeats() {
        // An active phase back into the edge.
        #expect(PillMotion.beat(moves: true, toResting: true, toDock: false, fromResting: false, toArmed: false) == .sink)
        // The resting pill peeking out as the dock, and tucking back.
        #expect(PillMotion.beat(moves: true, toResting: true, toDock: true, fromResting: true, toArmed: false) == .peek)
        #expect(PillMotion.beat(moves: true, toResting: true, toDock: false, fromResting: true, toArmed: false) == .peek)
        // Out of the edge into a phase; the chord's first frame is a peek.
        #expect(PillMotion.beat(moves: true, toResting: false, toDock: false, fromResting: true, toArmed: false) == .rise)
        #expect(PillMotion.beat(moves: true, toResting: false, toDock: false, fromResting: true, toArmed: true) == .peek)
        // Phase to phase on screen, and a start that replaces the dock.
        #expect(PillMotion.beat(moves: true, toResting: false, toDock: false, fromResting: false, toArmed: false) == .morph)
        // Nothing moves: a reshape in place.
        for toResting in [false, true] {
            #expect(PillMotion.beat(moves: false, toResting: toResting, toDock: false, fromResting: false, toArmed: false) == .morph)
        }
    }
}
