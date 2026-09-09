// make-iconset.swift — turn a full-bleed 1024×1024 icon artwork (as the image
// model produces it: opaque, no corners) into `Kleoth.iconset/` + `Kleoth.icns`
// on Apple's macOS icon grid: the artwork is scaled into an 824 px continuous
// rounded square centred on a transparent 1024 canvas (corner radius 185.4 px,
// the Big Sur+ template), so Finder, the Dock and Tahoe's icon plate all get
// the shape they expect. Dependency-free (AppKit/CoreGraphics + `iconutil`).
//
// Usage:  swift make-iconset.swift <artwork-1024.png> [<iconset-dir>] [<icns-out>]
//   defaults: app/branding-src/Kleoth.iconset and app/bundle/Kleoth.icns
//             (resolved relative to this script).
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: make-iconset.swift <artwork-1024.png> [<iconset-dir>] [<icns-out>]\n", stderr)
    exit(2)
}
let here = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let inURL = URL(fileURLWithPath: args[1])
let iconsetURL = args.count >= 3 ? URL(fileURLWithPath: args[2]) : here.appendingPathComponent("Kleoth.iconset")
let icnsURL = args.count >= 4 ? URL(fileURLWithPath: args[3]) : here.deletingLastPathComponent().appendingPathComponent("bundle/Kleoth.icns")

guard let source = NSImage(contentsOf: inURL), source.isValid else {
    fputs("cannot load \(inURL.path)\n", stderr); exit(1)
}

/// Apple's icon grid at 1024: the body is 824 px, inset 100 px on every side,
/// with a continuous-curvature corner of 185.4 px.
let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100
let bodyRadius: CGFloat = 185.4

func render(size: Int) -> Data {
    let px = CGFloat(size)
    let scale = px / canvas
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: px, height: px))

    let body = CGRect(x: bodyInset * scale, y: bodyInset * scale,
                      width: (canvas - 2 * bodyInset) * scale, height: (canvas - 2 * bodyInset) * scale)
    let clip = NSBezierPath(roundedRect: body, xRadius: bodyRadius * scale, yRadius: bodyRadius * scale)
    clip.addClip()
    // The artwork was composed full-bleed; scale it onto the body so the
    // subject keeps its intended 60 % occupancy inside the rounded square.
    source.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(at: iconsetURL)
try! fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconsetURL.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconsetURL.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(iconsetURL.path)")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fputs("iconutil failed (\(task.terminationStatus))\n", stderr); exit(1) }
print("wrote \(icnsURL.path)")
