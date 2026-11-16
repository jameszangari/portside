import AppKit
import ApplicationServices

/// Native Dock bounds from the Dock's public AX list element, read only on
/// overlay entry. Pure cover math is separate so it can be tested.
enum DockGeometry {
    /// The Dock's AXList frames in Cocoa global coordinates (bottom-left origin).
    static func frames() -> [CGRect] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let primary = NSScreen.screens.first else { return [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return [] }
        return elements.compactMap { element in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole as String, let frame = frame(of: element) else { return nil }
            return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// Cover rectangle for one display, in Cocoa coordinates.
enum DockCover {
    enum Edge: String { case bottom, left, right }

    /// Grows the Dock frame by `margin` on its open sides, flush to the nearest
    /// screen edge, clamped to the screen. Nil when the Dock is not on `screen`.
    /// A Dock still sliding in (partly or fully past the edge) is placed at its
    /// settled position, so the first read on entry covers its full size.
    static func rect(dock: CGRect, screen: CGRect, margin: CGFloat) -> (CGRect, Edge)? {
        // A wide Dock sits at the bottom; a tall one on the nearer side.
        let edge: Edge = dock.width >= dock.height ? .bottom
            : abs(dock.midX - screen.minX) <= abs(dock.midX - screen.maxX) ? .left : .right
        var settled = dock
        switch edge {
        case .bottom:
            guard dock.maxX > screen.minX, dock.minX < screen.maxX,
                  abs(dock.minY - screen.minY) <= dock.height * 2 else { return nil }
            settled.origin.y = max(dock.minY, screen.minY)
        case .left:
            guard dock.maxY > screen.minY, dock.minY < screen.maxY,
                  abs(dock.minX - screen.minX) <= dock.width * 2 else { return nil }
            settled.origin.x = max(dock.minX, screen.minX)
        case .right:
            guard dock.maxY > screen.minY, dock.minY < screen.maxY,
                  abs(dock.maxX - screen.maxX) <= dock.width * 2 else { return nil }
            settled.origin.x = min(dock.minX, screen.maxX - dock.width)
        }
        let overlap = settled.intersection(screen)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
        var cover = overlap.insetBy(dx: -margin, dy: -margin)
        switch edge {
        case .bottom: cover.size.height += cover.minY - screen.minY; cover.origin.y = screen.minY
        case .left: cover.size.width += cover.minX - screen.minX; cover.origin.x = screen.minX
        case .right: cover.size.width = screen.maxX - cover.minX
        }
        return (cover.intersection(screen), edge)
    }

    /// While hovered, the Dock draws icon labels in its own layer-20 window just
    /// past the Dock, so the cover grows toward the screen center to hide them.
    static func hovered(_ cover: CGRect, edge: Edge, clearance: CGFloat, screen: CGRect) -> CGRect {
        var grown = cover
        switch edge {
        case .bottom: grown.size.height += clearance
        case .left: grown.size.width += clearance
        case .right: grown.origin.x -= clearance; grown.size.width += clearance
        }
        return grown.intersection(screen)
    }

    /// Used when AX geometry is unavailable: the strip the Dock reserves, or a
    /// full-width bottom strip when the Dock reserves nothing (autohide).
    static func fallback(screen: CGRect, visible: CGRect, height: CGFloat) -> CGRect {
        if visible.minY > screen.minY {
            return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: visible.minY - screen.minY)
        }
        if visible.minX > screen.minX {
            return CGRect(x: screen.minX, y: screen.minY, width: visible.minX - screen.minX, height: screen.height)
        }
        if visible.maxX < screen.maxX {
            return CGRect(x: visible.maxX, y: screen.minY, width: screen.maxX - visible.maxX, height: screen.height)
        }
        return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(height, screen.height))
    }
}
