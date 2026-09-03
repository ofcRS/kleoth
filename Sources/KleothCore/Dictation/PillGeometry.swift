import CoreGraphics
import Foundation

/// Where the user parked the dictation pill, stored as *fractions* of the
/// screen's `visibleFrame` rather than absolute points so the pill lands in the
/// same visual spot when a display's resolution, scaling, or menu-bar/Dock
/// insets change.
///
/// Persisted as JSON in `UserDefaults` under
/// `DictationPillController.placementDefaultsKey`
/// (`dev.kleoth.dictation.pillPlacement`). Restoring resolves the display by
/// `displayId` (`NSScreenNumber`) first, then by name + `visibleFrame` size, and
/// falls back to `PillGeometry.defaultOrigin` on the screen under the mouse.
///
/// Naming note: `displayId`, not `displayID` — the project's snake_case
/// round-trip rule bans all-caps acronym suffixes on stored keys.
public struct PillPlacement: Codable, Equatable, Sendable {
    /// `NSScreenNumber` of the display the pill was dropped on.
    public var displayId: UInt32
    /// `NSScreen.localizedName`, used to re-find a display whose id changed
    /// (replug, different port).
    public var displayName: String
    /// The `visibleFrame` size the fractions were measured against.
    public var visibleWidth: Double
    public var visibleHeight: Double
    /// Panel center as a fraction of `visibleFrame` width (0 = left edge).
    public var relativeCenterX: Double
    /// Panel center as a fraction of `visibleFrame` height, **0 = bottom**
    /// (Cocoa's y-up screen coordinates).
    public var relativeCenterY: Double

    public init(
        displayId: UInt32,
        displayName: String,
        visibleWidth: Double,
        visibleHeight: Double,
        relativeCenterX: Double,
        relativeCenterY: Double
    ) {
        self.displayId = displayId
        self.displayName = displayName
        self.visibleWidth = visibleWidth
        self.visibleHeight = visibleHeight
        self.relativeCenterX = relativeCenterX
        self.relativeCenterY = relativeCenterY
    }
}

/// Pure placement + level math for the dictation pill.
///
/// This lives in `KleothCore` — not in the app target — for one reason: the app
/// package has no test target, so every decision the pill makes that can be
/// checked without a screen belongs here (same rationale as
/// `DictationChordMachine` and `PasteboardPolicy`). All coordinates are Cocoa
/// screen coordinates: y grows **upward**, `origin` is the panel's bottom-left
/// corner, and `panelSize` is the whole `NSPanel` — including the transparent
/// shadow margin the SwiftUI capsule draws inside.
public enum PillGeometry {
    /// Minimum gap between the panel rect and the edge of `visibleFrame`. The
    /// visible capsule sits a further `shadowPadding` inside that.
    public static let edgeMargin: CGFloat = 8
    /// Default distance from the bottom of `visibleFrame` to the bottom of the
    /// *capsule* (not the panel) — high enough to clear the Dock.
    public static let defaultBottomInset: CGFloat = 96
    /// Meter shaping exponent. > 1 so room tone near the −55 dBFS floor stays
    /// visually quiet and speech still swings the bars.
    public static let levelGamma: Double = 1.4

    // MARK: Placement

    /// Bottom-center of `visibleFrame`, with the capsule's bottom edge
    /// `defaultBottomInset` above the bottom of the screen's visible area.
    /// `shadowPadding` is the transparent margin the panel carries around the
    /// capsule, so it is subtracted from the y inset.
    public static func defaultOrigin(
        panelSize: CGSize,
        shadowPadding: CGFloat,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.minY + defaultBottomInset - shadowPadding
        return clamp(CGPoint(x: x, y: y), panelSize: panelSize, in: visibleFrame)
    }

