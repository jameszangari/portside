import AppKit
import SwiftUI

/// What Portside's own menu bar control looks like. `off` removes it; the
/// shelf then opens from an empty-bar click or a shortcut.
enum MenuBarControlIcon: String, Codable, CaseIterable, Identifiable {
    case eye, chevron, dots, grid, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .eye: "Eye"
        case .chevron: "Chevron"
        case .dots: "Dots"
        case .grid: "Grid"
        case .off: "No icon"
        }
    }

    /// The state, not the action: closed while the items are hidden.
    func symbol(hidden: Bool) -> String? {
        switch self {
        case .eye: hidden ? "eye.slash" : "eye"
        case .chevron: hidden ? "chevron.left.2" : "chevron.right.2"
        case .dots: hidden ? "ellipsis.circle" : "ellipsis.circle.fill"
        case .grid: hidden ? "square.grid.2x2" : "square.grid.2x2.fill"
        case .off: nil
        }
    }
}

enum MenuBarBarStyle: String, Codable, CaseIterable, Identifiable {
    case system, dock, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .dock: "Match Dock"
        case .custom: "Custom"
        }
    }
}

/// The outline drawn behind the real menu bar.
enum MenuBarShape: String, Codable, CaseIterable, Identifiable {
    case none, full, notch, pills
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .full: "Full bar"
        case .notch: "Split at the notch"
        case .pills: "Pills around items"
        }
    }
}

/// Saved in dock.json under `menuBarTriggers.look`. Every key is optional.
struct MenuBarLook: Codable, Equatable {
    static let cornerRange: ClosedRange<Double> = 0...28
    static let iconSizeRange: ClosedRange<Double> = 16...32

    var controlIcon = MenuBarControlIcon.eye
    var barStyle = MenuBarBarStyle.system
    var barBackground = DockBackground()
    var barCornerRadius = 10.0
    var barIconSize = 22.0
    var shape = MenuBarShape.none
    var background = DockBackground()
    /// Past half the bar's height a shape is a full pill.
    var cornerRadius = 14.0
    var shadow = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case controlIcon, barStyle, barBackground, barCornerRadius, barIconSize, shape, background, cornerRadius, shadow
    }

    /// Earlier builds saved a solid color only.
    private enum LegacyKeys: String, CodingKey { case barFill, fill }

    private static func solid(_ fill: SolidBackground) -> DockBackground {
        var background = DockBackground()
        background.style = .solid
        background.solid = fill
        return background
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controlIcon = c.value(.controlIcon, or: MenuBarControlIcon.eye)
        barStyle = c.value(.barStyle, or: MenuBarBarStyle.system)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldBar = (try? legacy.decodeIfPresent(SolidBackground.self, forKey: .barFill)).flatMap { $0 }
        barBackground = c.value(.barBackground, or: oldBar.map(Self.solid) ?? DockBackground())
        barCornerRadius = c.value(.barCornerRadius, or: 10.0)
        barIconSize = c.value(.barIconSize, or: 22.0)
        shape = c.value(.shape, or: MenuBarShape.none)
        let oldFill = (try? legacy.decodeIfPresent(SolidBackground.self, forKey: .fill)).flatMap { $0 }
        background = c.value(.background, or: oldFill.map(Self.solid) ?? DockBackground())
        cornerRadius = c.value(.cornerRadius, or: 14.0)
        shadow = c.value(.shadow, or: false)
        self = sanitized
    }

    var sanitized: MenuBarLook {
        var copy = self
        copy.barCornerRadius = min(max(barCornerRadius, Self.cornerRange.lowerBound), Self.cornerRange.upperBound)
        copy.cornerRadius = min(max(cornerRadius, Self.cornerRange.lowerBound), Self.cornerRange.upperBound)
        copy.barIconSize = min(max(barIconSize, Self.iconSizeRange.lowerBound), Self.iconSizeRange.upperBound)
        return copy
    }

    /// How the Portside Bar draws, given the Dock's current look.
    func panelLook(dock: DockLook) -> MenuBarOverflowPanel.Look {
        switch barStyle {
        case .system:
            return .init(dock: nil, cornerRadius: barCornerRadius, iconSize: barIconSize)
        case .dock:
            return .init(dock: dock, cornerRadius: dock.cornerRadius, iconSize: barIconSize)
        case .custom:
            return .init(dock: DockLook(background: barBackground, cornerRadius: barCornerRadius), cornerRadius: barCornerRadius, iconSize: barIconSize)
        }
    }
}

/// Where the outlines go, in a display's bar with its origin top-left. Pure.
enum MenuBarStylePlan {
    private static let pillInset: CGFloat = 2
    private static let pillPadding: CGFloat = 8
    private static let edge: CGFloat = 4

