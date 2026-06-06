#!/usr/bin/env swift
//
// generate.swift — Kleoth README hero + GitHub social-preview generator.
//
// Fully headless AppKit offscreen rendering (no screen capture, no Xcode project).
// Reuses the existing brand icon (the gold lyre on a violet rounded-rect) and draws
// it on a near-#0D1117 GitHub-dark background with a subtle violet accent glow,
// then sets "Kleoth" + tagline in the system font.
//
// Outputs (rendered @2x, then downscaled with `sips` by the caller is NOT needed —
// this script writes the FINAL pixel sizes directly by rendering @2x into an
// offscreen rep and asking sips to downscale; see writePNG()):
//   docs/assets/social-preview.png  — 1280x640
//   docs/assets/hero.png            — ~1600x420
//
// Run:  swift app/branding-src/readme-images/generate.swift
//
import AppKit
import Foundation

// MARK: - Paths

let repoRoot: URL = {
    // This file lives at app/branding-src/readme-images/generate.swift
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // …/app/branding-src/readme-images/generate.swift -> repo root is 4 levels up
    return here.deletingLastPathComponent() // readme-images
        .deletingLastPathComponent()        // branding-src
        .deletingLastPathComponent()        // app
        .deletingLastPathComponent()        // repo root
}()

let iconURL = repoRoot
    .appendingPathComponent("app/branding-src/Kleoth.iconset/icon_512x512@2x.png")
let outDir = repoRoot.appendingPathComponent("docs/assets")

guard let appIcon = NSImage(contentsOf: iconURL) else {
    FileHandle.standardError.write("ERROR: could not load icon at \(iconURL.path)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Palette

// GitHub dark canvas (#0D1117) with a faint violet that ties to the lyre's plum icon.
let bgTop    = NSColor(srgbRed: 0x12 / 255.0, green: 0x16 / 255.0, blue: 0x22 / 255.0, alpha: 1)
let bgBottom = NSColor(srgbRed: 0x0B / 255.0, green: 0x0D / 255.0, blue: 0x14 / 255.0, alpha: 1)
let glowColor = NSColor(srgbRed: 0x7C / 255.0, green: 0x5C / 255.0, blue: 0xC4 / 255.0, alpha: 1) // soft violet
let gold = NSColor(srgbRed: 0xE6 / 255.0, green: 0xC2 / 255.0, blue: 0x6A / 255.0, alpha: 1)

let titleColor   = NSColor(srgbRed: 0xF4 / 255.0, green: 0xF6 / 255.0, blue: 0xFB / 255.0, alpha: 1) // near-white
let taglineColor = NSColor(srgbRed: 0xC9 / 255.0, green: 0xD1 / 255.0, blue: 0xDE / 255.0, alpha: 1) // light grey
let subColor     = NSColor(srgbRed: 0x8B / 255.0, green: 0x94 / 255.0, blue: 0xA3 / 255.0, alpha: 1) // muted grey

// MARK: - Helpers

/// Draw a soft radial glow centered at `center` with the given outer radius.
func drawGlow(center: NSPoint, radius: CGFloat, color: NSColor, maxAlpha: CGFloat) {
    let inner = color.withAlphaComponent(maxAlpha)
    let outer = color.withAlphaComponent(0)
    guard let grad = NSGradient(colors: [inner, outer],
                                atLocations: [0.0, 1.0],
                                colorSpace: .sRGB) else { return }
    grad.draw(fromCenter: center, radius: 0,
              toCenter: center, radius: radius,
              options: [])
}

/// Draws the app icon clipped to its rounded-tile shape, over a soft outer shadow.
///
/// The iconset PNG has NO alpha — the gaps outside its rounded corners are baked
/// WHITE, which reads as a white square frame on the dark background. Clipping to
/// a rounded rect (radius ≥ the tile's baked radius) cuts those wedges off. The
/// shadow is drawn first from an opaque rounded base, because a shadow set inside
/// the clip would be clipped away with the very corners it should soften.
func drawIcon(_ image: NSImage, in rect: NSRect) {
    // Measured from the iconset PNG (1024px canvas): the violet tile sits inset
    // ~27px (2.64%) inside the white canvas, with a ~23% squircle corner. Clip a
    // hair INSIDE the tile edge, with a radius generous enough to stay inside the
    // squircle's earlier curve onset, so no white survives on any edge or corner.
    let inset = rect.width * 0.0284
    let tileRect = rect.insetBy(dx: inset, dy: inset)
    let radius = tileRect.width * 0.26
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = rect.width * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.025)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}

func attr(_ s: String, font: NSFont, color: NSColor, tracking: CGFloat = 0,
          lineHeight: CGFloat? = nil) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
    ]
    if let lh = lineHeight {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        attrs[.paragraphStyle] = p
    }
    return NSAttributedString(string: s, attributes: attrs)
}

