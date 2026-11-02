import SwiftUI
import os.log

/// A hoverable dock item and its frame in the strip's root coordinate space
/// (top-left origin, points).
struct HoverTarget: Equatable {
    var id: String
    var title: String
    var frame: CGRect
}

/// Collects every hover target's frame from the SwiftUI tree.
struct HoverTargetsKey: PreferenceKey {
    static let defaultValue: [HoverTarget] = []
    static func reduce(value: inout [HoverTarget], nextValue: () -> [HoverTarget]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Registers this view as a hover target that shows `title` in a label.
    /// Apps use it now; folders and widgets can adopt it later.
    func dockHoverTarget(id: String, title: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: HoverTargetsKey.self,
                    value: [HoverTarget(id: id, title: title, frame: geo.frame(in: .named(DockHover.space)))]
                )
            }
        )
    }
}

/// Decides which item is under the cursor and shows its label in the
/// overlay panel.
///
/// Driven only by events: mouseMoved/mouseExited from the dock panel's
/// tracking area, frame changes from SwiftUI, and a one-shot check when the
/// reveal slide finishes. No timers. It never touches the reveal/hide logic.
final class DockHover {
    /// Name of the strip's root coordinate space.
    static let space = "dockRoot"

    /// Converts a rect in strip root coordinates to screen coordinates.
    var stripToScreen: ((CGRect) -> NSRect?)?
    private(set) var edge: DockEdge = .bottom

    private let overlay: OverlayPanel
    private var targets: [HoverTarget] = []
    /// Matches `DockModel.iconGap` so label hit-slop tracks the live gap.
    var iconGap: CGFloat = DockModel.Defaults.iconGap
    private var cursor: CGPoint?
    private var current: HoverTarget?
    /// Where the current label points (screen), to follow a magnified tile.
    private var currentAnchor: NSRect?

    /// Where a target is drawn right now: its magnified frame while
    /// magnifying, else its own frame. Used for hit-testing and labels.
    var displayFrame: ((HoverTarget) -> CGRect)?
    private let logger = Logger(subsystem: "com.james.portside", category: "DockHover")

    /// Gap between the label and the icon's far edge (top on the bottom
    /// dock, outer side on side docks). The strip has 6pt of padding on that
    /// side, so this leaves 4pt of air between the label and the dock.
    /// The group popover uses the same gap.
    static let labelGap: CGFloat = 10

    /// Gap for the hover bubble, measured from the native Dock: its tail tip
    /// sits 2.5pt past the dock's outer edge.
    static let bubbleGap: CGFloat = 7.5

    /// The dock's current background, so labels use the same glass or
    /// frost. Read each time a label opens.
    var look: (() -> DockLook?)?

    /// Labels stay hidden while true (a group popover is open in the spot
    /// where the label would appear).
    var isSuppressed = false {
        didSet {
            guard isSuppressed != oldValue else { return }
            current = nil
            if isSuppressed {
                overlay.dismiss()
            } else {
                evaluate()
            }
        }
    }

    /// Called after the hover targets' frames change (items added, removed,
    /// resized or reordered).
    var onTargetsChanged: (() -> Void)?

    /// The item under the cursor changed (nil when none). Reported even
    /// while labels are suppressed, so hovering another group tile can
    /// switch the open grid.
    var onHoveredTargetChanged: ((String?) -> Void)?
    private var hoveredID: String?

    /// Labels open on the far side of `edge`. Drops the current label so the
    /// next hover places it for the new orientation.
    func setEdge(_ newEdge: DockEdge) {
        edge = newEdge
        clear()
    }

    init(overlay: OverlayPanel) {
        self.overlay = overlay
    }

    func updateTargets(_ targets: [HoverTarget]) {
        self.targets = targets
        evaluate()
        onTargetsChanged?()
    }

    /// A target's frame in screen coordinates, or nil if it is not in the
    /// strip or the dock is off screen. Unmagnified.
    func screenFrame(forTargetID id: String) -> NSRect? {
        guard let target = targets.first(where: { $0.id == id }) else { return nil }
        return stripToScreen?(target.frame)
    }

    /// Where a target is drawn on screen right now (magnified if it is),
    /// using the magnifier's target values rather than mid-spring ones.
    func displayScreenFrame(forTargetID id: String) -> NSRect? {
        guard let target = targets.first(where: { $0.id == id }) else { return nil }
        return stripToScreen?(frame(of: target))
    }

    func cursorMoved(to point: CGPoint) {
        cursor = point
        evaluate()
    }

    /// Cursor left the dock, the dock is hiding, or a click started (labels
    /// hide while clicking, dragging, or showing a context menu).
    func clear() {
        cursor = nil
        evaluate()
    }