    static func rects(shape: MenuBarShape, size: CGSize, notch: ClosedRange<CGFloat>?, menusEnd: CGFloat?, itemsStart: CGFloat?) -> [CGRect] {
        let bar = CGRect(origin: .zero, size: size)
        switch shape {
        case .none:
            return []
        case .full:
            return [bar]
        case .notch:
            guard let notch else { return [bar] }
            return [
                CGRect(x: 0, y: 0, width: notch.lowerBound, height: size.height),
                CGRect(x: notch.upperBound, y: 0, width: size.width - notch.upperBound, height: size.height),
            ]
        case .pills:
            let height = size.height - pillInset * 2
            var result: [CGRect] = []
            if let menusEnd, menusEnd > edge {
                let right = min(menusEnd + pillPadding, notch.map { $0.lowerBound - edge } ?? size.width)
                result.append(CGRect(x: edge, y: pillInset, width: right - edge, height: height))
            }
            if let itemsStart, itemsStart < size.width {
                let left = max(itemsStart - pillPadding, notch.map { $0.upperBound + edge } ?? 0)
                result.append(CGRect(x: left, y: pillInset, width: size.width - edge - left, height: height))
            }
            return result.filter { $0.width > 0 }
        }
    }
}

/// Draws the chosen outline just under the real menu bar's items. A plain
/// window below their level, so it needs no permission and takes no clicks.
/// Geometry is read only for pills, and only while they are chosen.
@MainActor
final class MenuBarStyleOverlay {
    private struct Layout: Equatable {
        var rects: [CGRect]
        var look: DockLook
        var shadow: Bool
    }

    private var look = MenuBarLook()
    private var panels: [NSPanel] = []
    private var layouts: [Layout] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private static let pillRefresh: TimeInterval = 1.5

    func apply(_ next: MenuBarLook) {
        let changedShape = next.shape != look.shape
        look = next
        if changedShape || observers.isEmpty { rewatch() }
        refresh()
    }

    func stop() {
        look = MenuBarLook()
        rewatch()
        refresh()
    }

    private func rewatch() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        timer?.invalidate()
        timer = nil
        guard look.shape != .none else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let watched: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        for (center, name) in watched {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append((center, token))
        }
        guard look.shape == .pills else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pillRefresh, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        task?.cancel()
        guard look.shape != .none else {
            task = nil
            layout([])
            return
        }
        let needsItems = look.shape == .pills
        // Read here: the frontmost app is only current on the main thread.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Portside's own menus only answer Accessibility on its main thread.
        let frontIsSelf = front == ProcessInfo.processInfo.processIdentifier
        let ownMenus = needsItems && frontIsSelf ? MenuBarFrontMenus.end(pid: front) : nil
        task = Task { [weak self] in
            let reading = needsItems ? await Task.detached(priority: .utility) { (frontIsSelf ? ownMenus : MenuBarFrontMenus.end(pid: front), MenuBarDrawnOwners.items()) }.value : (nil, nil)
            guard !Task.isCancelled else { return }
            self?.layout(reading.0, reading.1)
        }
    }

    private func layout(_ menusEnd: CGFloat?, _ items: [MenuBarDrawnOwners.Item]?) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let fill = DockLook(background: look.background, cornerRadius: look.cornerRadius)
        layout(NSScreen.screens.map { screen in
            let frame = Self.barFrame(on: screen)
            var notch: ClosedRange<CGFloat>?
            if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, left.maxX < right.minX {
                notch = (left.maxX - frame.minX)...(right.minX - frame.minX)
            }
            let top = primaryMaxY - screen.frame.maxY
            let starts = (items ?? []).filter {
                $0.frame.width > 0 && $0.frame.midX >= frame.minX && $0.frame.midX <= frame.maxX && $0.frame.midY >= top && $0.frame.midY <= top + frame.height + 8
            }.map(\.frame.minX)
            let end = menusEnd.flatMap { $0 > frame.minX && $0 <= frame.maxX ? $0 - frame.minX : nil }
            let rects = MenuBarStylePlan.rects(shape: look.shape, size: frame.size, notch: notch, menusEnd: end, itemsStart: starts.min().map { $0 - frame.minX })
            return (frame, Layout(rects: rects, look: fill, shadow: look.shadow))
        })
    }

    private func layout(_ wanted: [(CGRect, Layout)]) {
        while panels.count > wanted.count { panels.removeLast().orderOut(nil) }
        while panels.count < wanted.count { panels.append(Self.makePanel()) }
        let previous = layouts
        layouts = wanted.map(\.1)
        for (index, (frame, layout)) in wanted.enumerated() {
            let panel = panels[index]
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            guard index >= previous.count || previous[index] != layout || panel.contentView == nil else { continue }
            panel.contentView = NSHostingView(rootView: MenuBarStyleContent(rects: layout.rects, look: layout.look, shadow: layout.shadow))
            panel.orderFrontRegardless()
        }
    }

    private static func barFrame(on screen: NSScreen) -> CGRect {
        let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.fullScreenNone, .ignoresCycle, .stationary, .canJoinAllSpaces]
        return panel
    }
}

private struct MenuBarStyleContent: View {
    let rects: [CGRect]
    let look: DockLook
    let shadow: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(rects.indices, id: \.self) { index in
                let rect = rects[index]
                Color.clear
                    .frame(width: rect.width, height: rect.height)
                    .dockBackground(look, in: RoundedRectangle(cornerRadius: min(look.cornerRadius, rect.height / 2), style: .continuous), shadow: shadow)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }
}
