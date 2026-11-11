import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One on-screen window, for telling open menus apart. Top-left coordinates.
struct MenuBarWindowInfo: Equatable {
    let id: CGWindowID
    let layer: Int
    let bounds: CGRect
}

/// Which windows are menus hanging from a menu bar. Pure.
enum MenuBarOpenMenus {
    /// Room for a menu's shadow and rounded edge.
    static let attachmentSlack: CGFloat = 8

    static func candidates(_ windows: [MenuBarWindowInfo], strips: [CGRect], menuLayers: Set<Int>) -> Set<CGWindowID> {
        Set(windows.filter { window in
            menuLayers.contains(window.layer) && strips.contains { strip in
                abs(window.bounds.minY - strip.maxY) <= attachmentSlack
                    && window.bounds.maxX > strip.minX && window.bounds.minX < strip.maxX
            }
        }.map(\.id))
    }
}

/// The live answers to the trigger checks, all public API and all read only.
/// Each runs when a trigger fires or a rehide is due, never on a timer.
@MainActor
final class LiveMenuBarTriggerEnvironment: MenuBarTriggerEnvironment {
    private let busy: @MainActor () -> Bool
    private let editing: @MainActor () -> Bool
    /// Menu-shaped windows that were already up when the shelf opened.
    private var baseline = Set<CGWindowID>()

    init(busy: @escaping @MainActor () -> Bool, editing: @escaping @MainActor () -> Bool) {
        self.busy = busy
        self.editing = editing
    }

    private static var menuLayers: Set<Int> {
        let popup = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return [popup, popup - 1, Int(CGWindowLevelForKey(.statusWindow)), Int(CGWindowLevelForKey(.mainMenuWindow))]
    }

    private func onScreenWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private func menuWindows() -> Set<CGWindowID> {
        let own = ProcessInfo.processInfo.processIdentifier
        let windows: [MenuBarWindowInfo] = onScreenWindows().compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return MenuBarWindowInfo(id: id, layer: layer, bounds: bounds)
        }
        return MenuBarOpenMenus.candidates(windows, strips: menuBarStrips(), menuLayers: Self.menuLayers)
    }

    private func menuBarStrips() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            let height = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            return CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY, width: screen.frame.width, height: height)
        }
    }

    func noteRevealed() { baseline = menuWindows() }

    /// A new menu-shaped window hanging from a bar since the shelf opened.
    func menuIsOpen() -> Bool {
        if MenuBarOverflowPanel.ownMenuIsUp { return true }
        let now = menuWindows()
        baseline.formIntersection(now)
        return !now.subtracting(baseline).isEmpty
    }

    func pointerInMenuBar() -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let point = NSEvent.mouseLocation
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return menuBarStrips().contains { $0.contains(flipped) }
    }

    /// The Dock never becomes the active app, yet a click on it is a move away.
    func cursorOverActiveAppOrDock() -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let point = NSEvent.mouseLocation
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let own = ProcessInfo.processInfo.processIdentifier
        let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
        for window in onScreenWindows() {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer < cursorLayer, (window[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.contains(flipped),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.bundleIdentifier == "com.apple.dock" { return true }
            return app.isActive && app.activationPolicy == .regular
        }
        return false
    }

    func mouseButtonDown() -> Bool { NSEvent.pressedMouseButtons != 0 }
    func secureInputActive() -> Bool { IsSecureEventInputEnabled() }
    func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    func layoutIsBusy() -> Bool { busy() }
    func layoutIsEditing() -> Bool { editing() }
}

/// The frontmost app's menu titles, from Accessibility.
enum MenuBarFrontMenus {
    /// Right edge of the last title (the x axis is the same in Accessibility
    /// and AppKit). Nil if Accessibility cannot read it.
    nonisolated static func end(pid: pid_t?) -> CGFloat? {
        guard let pid else { return nil }
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
            guard let frame = frame(of: title) else { return nil }
            maxX = max(maxX, frame.maxX)
        }
        return maxX
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
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
}

/// Finds the empty part of the menu bar from public data: the bar band and
/// notch from `NSScreen`, status item windows from the window list (bounds
/// need no permission), and the frontmost app's menu titles from
/// Accessibility. Anything it cannot read counts as occupied, so a doubt
/// never reveals.
@MainActor
final class LiveMenuBarEmptyAreaProbe: MenuBarEmptyAreaProbe {
    func isEmptyBar(_ point: CGPoint) -> Bool { isEmpty(point, notchCounts: false) }
    func isClickableBar(_ point: CGPoint) -> Bool { isEmpty(point, notchCounts: true) }

    private func isEmpty(_ point: CGPoint, notchCounts: Bool) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let thickness = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - thickness, width: screen.frame.width, height: thickness)
        guard band.contains(point) else { return false }
        var notch: CGRect?
        if !notchCounts, screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGRect(x: left.maxX, y: band.minY, width: right.minX - left.maxX, height: band.height)
        }
        guard let menusEnd = MenuBarFrontMenus.end(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier), let items = statusItemRects(screen: screen, band: band) else { return false }
        // App menus are only drawn on the active display's bar.
        let menusHere = menusEnd > screen.frame.minX && menusEnd <= screen.frame.maxX
        let menus = CGRect(x: screen.frame.minX, y: band.minY, width: menusHere ? menusEnd - screen.frame.minX : 0, height: band.height)
        guard MenuBarBarGeometry.isEmpty(point: point, band: band, notch: notch, occupied: [menus] + items) else { return false }
        return !foreignElement(at: point)
    }

    /// Every drawn item on this display, from MenuBarAgent's own windows.
    /// Status items have no windows of their own on macOS 27. Nil while the bar
    /// is mid-change, so a doubt never reveals. Cached briefly for hover only.
    private func statusItemRects(screen: NSScreen, band: CGRect) -> [CGRect]? {
        guard let primary = NSScreen.screens.first else { return nil }
        let now = Date()
        let all: [MenuBarDrawnOwners.Item]
        if let cached, now.timeIntervalSince(cached.at) < 0.1 {
            all = cached.items
        } else {
            guard let read = MenuBarDrawnOwners.items() else { return nil }
            all = read
            cached = (now, read)
        }
        let top = primary.frame.maxY - screen.frame.maxY
        let here = all.filter { $0.frame.midY >= top && $0.frame.midY <= top + band.height + 8 && $0.frame.midX >= screen.frame.minX && $0.frame.midX <= screen.frame.maxX }
        guard !here.contains(where: { $0.frame.width <= 0 || $0.frame.height <= 0 }) else { return nil }
        return here.map { CGRect(x: $0.frame.minX, y: band.minY, width: $0.frame.width, height: band.height) }
    }

    func discardCache() { cached = nil }

    /// A notch overlay or other widget sitting in the bar is not empty bar.
    private func foreignElement(at point: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(primary.frame.maxY - point.y), &element) == .success, let element,
              AXUIElementGetPid(element, &pid) == .success else { return false }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == kAXMenuBarRole { return false }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return id != "com.apple.MenuBarAgent" && id != "com.apple.systemuiserver" && pid != NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private var cached: (at: Date, items: [MenuBarDrawnOwners.Item])?
}
