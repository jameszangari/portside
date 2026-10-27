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
    private var cursor: CGPoint?
    private var current: HoverTarget?
    private let logger = Logger(subsystem: "com.james.portside", category: "DockHover")

    /// Gap between the label and the icon's far edge (top on the bottom
    /// dock, outer side on side docks). The strip has 6pt of padding on that
    /// side, so this leaves 4pt of air between the label and the dock.
    private let labelGap: CGFloat = 10

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

    private func evaluate() {
        let slop = -DockMetrics.spacing / 2
        let hit = cursor.flatMap { point in
            // Tiles have a small gap between them. Extending each hit rect by
            // half of it along the dock means sweeping across icons swaps the
            // label without a flicker through "nothing hovered".
            targets.first {
                $0.frame.insetBy(dx: edge.isVertical ? 0 : slop, dy: edge.isVertical ? slop : 0).contains(point)
            }
        }
        guard hit != current else { return }
        current = hit

        guard let hit, let anchor = stripToScreen?(hit.frame) else {
            overlay.dismiss()
            return
        }
        overlay.present(AnyView(DockLabel(title: hit.title)), anchor: anchor, edge: edge, gap: labelGap)
        logger.debug("label: \(hit.title, privacy: .public)")
    }
}

/// Native-Dock-style name label: a small dark rounded pill.
struct DockLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 320)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(white: 0.12, opacity: 0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .fixedSize()
            .environment(\.colorScheme, .dark)
    }
}
