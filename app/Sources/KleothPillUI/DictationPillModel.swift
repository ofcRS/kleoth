import Foundation
import SwiftUI
import KleothCore

/// The observable state `DictationPillView` renders (design §3.19).
///
/// Deliberately dumb: `DictationPillController` owns every transition (and the
/// panel), the view only reads. Kept separate from the controller so the SwiftUI
/// content can be driven by a plain `@EnvironmentObject` without the view ever
/// touching AppKit.
@MainActor
final class DictationPillModel: ObservableObject {
    /// The phase being rendered. `.hidden` whenever the panel is off-screen.
    @Published private(set) var phase: DictationPillState = .hidden
    /// 0…1 mic level for the meter, already normalized + smoothed by the caller
    /// (`PillGeometry.normalizedLevel` / `smoothLevel`).
    @Published private(set) var level: Double = 0
    /// 0…1 mic + system levels for the `.recording` toolbar's two meters.
    /// Unlike `level` (which the dictation controller normalizes) these are
    /// shaped by `DictationPillController.setRecordingLevels` from the raw RMS
    /// the recorder reports, so the app hands the pill physics, not pixels.
    @Published private(set) var recordingLevels: AudioLevels = .zero
    /// Drives the spring-in / fade-out. Set *after* the panel is on screen so
    /// SwiftUI has a state change to animate.
    @Published var isPresented: Bool = false
    /// The screen edge the pill lives on. A side edge stands the capsule up
    /// (the view rotates it ±90°, so a pill parked on the left is a vertical
    /// bar that reads bottom-to-top) and turns the resting sheen so its bright
    /// end faces into the screen — UNLESS `flat` is set.
    @Published private(set) var edge: PillGeometry.Edge = .bottom
    /// The capsule lies HORIZONTAL whatever the edge: no rotation, no swapped
    /// panel dimensions, the bar hugging the edge and extending inward. True
    /// for the screen-recording phases and — while a recording is in flight —
    /// for every dictation phase, so a live recording toolbar never stands on
    /// its end (a 220 pt vertical bar down a side edge is unreadable, and the
    /// digits would have to be counter-rotated per glyph). Rides the shape
    /// spring with `phase`/`capsuleSize` so a flip is a tumble, not a snap.
    @Published private(set) var flat: Bool = false
    /// Where the pointer is inside the panel, in the root view's coordinate
    /// space (SwiftUI points, y down), or nil when it is outside. Fed by
    /// `DictationPillHostingView`'s `.activeAlways` tracking area — SwiftUI's
    /// own `.onHover` is dead while another app is frontmost, which is always.
    /// The Stop button uses it for its own hover state.
    @Published private(set) var pointer: CGPoint?
    /// Where the capsule sits inside the panel, as a displacement from the
    /// panel's center in SwiftUI points (y down). Zero whenever the panel is
    /// sized to the capsule; non-zero only while a transition is in flight and
    /// the panel is a stage covering both the start and the end rect. The
    /// controller animates this — it is THE pill's motion.
    @Published private(set) var offset: CGSize = .zero
    /// Explicit width for the text label of `.warning` / `.failed`, measured
    /// and capped by the controller so an over-long message truncates instead
    /// of running off the screen; nil for phases without text.
    @Published private(set) var labelWidth: CGFloat?
    /// The capsule's own (un-rotated) size for the phase being rendered.
    /// Explicit so it ANIMATES: a width that came from swapped-in content
    /// snapped to its final value the instant the phase changed (the pill
    /// popped to its full listening shape while still tucked in the edge).
    /// Applied inside the same spring as `phase`.
    @Published private(set) var capsuleSize = CGSize(width: 68, height: 22)
    /// The last motion cue — drives the view's keyframed squash-and-stretch
    /// and content reveal. `id` changes on every beat so equal kinds retrigger.
    @Published private(set) var beat = MotionBeat(kind: .morph, id: 0)
    /// Pointer over the panel (any phase). Set in every phase by
    /// `DictationPillController.handleHover`; the view reads it in
    /// `.recording` to swap the red dot for a `stop.fill` glyph, because a
    /// click anywhere on that capsule stops the recording (§6.4).
    @Published private(set) var hovered = false
    /// The resting capsule is pulled fully on screen by the pointer.
    @Published private(set) var peeking = false
    /// The pill's menu is up (the ⋯ glyph stays lit, the peek holds).
    @Published private(set) var menuOpen = false
    /// The dock's SURFACE (glass or ink) is on the capsule. Set the moment the
    /// dock comes out; cleared only once the collapse back into the sliver has
    /// SETTLED — deliberately later than `peeking`, which drops at the start
    /// of the collapse so the fields fade at once. Swapping the surface at
    /// the start too left SwiftUI's removal ghost of the outgoing dock
    /// surface — frozen at the dock's full size, top-left anchored — fading
    /// over the shrinking capsule: the "oversized boxes" filmed 2026-09-09.
    /// Held, the surface rides the capsule down under the pill's own fill and
    /// leaves sliver-sized, where its ghost matches the capsule exactly.
    @Published private(set) var dockHeld = false
    /// The peek dock's geometry (`PillDockMetrics`); the sandbox rescales it live.
    @Published private(set) var dock = PillDockMetrics()