/// Render `draw` into an `scale`× backing bitmap at logical size `size`, downscale to
/// the final pixel size, and write a PNG. Rendering big then shrinking keeps text crisp.
func render(finalWidth: Int, finalHeight: Int, scale: CGFloat,
            to url: URL, _ draw: (_ size: NSSize) -> Void) {
    let logical = NSSize(width: CGFloat(finalWidth), height: CGFloat(finalHeight))
    let pxW = Int(logical.width * scale)
    let pxH = Int(logical.height * scale)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write("ERROR: could not create bitmap rep\n".data(using: .utf8)!)
        exit(1)
    }
    rep.size = logical // logical points; the rep is `scale`× denser

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        FileHandle.standardError.write("ERROR: could not create graphics context\n".data(using: .utf8)!)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true

    draw(logical)

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    // rep is at `scale`× → emit the high-res PNG, then downscale to final px with sips.
    guard let hiData = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("ERROR: PNG encode failed\n".data(using: .utf8)!)
        exit(1)
    }
    let tmp = url.deletingPathExtension().appendingPathExtension("hires.png")
    try! hiData.write(to: tmp)

    // Downscale with sips for clean Lanczos resampling to the exact final size.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", String(finalHeight), String(finalWidth), tmp.path, "--out", url.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - Shared background

func paintBackground(_ size: NSSize, glowAt: NSPoint, glowRadius: CGFloat) {
    // Base vertical gradient.
    let grad = NSGradient(colors: [bgTop, bgBottom], atLocations: [0, 1], colorSpace: .sRGB)!
    grad.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Subtle violet glow behind the icon.
    drawGlow(center: glowAt, radius: glowRadius, color: glowColor, maxAlpha: 0.22)

    // A second, tighter warm-gold kiss right at the icon to lift it off the dark.
    drawGlow(center: glowAt, radius: glowRadius * 0.45, color: gold, maxAlpha: 0.06)

    // Faint top vignette for depth (darken corners very slightly).
    let vignette = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.18),
    ], atLocations: [0.55, 1.0], colorSpace: .sRGB)!
    vignette.draw(fromCenter: NSPoint(x: size.width / 2, y: size.height / 2), radius: 0,
                  toCenter: NSPoint(x: size.width / 2, y: size.height / 2),
                  radius: max(size.width, size.height) * 0.72, options: [])
}

// MARK: - Social preview (1280 x 640)

