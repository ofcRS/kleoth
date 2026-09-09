import SwiftUI

// MARK: - Geometry

/// The Kleoth lyre ("05 Green stone" from `app/branding-src/kleoth-lyre/`),
/// drawn natively so it scales crisply, follows the appearance, and can move.
///
/// The path data is the SVG's, verbatim (see `lyre-green.svg`); it is parsed
/// once into `Path`s in the SVG's own 206×266 user space (`viewBox 25 0 206 266`)
/// and scaled per render. Keeping the geometry in one place means the app mark,
/// the exported SVG and the menu-bar template can never drift apart.
enum KleothLyre {
    /// The SVG user-space box (`viewBox="25 0 206 266"`).
    static let viewBox = CGRect(x: 25, y: 0, width: 206, height: 266)

    /// The carved body: arms, soundbox and foot, one closed outline.
    static let body: Path = svgPath(
        "M69 45 C54 46 48 30 55 22 C65 10 86 20 91 40 C99 70 82 100 73 132 C65 160 75 181 94 181 C106 181 110 171 105 162 L151 162 C146 171 150 181 162 181 C181 181 191 160 183 132 C174 100 157 70 165 40 C170 20 191 10 201 22 C208 30 202 46 187 45 C179 44 177 35 181 31 C169 36 171 61 182 87 C191 110 210 143 207 169 C204 195 187 213 157 223 C157 232 164 237 176 238 L176 246 L80 246 L80 238 C92 237 99 232 99 223 C69 213 52 195 49 169 C46 143 65 110 74 87 C85 61 87 36 75 31 C79 35 77 44 69 45 Z"
    )
    /// The yoke the strings hang from.
    static let crossbar: Path = svgPath("M78 63 H178")
    /// The bridge on the soundbox.
    static let bridge: Path = svgPath("M107 162 H149")
    /// The faint highlight along the foot.
    static let footLine: Path = svgPath("M84 239 H172")

    /// Where the seven strings stand (x in user space); each runs from y 67 to 162.
    static let stringXs: [CGFloat] = [98, 108, 118, 128, 138, 148, 158]
    static let stringTop: CGFloat = 67
    static let stringMiddle: CGFloat = 114
    static let stringBottom: CGFloat = 162

    /// The three-stop material gradient, per appearance — the page's
    /// `--green1/2/3` for dark and light.
    static func material(for scheme: ColorScheme) -> (Color, Color, Color) {
        switch scheme {
        case .dark:
            return (Color(hex: 0xB0D1C3), Color(hex: 0x89B6A5), Color(hex: 0x608F80))
        default:
            return (Color(hex: 0x8DB7A4), Color(hex: 0x619480), Color(hex: 0x3F705E))
        }
    }

