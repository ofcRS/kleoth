import Testing
import Foundation
import CoreGraphics
@testable import KleothCore

/// Capture geometry (design §3.1, §5.2, §5.4). Three separate coordinate
/// systems meet here — AppKit points with a bottom-left origin, display-local
/// points with a TOP-left origin, and output pixels — so every conversion is a
/// pure function with a test rather than an inline subtraction at a call site.
@Suite struct CaptureGeometryTests {
    private let cap = ScreenRecordingDefaults.maxLongEdgePixels

    // MARK: - outputPixelSize

    /// The Retina cases the design names by hand. Everything is capped at a
    /// 1920 long edge, which also dodges the AVAssetWriter 4096×2304 ceiling.
    @Test func retinaDisplaysDownscaleToTheLongEdgeCap() {
        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 2880, height: 1800), pointPixelScale: 2, maxLongEdge: cap
        ) == CGSize(width: 1920, height: 1200))

        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 1440, height: 900), pointPixelScale: 2, maxLongEdge: cap
        ) == CGSize(width: 1920, height: 1200))

        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 1280, height: 720), pointPixelScale: 2, maxLongEdge: cap
        ) == CGSize(width: 1920, height: 1080))
    }

    /// Under the cap nothing is scaled — a small region keeps its native pixels
    /// instead of being blown up.
    @Test func smallSourcesAreNotUpscaled() {
        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 640, height: 360), pointPixelScale: 2, maxLongEdge: cap
        ) == CGSize(width: 1280, height: 720))

        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 800, height: 600), pointPixelScale: 1, maxLongEdge: cap
        ) == CGSize(width: 800, height: 600))
    }

    /// H.264 rejects odd dimensions (AVVideoSettings.h:65). Rounding DOWN is the
    /// deliberate direction: it never invents a pixel column that has no source.
    @Test func oddDimensionsRoundDownToEven() {
        let size = CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 1001, height: 501), pointPixelScale: 1, maxLongEdge: cap
        )
        #expect(size == CGSize(width: 1000, height: 500))

        // A cap-driven scale that lands on fractions rounds down on both axes.
        let scaled = CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 1333, height: 999), pointPixelScale: 2, maxLongEdge: cap
        )
        #expect(Int(scaled.width) % 2 == 0)
        #expect(Int(scaled.height) % 2 == 0)
        #expect(scaled.width == 1920)
    }

    /// The long edge lands exactly on the cap; only the SHORT edge carries the
    /// division, and `evenFloor` may take at most 2 px off it. Measuring the
    /// drift on the long edge instead would multiply that floor by the aspect
    /// ratio (2.39:1 ultrawide → 4.8 px) and say nothing extra.
    @Test func aspectRatioSurvivesTheCapAndTheEvenRounding() {
        let cases: [(CGSize, CGFloat)] = [
            (CGSize(width: 2880, height: 1800), 2),
            (CGSize(width: 1512, height: 982), 2),      // 14" MacBook Pro
            (CGSize(width: 1728, height: 1117), 2),     // 16" MacBook Pro
            (CGSize(width: 1333, height: 999), 2),
            (CGSize(width: 3440, height: 1440), 1),     // ultrawide, non-Retina
            (CGSize(width: 1200, height: 2000), 2),     // portrait: the cap lands on the height
        ]
        for (points, scale) in cases {
            let out = CaptureGeometry.outputPixelSize(sourcePoints: points, pointPixelScale: scale, maxLongEdge: cap)
            let pixels = CGSize(width: points.width * scale, height: points.height * scale)
            let expectedScale = CGFloat(cap) / max(pixels.width, pixels.height)

            // The long edge is exactly the cap — never one or two pixels short.
            #expect(max(out.width, out.height) == CGFloat(cap), "long edge missed the cap for \(points): \(out)")
            // The short edge is the exact value, floored to even.
            let exactShort = min(pixels.width, pixels.height) * expectedScale
            #expect(abs(min(out.width, out.height) - exactShort) <= 2,
                    "short edge drifted for \(points): \(out) (exact \(exactShort))")
            #expect(Int(out.width) % 2 == 0 && Int(out.height) % 2 == 0)
        }
    }

    /// A degenerate source (a zero-width window, a display that reported
    /// nothing) must not produce a NaN writer configuration.
    @Test func degenerateSourcesAreRejected() {
        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: 0, height: 1080), pointPixelScale: 2, maxLongEdge: cap
        ) == .zero)
        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: CGFloat.nan, height: 1080), pointPixelScale: 2, maxLongEdge: cap
        ) == .zero)
        #expect(CaptureGeometry.outputPixelSize(
            sourcePoints: CGSize(width: -100, height: -100), pointPixelScale: 2, maxLongEdge: cap
        ) == .zero)
    }

    // MARK: - sourceRect

    /// The built-in display sits at the origin, so the only thing that changes
    /// is the y flip: `y = displayFrame.maxY − rect.maxY`.
    @Test func sourceRectFlipsYOnTheMainDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let rect = CGRect(x: 100, y: 800, width: 400, height: 100)   // near the TOP in AppKit terms
        #expect(CaptureGeometry.sourceRect(fromGlobal: rect, displayFrame: display)
            == CGRect(x: 100, y: 82, width: 400, height: 100))
    }

    /// A secondary display to the LEFT of and BELOW the main one — the case
    /// where forgetting the display origin puts the capture on the wrong screen
    /// or off it entirely.
    @Test func sourceRectHandlesADisplayWithANegativeOrigin() {
        let display = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let rect = CGRect(x: -1800, y: 400, width: 640, height: 360)
        let local = CaptureGeometry.sourceRect(fromGlobal: rect, displayFrame: display)

        #expect(local.minX == rect.minX - display.minX)          // 120
        #expect(local.minY == display.maxY - rect.maxY)          // 780 - 760 = 20
        #expect(local == CGRect(x: 120, y: 20, width: 640, height: 360))
        // The result is display-local, so it must live inside the display's size.
        #expect(CGRect(origin: .zero, size: display.size).contains(local))
    }

    /// The whole display maps to the display's own bounds at the origin — the
    /// full-screen path must not be a special case at the call site.
    @Test func sourceRectOfTheWholeDisplayIsItsBounds() {
        let display = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        #expect(CaptureGeometry.sourceRect(fromGlobal: display, displayFrame: display)
            == CGRect(origin: .zero, size: display.size))
    }

    // MARK: - region

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var minimum: CGFloat { ScreenRecordingDefaults.minRegionPoints }

    /// A drag up-and-left is the same rectangle as a drag down-and-right.
    @Test func regionNormalizesAReversedDrag() {
        let forward = CaptureGeometry.region(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400), in: display, minimum: minimum
        )
        let reversed = CaptureGeometry.region(
            from: CGPoint(x: 500, y: 400), to: CGPoint(x: 100, y: 100), in: display, minimum: minimum
        )
        #expect(forward == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(forward == reversed)
    }

    /// A drag that runs off the edge (the pointer leaves the display) is clipped
    /// to the display rather than producing an out-of-bounds `sourceRect`.
    @Test func regionClampsToTheDisplay() {
        let region = CaptureGeometry.region(
            from: CGPoint(x: -200, y: -200), to: CGPoint(x: 2000, y: 2000), in: display, minimum: minimum
        )
        #expect(region == display)

        let partial = CaptureGeometry.region(
            from: CGPoint(x: 1200, y: 800), to: CGPoint(x: 2000, y: 2000), in: display, minimum: minimum
        )
        #expect(partial == CGRect(x: 1200, y: 800, width: 312, height: 182))
    }

    /// Under the minimum on EITHER side the answer is nil — the caller reads
    /// that as "the user meant the whole display", never as an error.
    @Test func regionRejectsAnythingUnderTheMinimumOnEitherSide() {
        #expect(CaptureGeometry.region(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 140, y: 400), in: display, minimum: minimum
        ) == nil)
        #expect(CaptureGeometry.region(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 140), in: display, minimum: minimum
        ) == nil)
        // A click with no drag at all.
        #expect(CaptureGeometry.region(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), in: display, minimum: minimum
        ) == nil)
        // Exactly the minimum is accepted.
        #expect(CaptureGeometry.region(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 100 + minimum, y: 100 + minimum),
            in: display, minimum: minimum
        ) == CGRect(x: 100, y: 100, width: minimum, height: minimum))
    }

    /// A drag entirely outside the display (a stale pointer on a display that
    /// just went away) clips to nothing, which must be nil and not a null rect.
    @Test func regionOutsideTheDisplayIsNil() {
        #expect(CaptureGeometry.region(
            from: CGPoint(x: 3000, y: 3000), to: CGPoint(x: 3400, y: 3400), in: display, minimum: minimum
        ) == nil)
    }

    /// Clamping happens before the minimum check: a big drag whose overlap with
    /// the display is a sliver is rejected, not silently shrunk to a 3 pt movie.
    @Test func regionAppliesTheMinimumAfterClamping() {
        #expect(CaptureGeometry.region(
            from: CGPoint(x: 1500, y: 100), to: CGPoint(x: 2500, y: 600), in: display, minimum: minimum
        ) == nil)
    }

    // MARK: - videoBitRate

    /// 3 Mbps is the 1080p reference (graft 1); 1920×1200 costs 11 % more pixels
    /// but is clamped back to the ceiling.
    @Test func bitRateIsThreeMegabitsAtAndAboveTenEightyP() {
        #expect(CaptureGeometry.videoBitRate(pixelSize: CGSize(width: 1920, height: 1080)) == 3_000_000)
        #expect(CaptureGeometry.videoBitRate(pixelSize: CGSize(width: 1920, height: 1200)) == 3_000_000)
        #expect(CaptureGeometry.videoBitRate(pixelSize: CGSize(width: 3840, height: 2160)) == 3_000_000)
    }

    /// Below 1080p the rate follows the PIXEL COUNT, not the long edge.
    @Test func bitRateScalesWithPixelCount() {
        let rate = CaptureGeometry.videoBitRate(pixelSize: CGSize(width: 1280, height: 720))
        #expect(rate == 1_333_333)
        // i.e. 4/9 of the reference, within rounding.
        #expect(abs(Double(rate) - 3_000_000.0 * 4.0 / 9.0) < 1)
    }

    /// A tiny region still gets a floor — a 200 kbps movie of a code editor is
    /// unreadable, and the file is small either way.
    @Test func bitRateHasAFloor() {
        #expect(CaptureGeometry.videoBitRate(pixelSize: CGSize(width: 640, height: 360))
            == ScreenRecordingDefaults.minimumVideoBitRate)
        #expect(CaptureGeometry.videoBitRate(pixelSize: CGSize(width: 128, height: 128))
            == ScreenRecordingDefaults.minimumVideoBitRate)
    }

    @Test func bitRateOfADegenerateSizeIsTheFloorNotACrash() {
        #expect(CaptureGeometry.videoBitRate(pixelSize: .zero) == ScreenRecordingDefaults.minimumVideoBitRate)
        #expect(CaptureGeometry.videoBitRate(pixelSize: CGSize(width: CGFloat.nan, height: 1080))
            == ScreenRecordingDefaults.minimumVideoBitRate)
    }
}