    // MARK: Controller-facing mutation

    func apply(phase newPhase: DictationPillState) {
        guard phase != newPhase else { return }
        phase = newPhase
        // The recording meters are meaningless outside the recording toolbar.
        switch newPhase {
        case .recording, .saving: break
        default: if recordingLevels != .zero { recordingLevels = .zero }
        }
        // The meter is meaningless outside `.listening`; zero it so a re-shown
        // pill never flashes the last frame of the previous session.
        if case .listening = newPhase { return }
        if level != 0 { level = 0 }
    }

    func apply(edge newEdge: PillGeometry.Edge) {
        if edge != newEdge { edge = newEdge }
    }

    func apply(flat newFlat: Bool) {
        if flat != newFlat { flat = newFlat }
    }

    func apply(pointer newPointer: CGPoint?) {
        if pointer != newPointer { pointer = newPointer }
    }

    func apply(offset newOffset: CGSize) {
        if offset != newOffset { offset = newOffset }
    }

    func apply(labelWidth width: CGFloat?) {
        if labelWidth != width { labelWidth = width }
    }

    func apply(capsuleSize size: CGSize) {
        if capsuleSize != size { capsuleSize = size }
    }

    func apply(beat kind: MotionBeat.Kind) {
        beat = MotionBeat(kind: kind, id: beat.id &+ 1)
    }

    func apply(hovered on: Bool) {
        if hovered != on { hovered = on }
    }

    func apply(peeking on: Bool) {
        if peeking != on { peeking = on }
    }

    func apply(menuOpen on: Bool) {
        if menuOpen != on { menuOpen = on }
    }

    func apply(dockHeld on: Bool) {
        if dockHeld != on { dockHeld = on }
    }

    func apply(dock metrics: PillDockMetrics) {
        if dock != metrics { dock = metrics }
    }

    func apply(level newLevel: Double) {
        let clamped = newLevel.isFinite ? min(max(newLevel, 0), 1) : 0
        // 20 Hz updates: skip sub-pixel churn so SwiftUI is not re-laid-out for
        // an invisible change.
        guard abs(clamped - level) > 0.005 || (clamped == 0 && level != 0) else { return }
        level = clamped
    }

    /// Already normalized + smoothed by `DictationPillController`. Same 20 Hz
    /// churn guard as `apply(level:)`: a sub-pixel change must not re-lay the
    /// toolbar out.
    func apply(recordingLevels newLevels: AudioLevels) {
        let mic = clampUnit(newLevels.mic)
        let system = clampUnit(newLevels.system)
        let changed = abs(mic - recordingLevels.mic) > 0.005
            || abs(system - recordingLevels.system) > 0.005
            || (mic == 0 && system == 0 && recordingLevels != .zero)
        guard changed else { return }
        recordingLevels = AudioLevels(mic: mic, system: system)
    }

    private func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// What kind of move the capsule is making, for the view's choreography.
struct MotionBeat: Equatable {
    enum Kind: Equatable {
        /// Out of the edge into an active phase.
        case rise
        /// Back into the edge.
        case sink
        /// Phase-to-phase in place (listening → transcribing → …).
        case morph
        /// The resting pill pulled out (or released) by the pointer.
        case peek
    }
    var kind: Kind
    var id: Int
}