    /// Resolves a saved placement against the *current* `visibleFrame`. Corrupt
    /// or out-of-range fractions can never push the pill off-screen: the result
    /// is always clamped.
    public static func origin(
        for placement: PillPlacement,
        panelSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let fractionX = sanitizedFraction(placement.relativeCenterX)
        let fractionY = sanitizedFraction(placement.relativeCenterY)
        let centerX = visibleFrame.minX + CGFloat(fractionX) * visibleFrame.width
        let centerY = visibleFrame.minY + CGFloat(fractionY) * visibleFrame.height
        let origin = CGPoint(x: centerX - panelSize.width / 2, y: centerY - panelSize.height / 2)
        return clamp(origin, panelSize: panelSize, in: visibleFrame)
    }

    /// Captures the panel's current position as screen-relative fractions.
    /// Round-trips with `origin(for:panelSize:in:)` for any origin already
    /// inside the clamp bounds.
    public static func placement(
        origin: CGPoint,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        displayId: UInt32,
        displayName: String
    ) -> PillPlacement {
        let width = visibleFrame.width > 0 ? visibleFrame.width : 1
        let height = visibleFrame.height > 0 ? visibleFrame.height : 1
        let centerX = origin.x + panelSize.width / 2
        let centerY = origin.y + panelSize.height / 2
        return PillPlacement(
            displayId: displayId,
            displayName: displayName,
            visibleWidth: Double(visibleFrame.width),
            visibleHeight: Double(visibleFrame.height),
            relativeCenterX: Double((centerX - visibleFrame.minX) / width),
            relativeCenterY: Double((centerY - visibleFrame.minY) / height)
        )
    }

    /// Keeps the whole panel inside `visibleFrame` with `edgeMargin` to spare.
    /// Idempotent; when the panel is larger than the available area it pins to
    /// the lower-left bound rather than producing an inverted range.
    public static func clamp(_ origin: CGPoint, panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let lowerX = visibleFrame.minX + edgeMargin
        let upperX = visibleFrame.maxX - edgeMargin - panelSize.width
        let lowerY = visibleFrame.minY + edgeMargin
        let upperY = visibleFrame.maxY - edgeMargin - panelSize.height
        return CGPoint(
            x: pin(origin.x, lower: lowerX, upper: upperX),
            y: pin(origin.y, lower: lowerY, upper: upperY)
        )
    }

    // MARK: Level

    /// RMS amplitude (0…1) → meter level (0…1). Below `floorDecibels` the meter
    /// reads 0; full scale reads 1. Never returns NaN, even for a NaN/negative
    /// sample (silence is the safe answer for a UI meter).
    public static func normalizedLevel(rms: Float, floorDecibels: Double = -55) -> Double {
        let amplitude = Double(rms)
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let floor = (floorDecibels.isFinite && floorDecibels < 0) ? floorDecibels : -55
        let decibels = 20 * log10(min(amplitude, 1))
        guard decibels.isFinite, decibels > floor else { return 0 }
        let linear = (decibels - floor) / (0 - floor)
        let shaped = pow(min(max(linear, 0), 1), levelGamma)
        guard shaped.isFinite else { return 0 }
        return min(max(shaped, 0), 1)
    }

    /// One-pole smoother for the 20 Hz level poll: jumps toward a louder target
    /// (`attack`) and eases back from a quieter one (`release`), so the bars
    /// feel responsive without flickering. Never returns NaN.
    public static func smoothLevel(
        previous: Double,
        target: Double,
        attack: Double = 0.6,
        release: Double = 0.25
    ) -> Double {
        let start = clampUnit(previous)
        let goal = clampUnit(target)
        let rawCoefficient = goal > start ? attack : release
        let coefficient = clampUnit(rawCoefficient)
        return clampUnit(start + (goal - start) * coefficient)
    }

    // MARK: Helpers

    private static func pin(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }

    private static func sanitizedFraction(_ value: Double) -> Double {
        // A non-finite fraction (a hand-edited or truncated defaults blob)
        // becomes "centered"; out-of-range values survive here and are handled
        // by the clamp, which is the single place edges are enforced.
        value.isFinite ? value : 0.5
    }

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
