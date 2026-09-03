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
    /// The screen edge the resting capsule is tucked into. The view rotates
    /// the `.idle` capsule to lie along a side edge (a vertical tab) and points
    /// its sheen inward; set by the controller before the phase changes.
    @Published private(set) var restingEdge: PillGeometry.Edge = .bottom

    // MARK: Controller-facing mutation

    func apply(phase newPhase: DictationPillState) {
        guard phase != newPhase else { return }
        phase = newPhase
        // The meter is meaningless outside `.listening`; zero it so a re-shown
        // pill never flashes the last frame of the previous session.
        if case .listening = newPhase { return }
        if level != 0 { level = 0 }
    }

    func apply(restingEdge edge: PillGeometry.Edge) {
        if restingEdge != edge { restingEdge = edge }
    }

    func apply(level newLevel: Double) {
        let clamped = newLevel.isFinite ? min(max(newLevel, 0), 1) : 0
        // 20 Hz updates: skip sub-pixel churn so SwiftUI is not re-laid-out for
        // an invisible change.
        guard abs(clamped - level) > 0.005 || (clamped == 0 && level != 0) else { return }
        level = clamped
    }
}
