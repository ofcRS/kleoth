import CoreGraphics
import Foundation

/// The meeting page's cover band (plan 2026-09-25 `## Design` 1): how tall the
/// band is for the detail pane's width, how much taller the picture behind it
/// is, and how the picture moves as the page scrolls. Pure math, so the rules
/// are pinned by tests; `MeetingCoverBand` in the app applies them.
///
/// `minY` throughout is the band's top edge relative to the scroll view's
/// visible top (`GeometryProxy.frame(in: .scrollView).minY`): 0 at rest,
/// negative once the page has scrolled, positive while it is pulled past its
/// top (the rubber band).
public enum CoverHeroGeometry {
    /// Band width : height. A 2:1 band shows the middle half of a square cover,
    /// which keeps the "one clear focal scene, centred" the prompt asks for.
    public static let aspect: CGFloat = 2
    /// The narrowest detail pane (440 pt) still gets a band worth looking at.
    public static let minHeight: CGFloat = 200
    /// Wide panes stop here, so the band stays a readable header; past a 1,200 pt pane the
    /// crop is a little under a third of the square (1,400 pt shows 29 %).
    public static let maxHeight: CGFloat = 400
    /// Extra picture above and below the band, hidden at rest, that the
    /// parallax slides into — so the slide never uncovers a gap, whatever the
    /// picture's aspect (a dropped-in `cover.png` need not be square).
    public static let reveal: CGFloat = 80
    /// How much slower than the page the picture moves: 0 would pin it to the
    /// page (no parallax), 1 to the window.
    public static let parallax: CGFloat = 0.35

    /// The band's height for a pane `width` wide: `width / aspect`, clamped to `minHeight`...`maxHeight`.
    public static func bandHeight(forWidth width: CGFloat) -> CGFloat {
        min(maxHeight, max(minHeight, width / aspect))
    }

    /// The picture's height behind a band: the band plus the hidden `reveal` above and below.
    public static func pictureHeight(bandHeight: CGFloat) -> CGFloat {
        bandHeight + 2 * reveal
    }

    /// How far down, relative to the band, the picture sits once the page has
    /// scrolled: it lags the page by `parallax`, never past the hidden `reveal`.
    /// Nothing while at rest, pulled past the top, or under Reduce Motion.
    public static func pictureOffset(minY: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, minY < 0 else { return 0 }
        return min(reveal, -minY * parallax)
    }

    /// The band's scale about its bottom edge while the page is pulled past its
    /// top, so the picture fills the gap instead of leaving window background
    /// above it. 1 otherwise, and always under Reduce Motion. No cap here: how
    /// far the page can be pulled, and so how big the scale gets, is bounded by
    /// the scroll view's rubber band, not by this function.
    public static func stretchScale(minY: CGFloat, bandHeight: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, minY > 0, bandHeight > 0 else { return 1 }
        return 1 + minY / bandHeight
    }
}
