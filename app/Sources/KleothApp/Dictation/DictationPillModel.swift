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
    /// Drives the spring-in / fade-out. Set *after* the panel is on screen so
    /// SwiftUI has a state change to animate.
    @Published var isPresented: Bool = false
    /// The screen edge the pill lives on. A side edge stands the capsule up
    /// (the view rotates it ±90° in EVERY phase, so a pill parked on the left
    /// is a vertical bar that reads bottom-to-top) and turns the resting sheen
    /// so its bright end faces into the screen.
    @Published private(set) var edge: PillGeometry.Edge = .bottom
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

    // MARK: Controller-facing mutation

    func apply(phase newPhase: DictationPillState) {
        guard phase != newPhase else { return }
        phase = newPhase
        // The meter is meaningless outside `.listening`; zero it so a re-shown
        // pill never flashes the last frame of the previous session.
        if case .listening = newPhase { return }
        if level != 0 { level = 0 }
    }

    func apply(edge newEdge: PillGeometry.Edge) {
        if edge != newEdge { edge = newEdge }
    }

    func apply(offset newOffset: CGSize) {
        if offset != newOffset { offset = newOffset }
    }

    func apply(labelWidth width: CGFloat?) {
        if labelWidth != width { labelWidth = width }
    }

    func apply(level newLevel: Double) {
        let clamped = newLevel.isFinite ? min(max(newLevel, 0), 1) : 0
        // 20 Hz updates: skip sub-pixel churn so SwiftUI is not re-laid-out for
        // an invisible change.
        guard abs(clamped - level) > 0.005 || (clamped == 0 && level != 0) else { return }
        level = clamped
    }
}
