import SwiftUI
import AppKit

// MARK: - Kleoth design system
//
// The shared visual vocabulary for the app's SwiftUI surfaces. Every view should
// pull spacing, radii, colors, and the common building blocks (cards, section
// headers, chips, badges) from here so the UI reads as one cohesive,
// "refined native macOS 26 Tahoe" product rather than a pile of one-off styles.
//
// Direction: system materials (`.regularMaterial` / `.thinMaterial`), SF Pro,
// the user's *system accent* (`Color.accentColor` — never a hardcoded brand
// hue), hairline strokes, and rounded cards. Liquid Glass is reserved for the
// single hero element (the record button, see `MeetingFormatting.swift`); all
// content here sits on materials, per Apple's HIG. macOS 26 niceties are gated
// behind `if #available(macOS 26, *)` and degrade gracefully below.

// MARK: - Metrics

/// Spacing, corner-radius, and stroke constants. Sticking to these keeps a
/// consistent rhythm across every view (use `KleothMetrics.m`, not a literal).
enum KleothMetrics {
    // Spacing scale (points). xs → xl, roughly geometric for a clear hierarchy.
    /// 4 — hairline gaps (icon ↔ label, badge inner padding).
    static let spacingXS: CGFloat = 4
    /// 8 — tight rows and chip spacing.
    static let spacingS: CGFloat = 8
    /// 12 — default gap between sibling elements.
    static let spacingM: CGFloat = 12
    /// 16 — default card padding and section spacing.
    static let spacingL: CGFloat = 16
    /// 24 — generous separation between major sections.
    static let spacingXL: CGFloat = 24

    // Corner radii (points).
    /// 14 — content cards (the primary container shape).
    static let cornerRadiusCard: CGFloat = 14
    /// 10 — controls and smaller framed panels.
    static let cornerRadiusControl: CGFloat = 10
    /// 8 — chips and pills clipped to a rounded rect (capsules ignore this).
    static let cornerRadiusChip: CGFloat = 8

    /// 1 — hairline stroke width for card/section borders.
    static let hairline: CGFloat = 1
}

// MARK: - Palette

/// Semantic colors. Built on the *system accent* and a small curated set so the
/// app inherits the user's chosen tint and stays legible in light and dark mode.
enum KleothPalette {
    /// "You" / the local speaker (mic, `speaker_0`). Always the system accent.
    static let youTint: Color = .accentColor
    /// "Them" / the remote speaker (system audio, `speaker_1`). A calm teal that
    /// reads clearly against the accent without competing with it.
    static let themTint: Color = .teal

    /// Curated palette for any additional speakers beyond You/Them, cycled
    /// deterministically. Chosen to stay distinct and tasteful in both appearances.
    static let extraSpeakerTints: [Color] = [.indigo, .orange, .pink, .green, .purple, .mint, .brown]

    /// Hairline stroke color for cards and section dividers — a faint tint of the
    /// foreground so it adapts to light/dark without a hard edge.
    static let hairlineStroke: Color = Color.primary.opacity(0.06)

    // MARK: Semantic status tints
    //
    // The app is accent-driven (never a hardcoded brand hue), but a few states
    // carry *universal* meaning that should read instantly regardless of the
    // user's chosen accent. These are the deliberate, documented exceptions —
    // use the token, not a bare `.red`/`.orange`/`.green`, so the meaning stays
    // consistent everywhere.

    /// Active recording. Red is the universal record affordance; intentionally
    /// not the accent so "recording" is unmistakable under any system tint.
    static let recordingTint: Color = .red
    /// Pending / unfinished work — untranscribed audio, "no summary yet".
    static let pendingTint: Color = .orange
    /// Success / granted — e.g. calendar access enabled.
    static let successTint: Color = .green

