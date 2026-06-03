// maketemplate.swift — convert a black-on-white glyph PNG into a tight,
// black-on-transparent macOS *template* image (alpha = inverted luminance),
// autocropped to the glyph's bounding box. Dependency-free (AppKit/CoreGraphics).
//
// Usage:  swift maketemplate.swift <in.png> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: maketemplate <in.png> <out.png>\n", stderr); exit(2) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let img = NSImage(contentsOf: inURL),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cg = rep.cgImage else { fputs("cannot load \(inURL.path)\n", stderr); exit(1) }

let w = cg.width, h = cg.height
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let buf = ctx.data else { exit(1) }
let p = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)

// Black, with alpha = (1 - luminance) * existing alpha. White -> transparent.
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Double(p[i]), g = Double(p[i + 1]), b = Double(p[i + 2]), a = Double(p[i + 3])
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let alpha = (255.0 - lum) * (a / 255.0)
        let A = UInt8(max(0, min(255, alpha)))
        p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = A
        if A > 16 { if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y } }
    }
}
guard maxX >= minX, maxY >= minY else { fputs("empty glyph\n", stderr); exit(1) }

// Crop to the glyph bbox + a small margin.
let margin = Int(Double(max(w, h)) * 0.04)
let x0 = max(0, minX - margin), y0 = max(0, minY - margin)
let x1 = min(w - 1, maxX + margin), y1 = min(h - 1, maxY + margin)
let cw = x1 - x0 + 1, ch = y1 - y0 + 1

guard let outCtx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8,
                             bytesPerRow: cw * 4, space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let outBuf = outCtx.data else { exit(1) }
let q = outBuf.bindMemory(to: UInt8.self, capacity: cw * ch * 4)
for y in 0..<ch {
    for x in 0..<cw {
        let si = ((y0 + y) * w + (x0 + x)) * 4
        let di = (y * cw + x) * 4
        q[di] = p[si]; q[di + 1] = p[si + 1]; q[di + 2] = p[si + 2]; q[di + 3] = p[si + 3]
    }
}
guard let outCG = outCtx.makeImage() else { exit(1) }
let outRep = NSBitmapImageRep(cgImage: outCG)
guard let png = outRep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: outURL)
print("wrote \(outURL.path) \(cw)x\(ch) (cropped from \(w)x\(h))")
