import SwiftUI
import AppKit
import ImageIO
import KleothCore

/// ImageIO thumbnails of meeting covers, keyed by path + mtime + pixel size
/// (design doc 2026-09-24 §4.4). A cover is a ~1024 px JPEG and a History row
/// shows it at 56 pt, so decoding the full picture for every row would be
/// wasted work; `CGImageSourceCreateThumbnailAtIndex` decodes straight to the
/// size asked for. The meeting page's band asks for the full file
/// (`pixelSize` ≥ 1024), with the same key scheme. The mtime is in the key
/// because New Cover writes the same `cover.jpg` path: a new picture is a new
/// key, never a stale hit.
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

/// One square tile in one of three states — the cover, the neutral lyre while
/// a job waits for its scene, or a spinner over either — at any size. History's
/// 56 pt rows use it (only for a meeting with a picture or a running job); the
/// meeting page's band is `MeetingCoverBand`. It only shows: every action
/// lives in `MeetingCoverMenuItems` or History's context menu.
struct MeetingCoverTile: View {
    @EnvironmentObject private var covers: CoverController

    let meeting: RecentMeeting
    let size: CGFloat

    var body: some View {
        let isBusy = covers.isBusy(meeting.directory)
        let thumbnail = meeting.coverImageURL.flatMap {
            // 2× for Retina: a 56 pt tile needs 112 px.
            CoverThumbnailCache.thumbnail(url: $0, modifiedAt: meeting.coverModifiedAt, pixelSize: Int(size * 2))
        }

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
        // One element to VoiceOver that says what it is, not an unnamed image
        // or a lone progress indicator; label and value match the band's chip.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meeting cover")
        .accessibilityValue(isBusy ? "Drawing cover" : "")
        .accessibilityAddTraits(.isImage)
        // The tooltip is the scene that was sent (§3.5).
        .help(scene)
    }

    /// The scene from `cover.json`, re-read on every render of the tile. The
    /// `@EnvironmentObject` observation is what triggers the re-read: an
    /// install, skip or remove bumps `revision`, a publish that re-evaluates
    /// `body`, so no cache to invalidate and no new view identity. (The
    /// picture itself follows `meeting`, whose `coverModifiedAt` changes when
    /// the list reloads.)
    private var scene: String {
        covers.record(for: meeting.directory)?.scene ?? ""
    }

    /// No picture yet (a job waiting for its scene): the still lyre on a
    /// quiet fill, under the spinner.
    private var neutralTile: some View {
        ZStack {
            Color.primary.opacity(0.06)
            LyreMark(motion: .still)
                .padding(size * 0.22)
        }
    }
}
