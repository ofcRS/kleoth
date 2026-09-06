import AppKit
import Foundation
import KleothPillUI

/// The ONE owner of the pill instance (design §3.4).
///
/// `DictationController` and `ScreenRecordingController` each get a face onto
/// it: dictation phases are FOREGROUND, a running screen recording is the
/// BACKDROP underneath them. The coordinator merges the two backdrops and fans
/// the pill's actions out to whichever side owns them.
///
/// **T0 STUB** — the surface is final and the body is a 1:1 pass-through, so
/// nothing changes for dictation. It is also UNUSED in T0:
/// `DictationController`'s convenience init still builds its own
/// `DictationPillController`; T5 rewires it to `dictationFace` and fills in the
/// merge / queue / fan-out logic sketched below.
@MainActor
final class PillCoordinator {
    static let shared = PillCoordinator()

    /// The real pill (T5 moves the instance here from
    /// `DictationController.swift`'s convenience init).
    let pill: DictationPillController

    /// Handed to `DictationController`'s designated init as `pill:`. Forwards
    /// everything 1:1 today; T5 turns `setResting(_:)` into
    /// `dictationWantsResting = $0; recompute()` and routes the callbacks
    /// through the fan-out.
    private let face: DictationFace

    var dictationFace: any DictationPillPresenting { face }

    /// Start / stop / reveal / open-Settings from the pill. T5 wires this to
    /// `ScreenRecordingController`.
    var onRecordingAction: ((DictationPillAction) -> Void)?

    init(pill: DictationPillController = DictationPillController()) {
        self.pill = pill
        self.face = DictationFace(pill: pill)
    }

    // MARK: - Recording side (T5)

    /// Non-nil → `.recording(since:)` outranks `.idle` in `recompute()`.
    func setRecordingBackdrop(since: Date?) {
        _ = since
    }

    /// `.saving` / `.saved` / a recording `.warning` or `.failed`: applied now
    /// when no dictation phase is live, otherwise a `.saved` is queued (≤
    /// `savedConfirmationMaxDelay`) and anything else is dropped.
    func showRecordingPhase(_ state: DictationPillState) {
        _ = state
    }

    /// `pill.dismiss()` iff the current state is one the recording side put up.
    func dismissRecordingPhase() {}

    /// Whether a DICTATION phase currently owns the pill — the recording side
    /// must not overwrite one.
    var isDictationPhaseLive: Bool { false }
}

/// The `DictationPillPresenting` the dictation controller talks to. T0: a
/// transparent forwarder, so the dictation lane behaves exactly as it does
/// today.
@MainActor
private final class DictationFace: DictationPillPresenting {
    private let pill: DictationPillController

    init(pill: DictationPillController) {
        self.pill = pill
    }

    var onAction: ((DictationPillAction) -> Void)? {
        get { pill.onAction }
        set { pill.onAction = newValue }
    }

    var onDismiss: (() -> Void)? {
        get { pill.onDismiss }
        set { pill.onDismiss = newValue }
    }

    func show(_ state: DictationPillState) { pill.show(state) }
    func setLevel(_ level: Double) { pill.setLevel(level) }
    func dismiss() { pill.dismiss() }
    func setResting(_ visible: Bool) { pill.setResting(visible) }
    func resetPosition() { pill.resetPosition() }
}
