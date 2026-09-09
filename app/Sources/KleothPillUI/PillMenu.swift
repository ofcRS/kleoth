import AppKit
import SwiftUI
import KleothCore

// The pill's menu (interaction demo, 2026-09-08): the pill's own dark panel,
// not an `NSMenu`. AppKit refuses to pop a menu up for an app that is not
// active — and Kleoth never is while its pill is up — and activating for the
// menu's lifetime steals the caret from the app the user is dictating into.
// A `.nonactivatingPanel` with SwiftUI rows has neither problem: it appears
// beside the capsule with the pill's own spring, its rows light up under a
// pointer that belongs to another app (the same `.activeAlways` tracking the
// pill uses), and the app underneath never loses focus.

/// One row of the menu.
struct PillMenuEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case action(DictationPillAction)
        /// Expands the microphone list inline.
        case microphones
        case separator
        /// Non-interactive caption ("In use: …").
        case caption
    }

    var id: String
    var kind: Kind
    var title: String = ""
    var subtitle: String?
    var symbol: String?
    var checked = false
    var enabled = true
    /// Device rows sit under the Microphone header.
    var indented = false
    /// A tint for the glyph (the record glyph is red, like on the dock).
    var tint: Color?
}

/// What `PillMenuView` renders. The controller builds the entries from the
/// host's `PillMenuContent` and rebuilds them when the microphone section is
/// expanded or collapsed.
@MainActor
final class PillMenuModel: ObservableObject {
    @Published var entries: [PillMenuEntry] = []
    @Published var isPresented = false
    /// Pointer in the menu's root space (y down), nil when off the panel.
    @Published var pointer: CGPoint?
    @Published var microphonesExpanded = false
    /// Which edge the pill sits on: the menu scales in from that side.
    @Published var edge: PillGeometry.Edge = .bottom
}

/// The floating menu window. Same flags as `DictationPanel`, same reasons.
final class PillMenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        // The pill is dark by design in every phase, whatever the system
        // appearance (`PillStyle`), and a Liquid Glass surface takes its tone
        // from the WINDOW's appearance: light-mode glass over a light page
        // rendered near-white with white ink on it. Pin the panel dark.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isRestorable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The menu's look: the pill's dark surface, rows with a glyph, a title and
/// an optional subtitle, hover highlight from the shared pointer.
struct PillMenuView: View {
    @ObservedObject var model: PillMenuModel
    let onSelect: (PillMenuEntry) -> Void

    static let width: CGFloat = 244
    static let shadowPadding: CGFloat = 24
    static let space = "kleoth.pill.menu"

    var body: some View {
        // Root = clear + overlay, aligned to the pill's side, so a point or
        // two of difference between the computed and the laid-out height
        // lands on the far side (and the root never resizes the panel — see
        // the note in `DictationPillView.body`).
        Color.clear.overlay(alignment: alignment) { menu }
    }

    private var alignment: Alignment {
        switch model.edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.entries) { entry in
                row(entry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(PillMenuStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PillStyle.rim, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .scaleEffect(model.isPresented ? 1 : 0.92, anchor: anchor)
        .opacity(model.isPresented ? 1 : 0)
        .padding(Self.shadowPadding)
        .coordinateSpace(name: Self.space)
    }

    /// The menu grows out of the pill's side.
    private var anchor: UnitPoint {
        switch model.edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    @ViewBuilder
    private func row(_ entry: PillMenuEntry) -> some View {
        switch entry.kind {
        case .separator:
            Rectangle()
                .fill(PillStyle.ink.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        case .caption:
            Text(entry.title)
                .font(.caption)
                .foregroundStyle(PillStyle.ink.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
        case .action, .microphones:
            PillMenuRow(entry: entry, pointer: model.pointer, expanded: model.microphonesExpanded) {
                onSelect(entry)
            }
        }
    }
}

/// One interactive row: glyph · title/subtitle · trailing check or chevron.
private struct PillMenuRow: View {
    let entry: PillMenuEntry
    let pointer: CGPoint?
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let hot = entry.enabled && (pointer.map { proxy.frame(in: .named(PillMenuView.space)).contains($0) } ?? false)
            Button(action: action) {
                HStack(spacing: 10) {
                    ZStack {
                        if let symbol = entry.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(entry.tint ?? PillStyle.ink.opacity(0.85))
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(PillStyle.ink.opacity(entry.enabled ? 1 : 0.4))
                            .lineLimit(1)
                        if let subtitle = entry.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(PillStyle.ink.opacity(entry.enabled ? 0.55 : 0.3))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 6)
                    trailing
                }
                .padding(.leading, entry.indented ? 24 : 6)
                .padding(.trailing, 8)
                .frame(height: entry.subtitle == nil ? 30 : 38)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(hot ? 0.13 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PillMenuRowStyle())
            .disabled(!entry.enabled)
            .animation(.easeOut(duration: 0.1), value: hot)
            .onChange(of: hot) { _, isHot in
                if isHot { NSCursor.pointingHand.set() } else if pointer == nil { NSCursor.arrow.set() }
            }
        }
        .frame(height: entry.subtitle == nil ? 30 : 38)
    }

    @ViewBuilder
    private var trailing: some View {
        switch entry.kind {
        case .microphones:
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PillStyle.ink.opacity(0.5))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(.spring(duration: 0.22, bounce: 0.2), value: expanded)
        case .action:
            if entry.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        case .separator, .caption:
            EmptyView()
        }
    }
}

private struct PillMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

enum PillMenuStyle {
    /// A touch more opaque than the capsule: rows of text need a steadier ground.
    static let surface = Color(white: 0.1).opacity(0.94)
}
