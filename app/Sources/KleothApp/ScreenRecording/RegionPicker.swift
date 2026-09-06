import AppKit
import CoreGraphics
import Foundation

/// "What do you want to record?" — one transparent overlay window per display;
/// click a display to take all of it, drag to take a region, Esc / ⌘. to cancel
/// (design §3.4, §2.1).
///
/// **T0 STUB** — `Choice` is final (T5 and the geometry tests build on it);
/// `pick()` returns nil, i.e. "cancelled". T4 builds the overlays.
@MainActor
final class RegionPicker {
    struct Choice: Equatable {
        var displayID: CGDirectDisplayID
        /// The display's AppKit global frame (bottom-left origin).
        var displayFrame: CGRect
        /// The dragged rect in AppKit global points, or nil for the whole
        /// display. `CaptureGeometry.sourceRect(fromGlobal:displayFrame:)`
        /// turns it into the stream's display-local rect.
        var globalRect: CGRect?
    }

    /// nil = cancelled (Esc / ⌘. / the overlay lost key status).
    func pick() async -> Choice? {
        nil
    }
}
