import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The live answers to the trigger checks, all public API and all read only.
/// Each runs when a trigger fires or a rehide is due, never on a timer.
@MainActor
final class LiveMenuBarTriggerEnvironment: MenuBarTriggerEnvironment {
    private let busy: @MainActor () -> Bool
    private let editing: @MainActor () -> Bool

    init(busy: @escaping @MainActor () -> Bool, editing: @escaping @MainActor () -> Bool) {
        self.busy = busy
        self.editing = editing
    }

    /// An open menu is a window at the pop-up menu level. Layer and owner are
    /// readable without Screen Recording; titles are not and are not read.
    func menuIsOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == level }
    }

    func mouseButtonDown() -> Bool { NSEvent.pressedMouseButtons != 0 }
    func secureInputActive() -> Bool { IsSecureEventInputEnabled() }
    func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    func layoutIsBusy() -> Bool { busy() }
    func layoutIsEditing() -> Bool { editing() }
}

/// Finds the empty part of the menu bar from public data: the bar band and
/// notch from `NSScreen`, status item windows from the window list (bounds
/// need no permission), and the frontmost app's menu titles from
/// Accessibility. Anything it cannot read counts as occupied, so a doubt
/// never reveals.
@MainActor
final class LiveMenuBarEmptyAreaProbe: MenuBarEmptyAreaProbe {
    func isEmptyBar(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let thickness = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - thickness, width: screen.frame.width, height: thickness)
        guard band.contains(point) else { return false }
        var notch: CGRect?
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGRect(x: left.maxX, y: band.minY, width: right.minX - left.maxX, height: band.height)
        }
        guard let menusEnd = appMenuEnd(), let items = statusItemRects(band: band) else { return false }
        let menus = CGRect(x: screen.frame.minX, y: band.minY, width: max(menusEnd - screen.frame.minX, 0), height: band.height)
        return MenuBarBarGeometry.isEmpty(point: point, band: band, notch: notch, occupied: [menus] + items)
    }

    /// Right edge of the frontmost app's last menu title (the x axis is the
    /// same in Accessibility and AppKit). Nil if Accessibility cannot read it.
    private func appMenuEnd() -> CGFloat? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let titles = children as? [AXUIElement], !titles.isEmpty else { return nil }
        var maxX: CGFloat = 0
        for title in titles {
            guard let frame = Self.frame(of: title) else { return nil }
            maxX = max(maxX, frame.maxX)
        }
        return maxX
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Windows at the status level inside the bar band, converted from the
    /// window list's top-left origin to AppKit's bottom-left.
    private func statusItemRects(band: CGRect) -> [CGRect]? {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let level = Int(CGWindowLevelForKey(.statusWindow))
        var rects: [CGRect] = []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == level {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { continue }
            let rect = CGRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
            if rect.intersects(band) { rects.append(rect) }
        }
        return rects
    }
}
