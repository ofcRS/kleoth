import SwiftUI
import AppKit
import ImageIO
import KleothCore

/// ImageIO thumbnails of meeting covers, keyed by path + mtime + pixel size
/// (design doc 2026-09-24 §4.4). A cover is a ~1024 px JPEG and a History row
/// shows it at 40 pt, so decoding the full picture for every row would be
/// wasted work; `CGImageSourceCreateThumbnailAtIndex` decodes straight to the
/// size asked for. The mtime is in the key because New Cover writes the same
/// `cover.jpg` path: a new picture is a new key, never a stale hit.
///
/// Main-actor only: tiles ask from `body`, and `NSCache` / `NSImage` are not
/// `Sendable`. `NSCache` evicts on its own under memory pressure.
@MainActor
enum CoverThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// The picture at `url` scaled to fit `pixelSize` pixels on its long side,
    /// or nil when it can't be read (a file trashed before the list reloaded,
    /// a damaged drop-in). A miss is not cached, so a later render retries.
    static func thumbnail(url: URL, modifiedAt: Date?, pixelSize: Int) -> NSImage? {
        let key = "\(url.path)|\(modifiedAt?.timeIntervalSince1970 ?? 0)|\(pixelSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}

/// One square tile in one of three states — the cover, the neutral lyre, or a
/// spinner over the lyre — at any size (§3.5). One reusable view, so History's
/// 40 pt rows, the 112 pt detail header and a future single timeline all show
/// the same thing. It only shows: every action lives in `MeetingCoverMenu` or
/// History's context menu.
struct MeetingCoverTile: View {
    @EnvironmentObject private var covers: CoverController

    let meeting: RecentMeeting
    let size: CGFloat
    /// The meeting's `cover.json`, when the caller has already read it. The
    /// header menu reads it for its own lines and passes it on, so a header
    /// render reads the file once. Left out (`nil`, the rows), the tile reads
    /// it itself. A passed-in `.some(nil)` means "read, and there is none" and
    /// is never re-read, which is why this is a double optional.
    var record: CoverRecord?? = nil

    var body: some View {
        let isBusy = covers.isBusy(meeting.directory)
        let thumbnail = meeting.coverImageURL.flatMap {
            // 2× for Retina: a 40 pt tile needs 80 px.
            CoverThumbnailCache.thumbnail(url: $0, modifiedAt: meeting.coverModifiedAt, pixelSize: Int(size * 2))
        }
        // The dot marks a failed draw on a tile with no picture. A failed New
        // Cover leaves the old picture, which needs no dot (its menu still
        // leads with the line). A queued Try Again keeps its old failure until
        // its job starts, so the spinner wins over the dot.
        let showsFailure = !isBusy && thumbnail == nil && covers.failure(for: meeting.directory) != nil

        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                neutralTile
            }
            if isBusy {
                // Over the picture too: a New Cover keeps the old one until the
                // new one is saved, and the wash says it is about to change.
                Rectangle().fill(.regularMaterial)
                ProgressView()
                    .controlSize(size >= 100 ? .small : .mini)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showsFailure {
                Circle()
                    .fill(KleothPalette.pendingTint)
                    .frame(width: size * 0.18, height: size * 0.18)
                    .padding(size * 0.06)
            }
        }
        // The tooltip is the scene that was sent (§3.5).
        .help(scene)
    }

    /// The scene from `cover.json`. Without a passed-in record, this reads
    /// the meeting's small `cover.json` on every render of the tile. That is
    /// accepted: a History row renders when it scrolls into view or when
    /// `CoverController` publishes, and a cache would need invalidating on
    /// every install, skip and remove. The `@EnvironmentObject` observation
    /// is what triggers the re-read: an install, skip or remove bumps
    /// `revision`, a publish that re-evaluates `body`, so no new view
    /// identity is needed. (The picture itself follows `meeting`, whose
    /// `coverModifiedAt` changes when the list reloads.)
    private var scene: String {
        let resolved: CoverRecord? = record ?? covers.record(for: meeting.directory)
        return resolved?.scene ?? ""
    }

    /// No cover (none yet, skipped, removed, or failed): the still lyre on a
    /// quiet fill, so a row without art still reads as a meeting, not a gap.
    private var neutralTile: some View {
        ZStack {
            Color.primary.opacity(0.06)
            LyreMark(motion: .still)
                .padding(size * 0.22)
        }
    }
}

/// The detail header's tile with its click menu (§3.5): Draw Cover ▸ with no
/// picture, and New Cover ▸ / Remove Cover / Show in Finder with one. A
/// failure's line and Try Again come first. Shown only while Covers ≠ Off;
/// the caller decides that.
struct MeetingCoverMenu: View {
    @EnvironmentObject private var covers: CoverController

    let meeting: RecentMeeting
    /// Whether the detail view has loaded a summary. The scene is written from
    /// the summary, never the transcript, so Draw Cover needs one.
    let hasSummary: Bool
    let size: CGFloat

    var body: some View {
        let isBusy = covers.isBusy(meeting.directory)
        // A queued Try Again keeps its old failure until its job starts; the
        // spinner wins, so no stale line or a second Try Again meanwhile.
        let failure = isBusy ? nil : covers.failure(for: meeting.directory)
        let record = covers.record(for: meeting.directory)

        Menu {
            if let failure {
                Text(failure)
                Button("Try Again") { covers.draw([meeting]) }
                Divider()
            }
            if let picture = meeting.coverImageURL {
                Text(pictureLine(record))
                Menu("New Cover") { styleButtons(isBusy: isBusy) }
                // Not while a cover job is queued or running: it would install
                // its picture over the `removed` record afterwards, undoing the
                // removal (and its guard against the automatic hook) at the
                // price of a paid call. The spinner says why it is greyed.
                Button("Remove Cover") { covers.remove(meeting) }
                    .disabled(isBusy)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([picture]) }
            } else {
                if record?.state == .skipped {
                    Text("Skipped: the meeting looked personal")
                }
                Menu("Draw Cover") { styleButtons(isBusy: isBusy) }
                    .disabled(!hasSummary)
                    .help(hasSummary ? "" : "Needs a summary")
            }
        } label: {
            MeetingCoverTile(meeting: meeting, size: size, record: record)
        }
        // Not `.borderlessButton`: that style is an `NSPopUpButton`, which keeps
        // only a label's Text and Image. The tile has neither, so it collapsed
        // to an empty few-point button (probed on macOS 26). The button style
        // with a plain button draws the SwiftUI label as it is.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Not "Cover", which VoiceOver would confuse with the menu's "Cover"
        // line for a dropped-in picture.
        .accessibilityLabel("Meeting cover")
    }

    /// The entries of New Cover ▸ and Draw Cover ▸. An explicit pick from here
    /// wins over the Style setting, Automatic included (`CoverStyleChoice`).
    /// Disabled while this meeting's cover is being drawn: the controller
    /// would ignore the click anyway.
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
    private func pictureLine(_ record: CoverRecord?) -> String {
        let parts = [
            record?.style.flatMap(CoverStyle.init(rawValue:))?.displayName,
            record?.engine.flatMap(CoverEngine.init(rawValue:))?.displayName,
        ].compactMap { $0 }
        return parts.isEmpty ? "Cover" : parts.joined(separator: " · ")
    }
}
