// rasterize-template.swift — render lyre-template.svg (black silhouette) onto
// white at a given pixel height, then feed the result to ../maketemplate.swift
// to get the black-on-transparent menu-bar template image. Two steps so the
// existing luminance→alpha + autocrop pipeline stays the single source of truth.
//
// Usage:  swift rasterize-template.swift <in.svg> <out.png> [heightPx=36]
//   then: swift ../maketemplate.swift <out.png> ../../Sources/KleothApp/Resources/MenuBarGlyph.png
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: rasterize-template <in.svg> <out.png> [heightPx]\n", stderr); exit(2) }
let height = args.count >= 4 ? Double(args[3]) ?? 36 : 36
guard let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { fputs("cannot load svg\n", stderr); exit(1) }
let aspect = svg.size.width / svg.size.height
// A little padding on every side so anti-aliased edges never touch the canvas;
// maketemplate autocrops it away again.
let pad = 4.0
let w = Int((height * aspect).rounded()) + Int(pad * 2), h = Int(height) + Int(pad * 2)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
NSGraphicsContext.current?.imageInterpolation = .high
svg.draw(in: NSRect(x: pad, y: pad, width: height * aspect, height: height),
         from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(w)x\(h)")
