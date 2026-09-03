import Testing
import Foundation
@testable import KleothCore

/// The monitor-level chord edge rule (design §5.1 / §7 "fn+shift+⌘", §8.2 #7b),
/// asserted against a stand-in for `NSEvent.ModifierFlags`.
@Suite struct ChordEdgeDetectorTests {
    private struct Mods: OptionSet {
        let rawValue: UInt8
        static let fn = Mods(rawValue: 1 << 0)
        static let shift = Mods(rawValue: 1 << 1)
        static let command = Mods(rawValue: 1 << 2)
        static let chord: Mods = [.fn, .shift]
    }

    @Test func exactChordGoesDownAndUp() {
        var detector = ChordEdgeDetector(chord: Mods.chord)
        #expect(detector.ingest([.fn]) == nil)                   // half the chord
        #expect(detector.ingest([.fn, .shift]) == .chordDown)
        #expect(detector.chordIsDown)
        #expect(detector.ingest([.fn, .shift]) == nil)           // flagsChanged storm debounced
        #expect(detector.ingest([.shift]) == .chordUp)           // fn released first
        #expect(!detector.chordIsDown)
        #expect(detector.ingest([]) == nil)
    }

    @Test func addingAThirdModifierMidHoldReadsAsChordUp() {
        // From `holding` the machine commits (.ended) — the documented 7b
        // behavior; from `pressed` it discards as a short tap.
        var detector = ChordEdgeDetector(chord: Mods.chord)
        _ = detector.ingest([.fn, .shift])
        #expect(detector.ingest([.fn, .shift, .command]) == .chordUp)
        #expect(!detector.chordIsDown)
    }

    @Test func releasingTheThirdModifierOffASupersetNeverArms() {
        // fn+shift+⌘ pressed (⌘ first, so the chord never matched exactly),
        // then ⌘ released: fn+shift never moved, so this is NOT a chord-down,
        // and the eventual fn/shift release is not a chord-up either.
        var detector = ChordEdgeDetector(chord: Mods.chord)
        #expect(detector.ingest([.command]) == nil)
        #expect(detector.ingest([.fn, .shift, .command]) == nil)
        #expect(detector.ingest([.fn, .shift]) == nil)           // suppressed edge
        #expect(!detector.chordIsDown)
        #expect(detector.ingest([]) == nil)
        // A genuine press afterwards still arms.
        #expect(detector.ingest([.fn, .shift]) == .chordDown)
    }

    @Test func supersetAfterExactPressThenReleaseOfThirdModifierIsSuppressed() {
        // fn+shift first (arms), ⌘ added (chord up → short tap / tap window),
        // ⌘ released with fn+shift still down: must not re-arm — from
        // `tapWindow` that chordDown would start a hands-free session.
        var detector = ChordEdgeDetector(chord: Mods.chord)
        #expect(detector.ingest([.fn, .shift]) == .chordDown)
        #expect(detector.ingest([.fn, .shift, .command]) == .chordUp)
        #expect(detector.ingest([.fn, .shift]) == nil)
        #expect(detector.ingest([.fn]) == nil)
        #expect(detector.ingest([]) == nil)
    }

    @Test func resetForgetsTheHeldChord() {
        var detector = ChordEdgeDetector(chord: Mods.chord)
        _ = detector.ingest([.fn, .shift])
        detector.reset()
        #expect(!detector.chordIsDown)
        #expect(detector.ingest([.fn, .shift]) == .chordDown)
    }
}