func drawSocial(_ size: NSSize) {
    let iconSize: CGFloat = 312
    let blockGap: CGFloat = 60                // gap between icon and text column

    // Title + lines.
    let title = attr("Kleoth", font: .systemFont(ofSize: 120, weight: .bold),
                     color: titleColor, tracking: -2)
    let tagline = attr("Local-first, bot-free meeting recorder for macOS",
                       font: .systemFont(ofSize: 33, weight: .medium),
                       color: taglineColor, tracking: 0.2)
    let sub = attr("On-device Whisper  ·  Your files, your Mac  ·  No meeting bots",
                   font: .systemFont(ofSize: 25, weight: .regular),
                   color: subColor, tracking: 0.3)

    let tSize = title.size()
    let gSize = tagline.size()
    let sSize = sub.size()
    let textColW = max(tSize.width, gSize.width, sSize.width)

    // Center the icon+text group horizontally as a unit, nudged a hair left of true
    // center so the group reads as optically centered (large icon carries weight left).
    let groupW = iconSize + blockGap + textColW
    let groupX = (size.width - groupW) / 2 - 6
    let iconX = groupX
    let iconY = (size.height - iconSize) / 2
    let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)

    paintBackground(size,
                    glowAt: NSPoint(x: iconRect.midX + 30, y: iconRect.midY),
                    glowRadius: 600)

    drawIcon(appIcon, in: iconRect)

    // Vertical text stack, optically centered against the icon.
    let textX = iconX + iconSize + blockGap
    let lineSpacingTagToTitle: CGFloat = 26
    let lineSpacingSubToTag: CGFloat = 18
    let stackH = tSize.height + lineSpacingTagToTitle + gSize.height + lineSpacingSubToTag + sSize.height
    var cursorY = (size.height + stackH) / 2 - tSize.height   // top line baseline box

    title.draw(at: NSPoint(x: textX, y: cursorY))
    cursorY -= (lineSpacingTagToTitle + gSize.height)
    tagline.draw(at: NSPoint(x: textX, y: cursorY))
    cursorY -= (lineSpacingSubToTag + sSize.height)
    sub.draw(at: NSPoint(x: textX, y: cursorY))
}

// MARK: - Hero banner (1600 x 420)

func drawHero(_ size: NSSize) {
    let iconSize: CGFloat = 248
    let leftPad: CGFloat = 96
    let blockGap: CGFloat = 52

    let title = attr("Kleoth", font: .systemFont(ofSize: 92, weight: .bold),
                     color: titleColor, tracking: -1.5)
    let tagline = attr("Local-first, bot-free meeting recorder for macOS",
                       font: .systemFont(ofSize: 30, weight: .medium),
                       color: taglineColor, tracking: 0.2)
    let sub = attr("On-device Whisper  ·  Your files, your Mac  ·  No meeting bots",
                   font: .systemFont(ofSize: 23, weight: .regular),
                   color: subColor, tracking: 0.3)

    let iconX = leftPad
    let iconY = (size.height - iconSize) / 2
    let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)

    paintBackground(size,
                    glowAt: NSPoint(x: iconRect.midX + 40, y: iconRect.midY),
                    glowRadius: 520)

    // A faint hairline divider feel is avoided — keep it airy.
    drawIcon(appIcon, in: iconRect)

    let tSize = title.size()
    let gSize = tagline.size()
    let sSize = sub.size()

    let textX = iconX + iconSize + blockGap
    let lineSpacingTagToTitle: CGFloat = 22
    let lineSpacingSubToTag: CGFloat = 16
    let stackH = tSize.height + lineSpacingTagToTitle + gSize.height + lineSpacingSubToTag + sSize.height
    var cursorY = (size.height + stackH) / 2 - tSize.height

    title.draw(at: NSPoint(x: textX, y: cursorY))
    cursorY -= (lineSpacingTagToTitle + gSize.height)
    tagline.draw(at: NSPoint(x: textX, y: cursorY))
    cursorY -= (lineSpacingSubToTag + sSize.height)
    sub.draw(at: NSPoint(x: textX, y: cursorY))
}

// MARK: - Run

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

render(finalWidth: 1280, finalHeight: 640, scale: 2.0,
       to: outDir.appendingPathComponent("social-preview.png"), drawSocial)

render(finalWidth: 1600, finalHeight: 420, scale: 2.0,
       to: outDir.appendingPathComponent("hero.png"), drawHero)

print("OK: wrote social-preview.png (1280x640) and hero.png (1600x420) to \(outDir.path)")
