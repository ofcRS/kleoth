import Foundation

/// Pure capture geometry: points → pixels, AppKit ↔ display-local coordinates,
/// the long-edge cap, even rounding, and the bit-rate policy (design §3.1).
///
/// It lives in KleothCore for the same reason `PillGeometry` does: the app
/// package has no test target, so every decision that can be a pure function is
/// one.
public enum CaptureGeometry {
    /// Output size in PIXELS for a source measured in points.
    ///
    /// Source points × `pointPixelScale`, then the long edge capped at
    /// `maxLongEdge` (aspect preserved), then BOTH dimensions rounded **down**
    /// to an even number — H.264 rejects odd dimensions
    /// (AVVideoSettings.h:65) and rounding down never invents pixels.
    ///
    /// 2880×1800 pt @2 → 1920×1200 · 1440×900 pt @2 → 1920×1200 (cap) ·
    /// 1280×720 pt @2 → 1920×1080 · 640×360 pt @2 → 1280×720 (under the cap).
    public static func outputPixelSize(sourcePoints: CGSize, pointPixelScale: CGFloat, maxLongEdge: Int) -> CGSize {
        let width = sourcePoints.width * pointPixelScale
        let height = sourcePoints.height * pointPixelScale
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return .zero }

        let cap = CGFloat(max(2, maxLongEdge))
        let longEdge = max(width, height)
        guard longEdge > cap else {
            return CGSize(width: evenFloor(width), height: evenFloor(height))
        }

        // Snap the long edge to the cap EXACTLY rather than trusting
        // `longEdge * (cap / longEdge)` to come back as `cap`: at 2666 → 1920
        // the round trip lands on 1919.999…, which `evenFloor` then turns into
        // 1918 — a two-pixel dent in every capped capture. The short side is
        // the only one that carries the division.
        let scale = cap / longEdge
        let capped = width >= height
            ? CGSize(width: cap, height: height * scale)
            : CGSize(width: width * scale, height: cap)

        return CGSize(width: evenFloor(capped.width), height: evenFloor(capped.height))
    }

    /// AppKit global rect (bottom-left origin, y up) → `SCStream.sourceRect`
    /// (display-local, TOP-left origin, points — SCStream.h:269).
    ///
    /// `x = r.minX − s.minX`, `y = s.maxY − r.maxY`. Works for a secondary
    /// display with a negative origin, which is the whole reason it is a
    /// function and not two inline subtractions.
    public static func sourceRect(fromGlobal rect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - displayFrame.minX,
            y: displayFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// A drag normalized (either direction) and clamped to the display it was
    /// made on. `nil` when either side is under `minimum` — the caller reads
    /// that as "the user meant the whole display", never as an error.
    public static func region(from dragStart: CGPoint, to end: CGPoint, in displayFrame: CGRect, minimum: CGFloat) -> CGRect? {
        let normalized = CGRect(
            x: min(dragStart.x, end.x),
            y: min(dragStart.y, end.y),
            width: abs(end.x - dragStart.x),
            height: abs(end.y - dragStart.y)
        )
        let clamped = normalized.intersection(displayFrame)
        guard !clamped.isNull, clamped.width >= minimum, clamped.height >= minimum else { return nil }
        return clamped
    }

    /// `videoBitRateAt1080p × (w·h / (1920·1080))`, clamped to
    /// `[minimumVideoBitRate, videoBitRateAt1080p]` (graft 1). Pixel count, not
    /// long edge: a 1920×1200 capture is not 11 % more expensive than 1080p in
    /// any way the user would notice, and the clamp keeps the ceiling honest.
    public static func videoBitRate(pixelSize: CGSize) -> Int {
        let reference = 1920.0 * 1080.0
        let pixels = Double(pixelSize.width) * Double(pixelSize.height)
        guard pixels > 0, pixels.isFinite else { return ScreenRecordingDefaults.minimumVideoBitRate }
        let scaled = Double(ScreenRecordingDefaults.videoBitRateAt1080p) * (pixels / reference)
        let clamped = min(
            Double(ScreenRecordingDefaults.videoBitRateAt1080p),
            max(Double(ScreenRecordingDefaults.minimumVideoBitRate), scaled)
        )
        return Int(clamped.rounded())
    }

    // MARK: - Internals

    /// Largest even integer ≤ `value`, never below 2.
    private static func evenFloor(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}
