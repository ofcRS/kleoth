import Foundation

/// Turns a stream of modifier-flag snapshots into `.chordDown` / `.chordUp`
/// signals for `DictationChordMachine` — the one AppKit-level decision the
/// hotkey monitor makes, lifted into KleothCore so it is unit-tested (the app
/// package has no test target; same rationale as `PillGeometry`).
///
/// Generic over any `OptionSet` so it needs no AppKit: the monitor feeds it
/// `NSEvent.ModifierFlags` intersected with the five real modifiers
/// (fn, shift, ⌘, ⌥, ⌃); tests feed a tiny local option set.
///
/// Rules (design §5.1, §7 row "fn+shift+⌘"):
/// - The chord is *exactly* `chord` — a superset (fn+shift+⌘) never arms.
/// - Adding a third modifier mid-hold reads as `.chordUp`: from `holding` the
///   machine commits (`.ended`, the documented §8.2 #7b behavior), from
///   `pressed` it discards as a short tap.
/// - Releasing that third modifier off a superset (fn+shift+⌘ → fn+shift) is
///   NOT a chord-down: fn+shift never moved, that chord was somebody else's
///   shortcut. The edge is suppressed and `chordIsDown` stays false, so the
///   eventual fn/shift release is a non-transition too — nothing reaches the
///   machine, which would otherwise arm (or, from `tapWindow`, start a
///   hands-free session) behind the user's back.
public struct ChordEdgeDetector<Flags: OptionSet> {
    public let chord: Flags
    /// The flag set of the last snapshot, whatever it was.
    private var lastFlags: Flags
    /// The last chord state told to the machine — debounces the
    /// `.flagsChanged` storm a real keypress produces.
    public private(set) var chordIsDown = false

    public init(chord: Flags) {
        self.chord = chord
        self.lastFlags = []
    }

    /// Feeds one snapshot of the relevant modifiers; returns the signal to hand
    /// the machine, or nil for a non-transition.
    public mutating func ingest(_ flags: Flags) -> ChordSignal? {
        let hadChordKeys = lastFlags.isSuperset(of: chord)
        lastFlags = flags
        let down = flags == chord
        guard down != chordIsDown else { return nil }
        if down && hadChordKeys {
            // fn+shift never moved — a third modifier was released off a
            // superset. Leave `chordIsDown` false so the later fn/shift
            // release is also a no-op.
            return nil
        }
        chordIsDown = down
        return down ? .chordDown : .chordUp
    }

    /// Forgets everything (monitor `start()` / `stop()`).
    public mutating func reset() {
        lastFlags = []
        chordIsDown = false
    }
}
