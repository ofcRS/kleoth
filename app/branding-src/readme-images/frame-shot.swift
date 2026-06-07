#!/usr/bin/env swift
//
// frame-shot.swift — place a transparent-surround app screenshot on the Kleoth
// dark-gradient backdrop (same palette as the README hero), with a soft shadow,
// so the README screenshots read as one cohesive product and look identical on
// GitHub's light and dark themes.
//
// Usage:  swift frame-shot.swift <input.png> <output.png> [padPx]
//
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: frame-shot <input> <output> [pad]\n".data(using: .utf8)!)
    exit(1)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let shot = NSImage(contentsOf: inURL),
      let shotRep = NSBitmapImageRep(data: try! Data(contentsOf: inURL)) else {
    FileHandle.standardError.write("ERROR: cannot load \(inURL.path)\n".data(using: .utf8)!)
    exit(1)
}
let sw = CGFloat(shotRep.pixelsWide)
let sh = CGFloat(shotRep.pixelsHigh)
let pad: CGFloat = args.count >= 4 ? CGFloat(Double(args[3])!) : max(64, sw * 0.07)
let W = sw + pad * 2
let H = sh + pad * 2

let bgTop    = NSColor(srgbRed: 0x12 / 255.0, green: 0x16 / 255.0, blue: 0x22 / 255.0, alpha: 1)
let bgBottom = NSColor(srgbRed: 0x0B / 255.0, green: 0x0D / 255.0, blue: 0x14 / 255.0, alpha: 1)
let glow     = NSColor(srgbRed: 0x7C / 255.0, green: 0x5C / 255.0, blue: 0xC4 / 255.0, alpha: 1)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("ERROR: bitmap/context\n".data(using: .utf8)!)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
ctx.shouldAntialias = true

// Base vertical gradient + a soft violet glow centered behind the screenshot.
NSGradient(colors: [bgTop, bgBottom], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
NSGradient(colors: [glow.withAlphaComponent(0.16), glow.withAlphaComponent(0)],
           atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(fromCenter: NSPoint(x: W / 2, y: H / 2), radius: 0,
          toCenter: NSPoint(x: W / 2, y: H / 2), radius: max(W, H) * 0.62, options: [])

// The screenshot, with a soft drop shadow (it also carries its own window shadow).
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
shadow.shadowBlurRadius = pad * 0.5
shadow.shadowOffset = NSSize(width: 0, height: -pad * 0.18)
shadow.set()
shot.draw(in: NSRect(x: pad, y: pad, width: sw, height: sh), from: .zero,
          operation: .sourceOver, fraction: 1.0, respectFlipped: true,
          hints: [.interpolation: NSImageInterpolation.high])
NSGraphicsContext.restoreGraphicsState()

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path) \(Int(W))x\(Int(H))")
