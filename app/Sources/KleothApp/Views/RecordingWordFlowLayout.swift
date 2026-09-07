import SwiftUI

/// Lays word views out like running text: left to right, wrapping at the
/// proposed width, with an optional forced break before any child.
///
/// `KleothFlowLayout` (KleothTheme) does the same job for a handful of metadata
/// chips, but a transcript is a different animal — hundreds to thousands of
/// children, re-measured on every pass — so this one caches each child's
/// intrinsic size and the resolved positions, and only recomputes when the
/// subviews or the proposed width actually change. It also understands a
/// paragraph break, which chips never need.
///
/// A child opts into a break with `.recordingParagraphBreak(true)`; the
/// transcript sets it where the silence between two words exceeds
/// `RecordingTranscriptView.paragraphGapSeconds`, so a pause reads as a
/// paragraph instead of one endless run of words.
struct WordFlowLayout: Layout {
    /// Gap between words on a line. Small — the words already carry their own
    /// horizontal padding for the highlight capsule.
    var spacing: CGFloat = 1
    /// Gap between wrapped lines of the same paragraph.
    var lineSpacing: CGFloat = 4
    /// Extra gap above a forced break, on top of `lineSpacing`.
    var paragraphSpacing: CGFloat = 10

    struct Cache {
        var sizes: [CGSize] = []
        var breaks: [Bool] = []
        /// Width the memoized `positions`/`size` were resolved against; `nil`
        /// until the first pass.
        var resolvedWidth: CGFloat?
        var positions: [CGPoint] = []
        var size: CGSize = .zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            breaks: subviews.map { $0[ParagraphBreakLayoutValue.self] }
        )
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.breaks = subviews.map { $0[ParagraphBreakLayoutValue.self] }
        cache.resolvedWidth = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        resolve(width: proposal.width ?? .infinity, cache: &cache)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        resolve(width: bounds.width, cache: &cache)
        for index in subviews.indices where cache.positions.indices.contains(index) {
            let origin = cache.positions[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(cache.sizes[index])
            )
        }
    }

    /// Runs the wrap once per (subviews, width) pair and memoizes the result —
    /// SwiftUI calls `sizeThatFits` and `placeSubviews` with the same width on
    /// every pass, and a transcript is far too many children to lay out twice.
    private func resolve(width proposedWidth: CGFloat, cache: inout Cache) {
        let width = proposedWidth > 0 ? proposedWidth : .infinity
        if let resolved = cache.resolvedWidth, abs(resolved - width) < 0.5 { return }

        var positions: [CGPoint] = []
        positions.reserveCapacity(cache.sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for index in cache.sizes.indices {
            let size = cache.sizes[index]
            let forcedBreak = cache.breaks.indices.contains(index) && cache.breaks[index]
            // Wrap when the child would overflow, or when it asked for a break.
            // `x > 0` keeps a single over-wide word (or a leading break) from
            // producing an empty first line.
            if x > 0, forcedBreak || x + size.width > width {
                contentWidth = max(contentWidth, x - spacing)
                x = 0
                y += lineHeight + lineSpacing + (forcedBreak ? paragraphSpacing : 0)
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        contentWidth = max(contentWidth, x - spacing)

        cache.positions = positions
        // Claim the full proposed width so the paragraph fills its pane and
        // left-aligns; fall back to the measured width when nothing was proposed.
        cache.size = CGSize(
            width: width.isFinite ? width : max(0, contentWidth),
            height: y + lineHeight
        )
        cache.resolvedWidth = width
    }
}

/// Per-child flag read by `WordFlowLayout`: start a new paragraph before me.
private struct ParagraphBreakLayoutValue: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Marks this child as the start of a new paragraph inside a
    /// `WordFlowLayout`. No effect in any other layout.
    func recordingParagraphBreak(_ startsParagraph: Bool) -> some View {
        layoutValue(key: ParagraphBreakLayoutValue.self, value: startsParagraph)
    }
}
