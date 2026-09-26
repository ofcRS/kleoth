import SwiftUI
import AppKit
import KleothCore

/// The entries of the cover menu (design 2026-09-24 §3.5; plan 2026-09-25
/// `## Design` 4), wording unchanged from the old header tile: a failure line
/// and Try Again first; with a picture, its style · engine line, New Cover ▸,
/// Remove Cover and Show in Finder; without one, "Skipped…" when the scene
/// step said so, then Draw Cover ▸. One view, three doors: the band's
/// right-click, its corner button, and the header chip.
///
/// Every entry that changes a cover is disabled while there is no engine: a
/// demo launch shows its folder's pictures with Covers Off, and nothing can be
/// drawn or removed there, so no film shows a live-looking item that does
/// nothing. Show in Finder only reads, so it stays enabled.
struct MeetingCoverMenuItems: View {
    @EnvironmentObject private var covers: CoverController

    let meeting: RecentMeeting
    /// Whether the page has loaded a summary. The scene is written from the
    /// summary, never the transcript, so Draw Cover needs one.
    let hasSummary: Bool
    /// The meeting's `cover.json`, read once by the caller.
    let record: CoverRecord?

    var body: some View {
        let isBusy = covers.isBusy(meeting.directory)
        let canDraw = covers.engine != nil
        // A queued Try Again keeps its old failure until its job starts; the
        // spinner wins, so no stale line or a second Try Again meanwhile.
        let failure = isBusy ? nil : covers.failure(for: meeting.directory)

        if let failure {
            Text(failure)
            Button("Try Again") { covers.draw([meeting]) }
                .disabled(!canDraw)
            Divider()
        }
        if let picture = meeting.coverImageURL {
            Text(pictureLine)
            Menu("New Cover") { styleButtons(isBusy: isBusy) }
                .disabled(!canDraw)
            // Not while a cover job is queued or running: it would install
            // its picture over the `removed` record afterwards, undoing the
            // removal (and its guard against the automatic hook) at the
            // price of a paid call.
            Button("Remove Cover") { covers.remove(meeting) }
                .disabled(isBusy || !canDraw)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([picture]) }
        } else {
            if record?.state == .skipped {
                Text("Skipped: the meeting looked personal")
            }
            Menu("Draw Cover") { styleButtons(isBusy: isBusy) }
                .disabled(!hasSummary || !canDraw)
                .help(hasSummary ? "" : "Needs a summary")
        }
    }

    /// New Cover ▸ / Draw Cover ▸: an explicit pick wins over the Style
    /// setting, Automatic included (`CoverStyleChoice`). Disabled while this
    /// meeting's cover is being drawn: the controller would ignore it anyway.
    @ViewBuilder
    private func styleButtons(isBusy: Bool) -> some View {
        Button("Automatic Style") { covers.draw([meeting], style: .automatic) }
            .disabled(isBusy)
        ForEach(CoverStyle.allCases) { style in
            Button(style.displayName) { covers.draw([meeting], style: .fixed(style)) }
                .disabled(isBusy)
        }
    }

    /// "Illustration · OpenRouter" from `cover.json`. A picture the user
    /// dropped into the folder has no record naming either, so it says "Cover".
    private var pictureLine: String {
        let parts = [
            record?.style.flatMap(CoverStyle.init(rawValue:))?.displayName,
            record?.engine.flatMap(CoverEngine.init(rawValue:))?.displayName,
        ].compactMap { $0 }
        return parts.isEmpty ? "Cover" : parts.joined(separator: " · ")
    }
}

/// The cover across the top of the meeting page (plan 2026-09-25 `## Design`
/// 1, 3, 4): the picture cropped to a 2:1 band the width of the pane, sliding
/// slower than the page (`CoverHeroGeometry`), a click for the full-size
/// picture (the page's Quick Look panel), the cover menu on right-click and
/// behind the corner button. Shown only with a picture; `MeetingCoverChip`
/// covers every other state.
struct MeetingCoverBand: View {
    @EnvironmentObject private var covers: CoverController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let meeting: RecentMeeting
    let picture: URL
    /// The detail pane's width, which sets the band's height. The band itself
    /// spans the width it is offered, edge to edge (see `body`).
    let width: CGFloat
    let hasSummary: Bool
    /// False when the band is not inside a scroll view: `.scrollView` then has
    /// nothing to measure. The meeting page scrolls in every state, so it
    /// passes true.
    let parallax: Bool
    /// Set on click; `MeetingDetailView` shows it with `.quickLookPreview`.
    @Binding var previewURL: URL?

    /// One decode per picture, whatever the pane's width: the source is a
    /// 1024 px JPEG (ImageIO never scales a thumbnail past its source), and a
    /// 2× pane up to 1024 pt wide gets every pixel. A size that followed the
    /// width would decode again at every step of a live resize, each step a
    /// new cache key.
    private static let bandPixelSize = 2048