    /// A minimal absolute-command SVG path parser: `M L H Q C Z` are all the
    /// studies page uses, so relative commands and arcs are deliberately out.
    static func svgPath(_ d: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var current = CGPoint.zero

        func flush() {
            var i = 0
            switch command {
            case "M":
                while i + 1 < numbers.count {
                    current = CGPoint(x: numbers[i], y: numbers[i + 1])
                    // Only the first pair after M moves; subsequent pairs are implicit L.
                    if i == 0 { path.move(to: current) } else { path.addLine(to: current) }
                    i += 2
                }
            case "L":
                while i + 1 < numbers.count {
                    current = CGPoint(x: numbers[i], y: numbers[i + 1])
                    path.addLine(to: current)
                    i += 2
                }
            case "H":
                while i < numbers.count {
                    current = CGPoint(x: numbers[i], y: current.y)
                    path.addLine(to: current)
                    i += 1
                }
            case "Q":
                while i + 3 < numbers.count {
                    let control = CGPoint(x: numbers[i], y: numbers[i + 1])
                    current = CGPoint(x: numbers[i + 2], y: numbers[i + 3])
                    path.addQuadCurve(to: current, control: control)
                    i += 4
                }
            case "C":
                while i + 5 < numbers.count {
                    let c1 = CGPoint(x: numbers[i], y: numbers[i + 1])
                    let c2 = CGPoint(x: numbers[i + 2], y: numbers[i + 3])
                    current = CGPoint(x: numbers[i + 4], y: numbers[i + 5])
                    path.addCurve(to: current, control1: c1, control2: c2)
                    i += 6
                }
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll(keepingCapacity: true)
        }

        var token = ""
        func endToken() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }
        for ch in d {
            if ch.isLetter {
                endToken()
                flush()
                command = ch
            } else if ch == " " || ch == "," {
                endToken()
            } else if ch == "-" && !token.isEmpty {
                endToken()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        endToken()
        flush()
        return path
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Motion

/// How the strings move. Mirrors the studies page's `animate()`: endpoints stay
/// anchored, only each string's middle bends and catches light.
enum LyreMotion: Equatable {
    /// A slow breath rolling across the strings.
    case idle
    /// A fine, fast quiver — a meeting is being captured.
    case recording
    /// A wave travelling string to string — transcribing in the background.
    case processing
    /// No motion at all (also what every mode degrades to under Reduce Motion).
    case still

    /// The bend (in user-space points) and opacity of string `i` at time `t`,
    /// scaled by `intensity` (0…1). Formulas are the page's, verbatim.
    func sample(string i: Int, at t: Double, intensity: Double) -> (bend: CGFloat, opacity: Double) {
        let amount = intensity
        guard amount > 0 else { return (0, 0.75) }
        let fi = Double(i)
        switch self {
        case .recording:
            let bend = sin(t * 22 + fi * 0.9) * (2 + sin(t * 2.7 + fi)) * amount * 2.5
            return (CGFloat(bend), 0.7 + 0.2 * sin(t * 3 + fi))
        case .processing:
            let wave = pow(max(0, cos(t * 2.2 - fi * 0.55)), 5)
            let bend = sin(t * 18 + fi) * wave * amount * 5
            return (CGFloat(bend), 0.45 + wave * 0.55)
        case .idle:
            let breath = pow(max(0, sin(t * 0.9 - fi * 0.18)), 8)
            let bend = sin(t * 9 + fi) * breath * amount * 1.4
            return (CGFloat(bend), 0.65 + breath * 0.25)
        case .still:
            return (0, 0.75)
        }
    }
}

// MARK: - View

/// The lyre brand mark. Fits the lyre into its frame preserving the 206:266
/// aspect. Resting (`.still`, or Reduce Motion on) it is a plain `Canvas` that
/// schedules no redraws; in a live mode it rides `TimelineView(.animation)`.
struct LyreMark: View {
    var motion: LyreMotion = .idle
    /// 0…1, how far the strings bend. The page's default is 0.4.
    var intensity: Double = 0.4
    /// `nil` hides the mark from assistive tech (decorative); a string labels it.
    var accessibilityLabel: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectiveMotion: LyreMotion {
        reduceMotion ? .still : motion
    }

    var body: some View {
        Group {
            if effectiveMotion == .still {
                canvas(time: 0, motion: .still)
            } else {
                // 30 fps is plenty for a few bending strings and keeps the popover cheap.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate, motion: effectiveMotion)
                }
            }
        }
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityLabel(accessibilityLabel ?? "")
    }

    private func canvas(time: Double, motion: LyreMotion) -> some View {
        let (g1, g2, g3) = KleothLyre.material(for: colorScheme)
        return Canvas(rendersAsynchronously: false) { gc, size in
            let box = KleothLyre.viewBox
            let scale = min(size.width / box.width, size.height / box.height)
            let offset = CGPoint(
                x: (size.width - box.width * scale) / 2 - box.minX * scale,
                y: (size.height - box.height * scale) / 2 - box.minY * scale
            )
            let transform = CGAffineTransform(translationX: offset.x, y: offset.y)
                .scaledBy(x: scale, y: scale)

            // Body: the page's objectBoundingBox gradient (0,0)→(0.8,1).
            let body = KleothLyre.body.applying(transform)
            let bounds = body.boundingRect
            let gradient = Gradient(stops: [
                .init(color: g1, location: 0),
                .init(color: g2, location: 0.55),
                .init(color: g3, location: 1),
            ])
            gc.fill(
                body,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.minX + bounds.width * 0.8, y: bounds.maxY)
                )
            )
            gc.stroke(KleothLyre.crossbar.applying(transform), with: .color(g2),
                      style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round))
            gc.stroke(KleothLyre.footLine.applying(transform), with: .color(g1.opacity(0.5)),
                      lineWidth: 1.5 * scale)
            gc.stroke(KleothLyre.bridge.applying(transform), with: .color(g1),
                      lineWidth: 2 * scale)

            // Strings: anchored top and bottom, the middle control point bends.
            let style = StrokeStyle(lineWidth: max(0.5, 1.65 * scale), lineCap: .round)
            for (i, x) in KleothLyre.stringXs.enumerated() {
                let (bend, opacity) = motion.sample(string: i, at: time, intensity: intensity)
                var string = Path()
                string.move(to: CGPoint(x: x, y: KleothLyre.stringTop))
                string.addQuadCurve(
                    to: CGPoint(x: x, y: KleothLyre.stringBottom),
                    control: CGPoint(x: x + bend, y: KleothLyre.stringMiddle)
                )
                // The page stacks a group opacity of .8 under each string's own.
                gc.stroke(string.applying(transform), with: .color(g2.opacity(0.8 * opacity)),
                          style: style)
            }
        }
        .aspectRatio(KleothLyre.viewBox.width / KleothLyre.viewBox.height, contentMode: .fit)
    }
}
