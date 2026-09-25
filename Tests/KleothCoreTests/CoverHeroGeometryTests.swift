import Testing
import Foundation
import CoreGraphics
@testable import KleothCore

/// The meeting page's cover band (covers plan 2026-09-25 `## Design` 1): its
/// height for a pane width, the hidden picture above and below it, and how the
/// picture moves as the page scrolls. `minY` is the band's top edge relative to
/// the scroll view's visible top: 0 at rest, negative once scrolled, positive
/// when the page is pulled past its top.
@Suite struct CoverHeroGeometryTests {
    @Test func bandHeightIsHalfTheWidthClampedTo200And400() {
        #expect(CoverHeroGeometry.bandHeight(forWidth: 300) == 200)   // below the floor: the floor
        #expect(CoverHeroGeometry.bandHeight(forWidth: 440) == 220)   // the narrowest detail pane
        #expect(CoverHeroGeometry.bandHeight(forWidth: 600) == 300)
        #expect(CoverHeroGeometry.bandHeight(forWidth: 800) == 400)
        #expect(CoverHeroGeometry.bandHeight(forWidth: 1400) == 400)  // wide panes cap
    }

    @Test func pictureIsTallerThanTheBandByTheRevealOnEachSide() {
        #expect(CoverHeroGeometry.pictureHeight(bandHeight: 300) == 300 + 2 * CoverHeroGeometry.reveal)
        #expect(CoverHeroGeometry.reveal == 80)
    }

    @Test func pictureLagsThePageAndNeverSlidesPastTheReveal() {
        #expect(CoverHeroGeometry.pictureOffset(minY: 0, reduceMotion: false) == 0)
        #expect(CoverHeroGeometry.pictureOffset(minY: -100, reduceMotion: false) == 35)
        #expect(CoverHeroGeometry.pictureOffset(minY: -1_000, reduceMotion: false) == CoverHeroGeometry.reveal)
        // Pulled past the top: the stretch handles that, not the slide.
        #expect(CoverHeroGeometry.pictureOffset(minY: 60, reduceMotion: false) == 0)
    }

    @Test func bandStretchesOnlyWhenPulledPastTheTop() {
        #expect(CoverHeroGeometry.stretchScale(minY: 0, bandHeight: 300, reduceMotion: false) == 1)
        #expect(CoverHeroGeometry.stretchScale(minY: -100, bandHeight: 300, reduceMotion: false) == 1)
        #expect(CoverHeroGeometry.stretchScale(minY: 60, bandHeight: 300, reduceMotion: false) == 1.2)
        // A zero-height band can't divide.
        #expect(CoverHeroGeometry.stretchScale(minY: 60, bandHeight: 0, reduceMotion: false) == 1)
    }

    @Test func reduceMotionTurnsBothOff() {
        #expect(CoverHeroGeometry.pictureOffset(minY: -100, reduceMotion: true) == 0)
        #expect(CoverHeroGeometry.stretchScale(minY: 60, bandHeight: 300, reduceMotion: true) == 1)
    }
}