    var body: some View {
        let height = CoverHeroGeometry.bandHeight(forWidth: width)
        let pictureHeight = CoverHeroGeometry.pictureHeight(bandHeight: height)
        // Not in a scroll view, or Reduce Motion on: `CoverHeroGeometry` then
        // returns no offset and no stretch (its rule is the only gate).
        let still = !parallax || reduceMotion
        let isBusy = covers.isBusy(meeting.directory)
        let record = covers.record(for: meeting.directory)
        // Through the same cache the rows use — the key carries the mtime,
        // so New Cover is a new key.
        let image = CoverThumbnailCache.thumbnail(
            url: picture, modifiedAt: meeting.coverModifiedAt, pixelSize: Self.bandPixelSize)

        // The band takes the width it is offered — the scroll content's, which
        // a legacy scroller ("Show scroll bars: Always") makes narrower than
        // the pane — and only its height comes from the pane's width. The
        // picture rides on it as an overlay, so it can never widen the page.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        // At least the band's width (fill) and taller than the
                        // band by the reveal on each side, centred on it, so the
                        // slide below never uncovers the background — whatever the
                        // picture's aspect (a dropped-in `cover.png` need not be square).
                        .frame(height: pictureHeight)
                        // The picture's own top sits `reveal` above the band's, so
                        // the band's minY is the picture's plus the reveal.
                        .visualEffect { content, proxy in
                            content.offset(y: CoverHeroGeometry.pictureOffset(
                                minY: proxy.frame(in: .scrollView).minY + CoverHeroGeometry.reveal, reduceMotion: still))
                        }
                } else {
                    // The file is there but unreadable (a damaged drop-in, or it
                    // went to the Trash between the list reload and this render):
                    // a quiet band, and the menu still offers Remove Cover.
                    Color.primary.opacity(0.06)
                }
            }
            .clipped()
            // Pulled past the top: grow about the bottom edge to fill the gap.
            .visualEffect { content, proxy in
                content.scaleEffect(CoverHeroGeometry.stretchScale(
                    minY: proxy.frame(in: .scrollView).minY, bandHeight: height, reduceMotion: still), anchor: .bottom)
            }
            .contentShape(Rectangle())
            .onTapGesture { previewURL = picture }
            // The picture is one button to VoiceOver, with the click's action;
            // the corner `…` button (the overlay below) stays its own element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Meeting cover, show full size")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { previewURL = picture }
            .contextMenu { MeetingCoverMenuItems(meeting: meeting, hasSummary: hasSummary, record: record) }
            .overlay(alignment: .bottomTrailing) { cornerControls(isBusy: isBusy, record: record) }
            // The tooltip is the scene that was sent (§3.5).
            .help(record?.scene ?? "")
    }

    /// Bottom-trailing: the "Drawing a new cover…" capsule while a New Cover
    /// runs (the old picture stays until the new one is saved; no full wash
    /// over a band this size), and the `…` button that opens the menu for
    /// people who don't right-click.
    @ViewBuilder
    private func cornerControls(isBusy: Bool, record: CoverRecord?) -> some View {
        HStack(spacing: KleothMetrics.spacingS) {
            if isBusy {
                HStack(spacing: KleothMetrics.spacingXS) {
                    ProgressView().controlSize(.small)
                    Text("Drawing a new cover…").font(.caption)
                }
                .padding(.horizontal, KleothMetrics.spacingS)
                .padding(.vertical, KleothMetrics.spacingXS)
                .background(.regularMaterial, in: Capsule())
            }
            Menu {
                MeetingCoverMenuItems(meeting: meeting, hasSummary: hasSummary, record: record)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
            }
            // Not `.borderlessButton`: an `NSPopUpButton` keeps only a label's
            // text or image and dropped the old tile (probed on macOS 26);
            // `.button` + `.plain` draws the SwiftUI label as it is.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Cover options")
            .accessibilityLabel("Cover options")
        }
        .padding(KleothMetrics.spacingM)
    }
}

/// The header's cover control when the meeting has no picture (plan
/// 2026-09-25 `## Design` 4, 6): a chip that opens the cover menu, worded by
/// state — "Draw Cover", "No cover" (the scene step skipped it), "Cover
/// failed" — or a spinner chip while one is drawn. Nothing without a summary:
/// there is nothing to draw from, and the "No summary yet" pill beside it
/// already says so (a deviation from §3.5's disabled item with a tooltip).
/// Nothing either while Covers is Off (`engine` nil, a demo launch included):
/// nothing can be drawn there (plan `## Design` 6).
struct MeetingCoverChip: View {
    @EnvironmentObject private var covers: CoverController

    let meeting: RecentMeeting
    let hasSummary: Bool

    var body: some View {
        let isBusy = covers.isBusy(meeting.directory)
        let failure = isBusy ? nil : covers.failure(for: meeting.directory)
        let record = covers.record(for: meeting.directory)
        let skipped = record?.state == .skipped

        if covers.engine == nil {
            // Covers Off has nothing to draw with; the band still shows a
            // picture that is already there (`showsCovers`).
            EmptyView()
        } else if isBusy {
            HStack(spacing: KleothMetrics.spacingXS) {
                ProgressView().controlSize(.mini)
                Text("Drawing cover…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, KleothMetrics.spacingS)
            .padding(.vertical, KleothMetrics.spacingXS)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Meeting cover")
            .accessibilityValue("Drawing cover")
        } else if hasSummary {
            Menu {
                MeetingCoverMenuItems(meeting: meeting, hasSummary: hasSummary, record: record)
            } label: {
                if failure != nil {
                    KleothPill("Cover failed", systemImage: "exclamationmark.triangle", tint: KleothPalette.pendingTint)
                } else if skipped {
                    KleothPill("No cover", systemImage: "paintpalette")
                } else {
                    KleothPill("Draw Cover", systemImage: "paintpalette")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(failure ?? (skipped ? "Skipped: the meeting looked personal" : "Draw a cover for this meeting"))
            // The state is spoken, not only the control's name.
            .accessibilityLabel("Meeting cover")
            .accessibilityValue(failure != nil ? "Cover failed" : (skipped ? "No cover" : "Draw Cover"))
        }
    }
}