    /// Follow the hovered icon's actual rendered position, including every
    /// spring frame. Moving the label immediately avoids a second animation.
    func iconPresented(id: String, frame: CGRect) {
        guard !isSuppressed, current?.id == id,
              let anchor = stripToScreen?(frame), anchor != currentAnchor else { return }
        currentAnchor = anchor
        overlay.reanchor(anchor)
    }

    func baseFrame(for id: String) -> CGRect? {
        targets.first { $0.id == id }?.frame
    }

    private func evaluate() {
        let slop = -iconGap / 2
        let hit = cursor.flatMap { point in
            // Tiles have a small gap between them. Extending each hit rect by
            // half of it along the dock means sweeping across icons swaps the
            // label without a flicker through "nothing hovered".
            targets.first {
                frame(of: $0).insetBy(dx: edge.isVertical ? 0 : slop, dy: edge.isVertical ? slop : 0).contains(point)
            }
        }
        if hit?.id != hoveredID {
            hoveredID = hit?.id
            onHoveredTargetChanged?(hoveredID)
        }
        guard !isSuppressed else { return }
        if hit == current { return }
        current = hit

        guard let hit, let anchor = stripToScreen?(frame(of: hit)) else {
            currentAnchor = nil
            overlay.dismiss()
            return
        }
        currentAnchor = anchor
        let label = AnyView(DockLabel(title: hit.title, pointing: edge, look: look?()))
        overlay.present(label, anchor: anchor, edge: edge, gap: Self.bubbleGap)
        logger.debug("label: \(hit.title, privacy: .public)")
    }

    private func frame(of target: HoverTarget) -> CGRect {
        displayFrame?(target) ?? target.frame
    }
}

/// Native-Dock-style name label: a speech bubble whose small tail points at
/// the icon. Its background is the dock's own (Liquid Glass or Solid, with
/// the same frost and tint); without a look (the drag-out label)
/// it uses the default glass. Without `pointing` it has no tail.
struct DockLabel: View {
    let title: String
    /// The dock's edge. The tail sits on the side facing the dock.
    var pointing: DockEdge?
    var look: DockLook?

    private static let tail: CGFloat = 7

    private static var defaultLook: DockLook {
        DockLook(cornerRadius: 0)
    }

    var body: some View {
        Text(title)
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 320)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .padding(tailSide, pointing == nil ? 0 : Self.tail)
            .fixedSize()
            .dockBackground(look ?? Self.defaultLook, in: LabelBubble(edge: pointing, tail: Self.tail))
    }

    private var tailSide: Edge.Set {
        switch pointing {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        case nil: []
        }
    }
}

/// Rounded rectangle with a small rounded tail on the side facing the dock.
/// Drawn once for a tail at the bottom, then rotated for the side docks.
private struct LabelBubble: InsettableShape {
    let edge: DockEdge?
    let tail: CGFloat
    var inset: CGFloat = 0
    private let radius: CGFloat = 11
    private let tailHalfWidth: CGFloat = 12

    func inset(by amount: CGFloat) -> LabelBubble {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in fullRect: CGRect) -> Path {
        let rect = fullRect.insetBy(dx: inset, dy: inset)
        let radius = max(0, self.radius - inset)
        guard let edge else {
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        }
        let vertical = edge.isVertical
        let width = vertical ? rect.height : rect.width
        let height = vertical ? rect.width : rect.height
        let body = height - max(0, tail - inset)
        let mid = width / 2
        let r = min(radius, body / 2)

        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: r), radius: r)
        p.addArc(tangent1End: CGPoint(x: width, y: body), tangent2End: CGPoint(x: width - r, y: body), radius: r)
        p.addLine(to: CGPoint(x: mid + tailHalfWidth, y: body))
        p.addQuadCurve(to: CGPoint(x: mid + 1.5, y: height - 0.8), control: CGPoint(x: mid + tailHalfWidth * 0.35, y: body))
        p.addQuadCurve(to: CGPoint(x: mid - 1.5, y: height - 0.8), control: CGPoint(x: mid, y: height + 0.6))
        p.addQuadCurve(to: CGPoint(x: mid - tailHalfWidth, y: body), control: CGPoint(x: mid - tailHalfWidth * 0.35, y: body))
        p.addArc(tangent1End: CGPoint(x: 0, y: body), tangent2End: CGPoint(x: 0, y: body - r), radius: r)
        p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: r, y: 0), radius: r)
        p.closeSubpath()

        switch edge {
        case .bottom:
            return p.offsetBy(dx: rect.minX, dy: rect.minY)
        case .left:   // tail on the left: local y runs from the right edge to the left
            return p.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height + rect.minX, ty: rect.minY))
        case .right:
            return p.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: rect.minX, ty: rect.minY))
        }
    }
}