    /// A stable, tasteful color for a speaker.
    ///
    /// The two-channel capture model means You/Them dominate, so those are pinned:
    /// "You" / `speaker_0` → accent; "Them" / `speaker_1` → teal. Any further
    /// speakers (e.g. a SOTA-diarized recording) cycle `extraSpeakerTints`
    /// deterministically off the speaker id, so the same speaker always gets the
    /// same color within and across views.
    ///
    /// - Parameters:
    ///   - id: The transcript speaker id, e.g. `"speaker_0"`.
    ///   - name: The display name if mapped (e.g. `"You"`, `"Them"`), else `nil`.
    static func speakerColor(forSpeakerId id: String, name: String?) -> Color {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Pin the two primary roles by name or by the canonical channel ids.
        if normalizedName == "you" || normalizedID == "speaker_0" { return youTint }
        if normalizedName == "them" || normalizedID == "speaker_1" { return themTint }

        // Otherwise pick deterministically from the curated extras. Prefer the
        // numeric channel suffix ("speaker_2" → 2) so colors are stable and
        // ordered; fall back to a hash of the id for non-standard ids.
        let index: Int
        if let suffix = normalizedID.split(separator: "_").last, let n = Int(suffix) {
            index = n
        } else {
            index = abs(normalizedID.hashValue)
        }
        return extraSpeakerTints[index % extraSpeakerTints.count]
    }
}

// MARK: - Card container

extension View {
    /// Wraps content in the standard Kleoth content card: interior padding, a
    /// `.regularMaterial` fill clipped to a rounded rect, and a hairline border.
    /// This is the primary container shape for grouped content — material, *not*
    /// glass (glass is reserved for the record button).
    ///
    /// - Parameter padding: Interior padding. Defaults to `KleothMetrics.spacingL`.
    func kleothCard(padding: CGFloat = KleothMetrics.spacingL) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                    .strokeBorder(KleothPalette.hairlineStroke, lineWidth: KleothMetrics.hairline)
            )
    }
}

// MARK: - Section header

/// A consistent section header: an accent-tinted SF Symbol next to a `.headline`
/// title, baseline-aligned. Used to open each grouped section so affordances read
/// uniformly across views.
///
/// Usage: `KleothSectionHeader("Action Items", systemImage: "checklist")`
struct KleothSectionHeader: View {
    private let title: String
    private let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KleothMetrics.spacingS) {
            Image(systemName: systemImage)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
            Text(title)
                .font(.headline)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pill / chip

/// A small capsule chip for metadata and tags: an optional SF Symbol plus
/// `.caption` text on a quiet tinted background. Defaults to a neutral secondary
/// look; pass a `tint` to color it (the fill becomes a soft wash of that tint).
///
/// Usage: `KleothPill("12m 03s", systemImage: "clock")`
///        `KleothPill("#planning", tint: .accentColor)`
struct KleothPill: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: KleothMetrics.spacingXS) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, KleothMetrics.spacingS)
        .padding(.vertical, KleothMetrics.spacingXS)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Tier badge

/// The transcription-tier badge: "SOTA" (ElevenLabs, accent) or "Local"
/// (on-device, green). A compact capsule, `.caption2.bold()`, matching the
/// History list's badge language.
///
/// Usage: `KleothTierBadge(isSOTA: TranscriptTier.isSOTA(meeting.transcriptTier))`
struct KleothTierBadge: View {
    let isSOTA: Bool

