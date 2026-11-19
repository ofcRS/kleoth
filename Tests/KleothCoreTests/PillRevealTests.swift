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

    /// Unchanged: a rise leaves the edge as a plain blob and blooms its
    /// content in.
    @Test func aRiseRevealsItsContentOnceOutOfTheEdge() {
        #expect(PillReveal.opacity(for: .rise).first?.value == 0)
        #expect(PillReveal.scale(for: .rise).first?.value == 0.6)
        #expect(total(PillReveal.opacity(for: .rise)) <= 0.3)
    }

    /// Unchanged: a morph or a peek shows the content at once.
    @Test func aMorphOrAPeekShowsTheContentAtOnce() {
        for beat in [PillBeat.morph, .peek] {
            #expect(PillReveal.opacity(for: beat).allSatisfy { $0.value == 1 })
            #expect(total(PillReveal.opacity(for: beat)) <= 0.02)
        }
    }

    // MARK: Which beat a transition plays

    /// The bug's own transition: an active phase ("Meeting saved") straight
    /// onto the peek dock under the pointer. The dock is ON screen, so this is
    /// no sink into the edge: its fields show at once.
    @Test func theDockComingOutOfAnActivePhaseIsNoSink() {
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
