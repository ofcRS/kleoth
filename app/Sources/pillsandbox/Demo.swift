import AppKit
import KleothCore
import KleothPillUI

/// README demos, composed from a pill film (`--demo dictation|screen`).
///
/// The pill in every frame is the REAL one — the `DictationPillController`
/// capture the film already takes. Everything around it is a stage drawn here:
/// a desktop, an editor or a slide window with sample content, a caption per
/// step, the fn+shift keys while they are held, the words being spoken, and a
/// cursor. Nothing is captured from the screen and no other app is involved.
/// `app/branding-src/demo/make-demos.sh` films both and encodes the GIFs.
enum DemoKind: String {
    case dictation, screen
}

/// The stage, in points: the lower middle of the screen the pill docks on.
private let stageSize = CGSize(width: 680, height: 425)
private let stageScale: CGFloat = 2

/// Writes `frame-NNNN.png` for every captured frame plus `frames.txt`, an
/// ffmpeg concat list that keeps the film's real timing (the last frame is
/// held so a looping GIF rests before it restarts). Returns the list's URL.
func writeDemo(_ frames: [CapturedFrame], kind: DemoKind, to dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let first = frames.first else { throw CocoaError(.fileWriteUnknown) }
    let screen = first.frame.screenFrame
    let camera = CGRect(
        x: first.frame.panelFrame.midX - stageSize.width / 2, y: screen.minY,
        width: stageSize.width, height: stageSize.height
    )
    let stage = DemoStage(kind: kind, camera: camera, screen: screen, frames: frames)
    var list = ""
    for (index, captured) in frames.enumerated() {
        guard let image = stage.render(index) else { continue }
        let name = String(format: "frame-%04d.png", index)
        try writePNG(image, to: dir.appendingPathComponent(name))
        let next = index + 1 < frames.count ? frames[index + 1].time : captured.time + 1.8
        list += "file '\(name)'\nduration \(String(format: "%.4f", max(0.01, next - captured.time)))\n"
    }
    // The concat demuxer ignores the last entry's duration unless the file is repeated.
    list += "file '" + String(format: "frame-%04d.png", frames.count - 1) + "'\n"
    let url = dir.appendingPathComponent("frames.txt")
    try list.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - Stage

private struct DemoStage {
    let kind: DemoKind
    let camera: CGRect
    let screen: CGRect
    let frames: [CapturedFrame]
    /// Where the drawn cursor is on each frame (screen demo only).
    let cursor: [CGPoint]

    init(kind: DemoKind, camera: CGRect, screen: CGRect, frames: [CapturedFrame]) {
        self.kind = kind
        self.camera = camera
        self.screen = screen
        self.frames = frames
        cursor = kind == .screen ? Self.cursorPath(frames, camera: camera) : []
    }

    /// When a sequence step first ran (nil if it never did).
    func start(_ step: String) -> TimeInterval? {
        frames.first { $0.step == step }?.time
    }

    func end(_ step: String) -> TimeInterval? {
        frames.last { $0.step == step }?.time
    }

    var editorRect: CGRect {
        // Dictation leaves room below the window for the words being spoken.
        let bottom: CGFloat = kind == .dictation ? 150 : 92
        return CGRect(x: camera.minX + 56, y: camera.minY + bottom, width: camera.width - 112, height: camera.height - bottom - 58)
    }

    func render(_ index: Int) -> CGImage? {
        let captured = frames[index]
        guard let ctx = CGContext(
            data: nil, width: Int(camera.width * stageScale), height: Int(camera.height * stageScale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: stageScale, y: stageScale)
        ctx.translateBy(x: -camera.minX, y: -camera.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        drawDesktop(ctx)
        let t = captured.time
        switch kind {
        case .dictation:
            drawEditor(at: t)
            if ["armed", "listening"].contains(captured.step) { drawKeys() }
            drawSpeech(at: t)
        case .screen:
            drawSlides()
        }
        drawPill(captured, in: ctx)
        if kind == .screen { drawCursor(index) }
        drawCaption(caption(for: captured))
        return ctx.makeImage()
    }

    // MARK: Captions

    func caption(for captured: CapturedFrame) -> String {
        let t = captured.time
        switch kind {
        case .dictation:
            if let done = start("done"), t >= done { return "Pasted where your cursor was" }
            if let released = start("transcribing"), t >= released { return "Let go — Kleoth transcribes it and cleans it up" }
            if let held = start("armed"), t >= held { return "Hold fn + shift and talk" }
            return "Your cursor is in any app — an editor, a terminal, a chat"
        case .screen:
            let phase = phaseName(captured.frame.phase)
            if phase == "saving" || phase == "saved" { return "Saved: an MP4 in ~/Kleoth/screen-recordings" }
            if let stop = start("hover:stop"), t >= stop { return "Stop when you're done" }
            if let rec = start("click:rec"), t >= rec { return "Recording the screen, system audio and your mic" }
            return "Hover the pill, click Record, pick a region"
        }
    }

    func drawCaption(_ text: String) {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let box = CGRect(
            x: camera.midX - size.width / 2 - 16, y: camera.maxY - 14 - size.height - 12,
            width: size.width + 32, height: size.height + 12
        )
        NSColor(white: 0.1, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        label.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 6))
    }

    // MARK: Desktop

    func drawDesktop(_ ctx: CGContext) {
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.84, green: 0.89, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.91, blue: 0.95, alpha: 1),
        ])
        gradient?.draw(in: camera, angle: -90)
        let glow = NSGradient(colors: [
            NSColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 0.16),
            NSColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 0),
        ])
        glow?.draw(fromCenter: CGPoint(x: camera.minX + 120, y: camera.maxY - 60), radius: 0,
                   toCenter: CGPoint(x: camera.minX + 120, y: camera.maxY - 60), radius: 420, options: [])
    }

    /// A plain window: rounded, shadowed, a title bar with the three dots.
    /// Returns the content rect below the title bar.
    @discardableResult
    func drawWindow(_ rect: CGRect, title: String) -> CGRect {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let bar = CGRect(x: rect.minX, y: rect.maxY - 32, width: rect.width, height: 32)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(white: 0.965, alpha: 1).setFill()
        bar.fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        CGRect(x: rect.minX, y: bar.minY, width: rect.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dots: [NSColor] = [
            NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
        ]
        for (i, color) in dots.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.minX + 14 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
        }
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: 0.35, alpha: 1),
        ])
        label.draw(at: CGPoint(x: bar.midX - label.size().width / 2, y: bar.midY - label.size().height / 2))
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 33)
    }

    // MARK: Dictation

    static let spoken = "so for standup — next I'm, uh, moving settings over to the new sidebar, and then, um, I'll write the migration for, like, old installs"
    static let pasted = "Next: move Settings to the new sidebar, then write the migration for old installs."

    func drawEditor(at t: TimeInterval) {
        let content = drawWindow(editorRect, title: "standup.md")
        let body = NSMutableAttributedString()
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ]
        // Bullets hang: a wrapped line lines up with the text, not the bullet.
        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = 15
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(white: 0.18, alpha: 1),
            .paragraphStyle: hanging,
        ]
        body.append(NSAttributedString(string: "Standup — Thursday\n\n", attributes: heading))
        body.append(NSAttributedString(string: "•  Shipped the export fix\n•  ", attributes: text))
        let pasted = start("done").map { t >= $0 } ?? false
        if pasted { body.append(NSAttributedString(string: Self.pasted, attributes: text)) }
        // A caret blinking at 1 Hz where the text goes.
        if Int(t * 2) % 2 == 0 {
            body.append(NSAttributedString(string: "|", attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .light), .foregroundColor: NSColor.systemBlue,
            ]))
        }
        body.draw(with: content.insetBy(dx: 30, dy: 26), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// fn and ⇧ shift, pressed, bottom left.
    func drawKeys() {
        var x = camera.minX + 26
        let y = camera.minY + 26
        for (label, width) in [("fn", 46.0), ("⇧ shift", 86.0)] {
            let key = CGRect(x: x, y: y, width: width, height: 40)
            NSColor(white: 0.55, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: key.offsetBy(dx: 0, dy: -2), xRadius: 8, yRadius: 8).fill()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: key, xRadius: 8, yRadius: 8).fill()
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.2, alpha: 1),
            ])
            text.draw(at: CGPoint(x: key.midX - text.size().width / 2, y: key.midY - text.size().height / 2))
            x += width + 10
        }
    }

    /// The words as they are said, above the pill: revealed across the hold,
    /// then fading once the keys are released.
    func drawSpeech(at t: TimeInterval) {
        guard let from = start("listening"), let to = end("listening"), t >= from else { return }
        let released = start("transcribing") ?? to
        var alpha: CGFloat = 1
        if t > released { alpha = max(0, 1 - CGFloat(t - released) / 0.5) }
        guard alpha > 0 else { return }
        let words = Self.spoken.split(separator: " ")
        let shown = min(words.count, Int(ceil(Double(words.count) * min(1, (t - from) / max(0.1, to - from) * 1.08))))
        guard shown > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: "“" + words.prefix(shown).joined(separator: " ") + "…”", attributes: [
            .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 15), toHaveTrait: .italicFontMask),
            .foregroundColor: NSColor(white: 0.25, alpha: alpha),
            .paragraphStyle: paragraph,
        ])
        let width: CGFloat = 440
        let bounds = text.boundingRect(with: CGSize(width: width, height: 200), options: [.usesLineFragmentOrigin])
        let box = CGRect(x: camera.midX - width / 2 - 16, y: camera.minY + 66, width: width + 32, height: ceil(bounds.height) + 20)
        NSColor(white: 1, alpha: 0.94 * alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
        NSColor(white: 0.8, alpha: alpha).setStroke()
        NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()
        text.draw(with: box.insetBy(dx: 16, dy: 10), options: [.usesLineFragmentOrigin])
    }

    // MARK: Screen

    func drawSlides() {
        let content = drawWindow(editorRect, title: "Q4 roadmap")
        let heading = NSAttributedString(string: "Q4 roadmap", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ])
        heading.draw(at: CGPoint(x: content.minX + 40, y: content.maxY - 62))
        let sub = NSAttributedString(string: "Where each team is, and what ships next", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ])
        sub.draw(at: CGPoint(x: content.minX + 40, y: content.maxY - 86))
        let rows: [(String, CGFloat, NSColor)] = [
            ("Onboarding", 0.78, NSColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 1)),
            ("Billing", 0.52, NSColor(srgbRed: 0.35, green: 0.40, blue: 0.85, alpha: 1)),
            ("Mobile", 0.30, NSColor(srgbRed: 0.93, green: 0.62, blue: 0.20, alpha: 1)),
        ]
        for (i, row) in rows.enumerated() {
            let y = content.maxY - 132 - CGFloat(i) * 40
            let label = NSAttributedString(string: row.0, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1),
            ])
            label.draw(at: CGPoint(x: content.minX + 40, y: y + 4))
            let track = CGRect(x: content.minX + 140, y: y, width: content.width - 180, height: 22)
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()
            row.2.setFill()
            NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: track.width * row.1, height: 22),
                         xRadius: 6, yRadius: 6).fill()
        }
    }

    /// Where the cursor is on every frame: on the pill while the film points at
    /// it, otherwise wandering over the slide — eased, so it glides between them.
    static func cursorPath(_ frames: [CapturedFrame], camera: CGRect) -> [CGPoint] {
        let slide = [
            CGPoint(x: camera.midX + 130, y: camera.minY + 250),
            CGPoint(x: camera.midX + 40, y: camera.minY + 214),
            CGPoint(x: camera.midX - 50, y: camera.minY + 172),
            CGPoint(x: camera.midX + 90, y: camera.minY + 200),
        ]
        var position = slide[0]
        var last = frames.first?.time ?? 0
        return frames.map { captured in
            let target: CGPoint
            if let pointer = captured.pointer {
                target = pointer
            } else {
                // Move to the next point on the slide every 1.4 s.
                target = slide[Int(captured.time / 1.4) % slide.count]
            }
            let dt = max(0, captured.time - last)
            last = captured.time
            let k = CGFloat(1 - exp(-dt * 7))
            position = CGPoint(x: position.x + (target.x - position.x) * k, y: position.y + (target.y - position.y) * k)
            return position
        }
    }

    func drawCursor(_ index: Int) {
        let point = cursor[index]
        // A ring around the cursor for a moment after each click.
        let captured = frames[index]
        if captured.step.hasPrefix("click:"), let clicked = start(captured.step) {
            let age = CGFloat(captured.time - clicked)
            if age < 0.35 {
                let radius = 8 + age * 60
                NSColor.systemBlue.withAlphaComponent(0.5 * (1 - age / 0.35)).setStroke()
                let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        let arrow = NSCursor.arrow
        let size = arrow.image.size
        let scale: CGFloat = 1.25
        // hotSpot is measured from the image's top-left; the context is y-up.
        let origin = CGPoint(x: point.x - arrow.hotSpot.x * scale, y: point.y - (size.height - arrow.hotSpot.y) * scale)
        arrow.image.draw(in: CGRect(origin: origin, size: CGSize(width: size.width * scale, height: size.height * scale)))
    }

    // MARK: Pill

    func drawPill(_ captured: CapturedFrame, in ctx: CGContext) {
        let image = captured.frame.image
        var rect = captured.frame.panelFrame
        // A capture taken in the same turn as a panel resize can predate the
        // new frame; draw it at its own size so it is never stretched.
        let size = CGSize(width: CGFloat(image.width) / stageScale, height: CGFloat(image.height) / stageScale)
        if abs(size.width - rect.width) > 0.5 || abs(size.height - rect.height) > 0.5 {
            rect = CGRect(origin: rect.origin, size: size)
        }
        ctx.saveGState()
        ctx.clip(to: screen) // the tucked half stays below the screen edge
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}