    var body: some View {
        let tint: Color = isSOTA ? .accentColor : .green
        Text(isSOTA ? "SOTA" : "Local")
            .font(.caption2.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, KleothMetrics.spacingS)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

extension KleothPalette {
    /// Convenience builder for the tier badge, for call sites that prefer a
    /// function over the `KleothTierBadge` view.
    ///
    /// Usage: `KleothPalette.tierBadge(isSOTA: false)`
    static func tierBadge(isSOTA: Bool) -> some View {
        KleothTierBadge(isSOTA: isSOTA)
    }
}

// MARK: - Stat tile

/// A label-over-value stat cell for compact metric rows (e.g. the cost
/// breakdown): a `.caption2` secondary label above a `.caption` monospaced-digit
/// value, so columns of numbers align cleanly.
///
/// Usage: `KleothStatTile(label: "Total", value: "$0.0123")`
struct KleothStatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Speaker dot

/// A small filled circle used to color-code a speaker before their name in
/// transcript rows. Pair with `KleothPalette.speakerColor(forSpeakerId:name:)`.
///
/// Usage: `SpeakerDot(color: KleothPalette.speakerColor(forSpeakerId: id, name: name))`
struct SpeakerDot: View {
    let color: Color
    var size: CGFloat = 8
    /// Optional speaker name, surfaced to assistive tech so speaker identity is
    /// not conveyed by color alone.
    var speakerName: String?

    init(color: Color, size: CGFloat = 8, speakerName: String? = nil) {
        self.color = color
        self.size = size
        self.speakerName = speakerName
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityLabel(speakerName.map { "Speaker: \($0)" } ?? "")
            .accessibilityHidden(speakerName == nil)
    }
}

// MARK: - Wrapping flow layout

/// A minimal left-to-right wrapping layout: lays children out in rows, wrapping
/// to the next row when the proposed width is exceeded. Shared by the detail
/// header's metadata chips and the summary's tag chips so a long run (e.g. a long
/// model slug) wraps instead of clipping in a narrow pane.
struct KleothFlowLayout: Layout {
    var spacing: CGFloat = KleothMetrics.spacingS

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Bundled brand assets

/// Loads brand images bundled with the app target (via `Bundle.module`), cached.
/// Used for the menu-bar template glyph and the empty-state illustrations. All
/// access is on the main actor (UI), which also keeps the cache concurrency-safe.
@MainActor
enum KleothAssets {
    /// Named full-bleed illustrations under `Sources/KleothApp/Resources`.
    enum Illustration: String {
        case noMeetings = "EmptyNoMeetings"
        case notTranscribed = "EmptyNotTranscribed"
        case selectMeeting = "EmptySelect"
    }

    private static var cache: [String: NSImage] = [:]

    /// The menu-bar glyph as an AppKit *template* image, so it follows the menu
    /// bar's light/dark appearance. `nil` when the asset is missing (callers fall
    /// back to an SF Symbol).
    static func menuBarGlyph() -> NSImage? {
        // Cache the *prepared* template under its own key, so we never mutate the
        // shared raw-image cache entry in place (NSImage is a reference type).
        let key = "MenuBarGlyph.template"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.module.url(forResource: "MenuBarGlyph", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        // Size to the menu-bar icon height (~18pt), preserving aspect, so the
        // high-res source renders crisply at status-bar size.
        let height: CGFloat = 18
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 0.8
        image.size = NSSize(width: (height * aspect).rounded(), height: height)
        cache[key] = image
        return image
    }

    /// A full-bleed brand illustration, or `nil` if missing.
    static func illustration(_ which: Illustration) -> NSImage? {
        image(named: which.rawValue)
    }

    /// The Kleoth lyre app mark for in-app chrome (the menu-bar popover header),
    /// so it reads as the same brand as the Dock/Finder icon — not a generic
    /// waveform glyph. Prefers a bundled full-bleed `AppMark.png`, falling back to
    /// the running app's own icon image, then `nil` (callers use an SF Symbol).
    static func appMark() -> NSImage? {
        if let bundled = image(named: "AppMark") { return bundled }
        let icon = NSApp.applicationIconImage
        return (icon?.size.width ?? 0) > 0 ? icon : nil
    }

    private static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

// MARK: - Illustration tile

/// A full-bleed brand illustration shown as a rounded, contained tile with a
/// hairline border and soft shadow — used in empty states. Decorative, so it is
/// hidden from assistive tech (the surrounding title/message carry the meaning).
struct KleothIllustration: View {
    let image: NSImage
    var size: CGFloat = 132

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                    .strokeBorder(KleothPalette.hairlineStroke, lineWidth: KleothMetrics.hairline)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}
