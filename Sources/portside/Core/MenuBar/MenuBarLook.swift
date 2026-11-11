import AppKit
import SwiftUI

/// What Portside's own menu bar control looks like. `off` removes it; the
/// shelf then opens from an empty-bar click or a shortcut.
enum MenuBarControlIcon: String, Codable, CaseIterable, Identifiable {
    case eye, chevron, dots, grid, off, symbol, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .eye: "Eye"
        case .chevron: "Chevron"
        case .dots: "Dots"
        case .grid: "Grid"
        case .off: "No icon"
        case .symbol: "Symbol"
        case .image: "Your image"
        }
    }

    /// The state, not the action: closed while the items are hidden.
    func symbol(hidden: Bool) -> String? {
        switch self {
        case .eye: hidden ? "eye.slash" : "eye"
        case .chevron: hidden ? "chevron.left.2" : "chevron.right.2"
        case .dots: hidden ? "ellipsis.circle" : "ellipsis.circle.fill"
        case .grid: hidden ? "square.grid.2x2" : "square.grid.2x2.fill"
        case .off, .symbol, .image: nil
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
    /// With `symbol`: the SF Symbol picked in Settings.
    var customSymbol: String?
    /// With `image`: a file in Portside's support folder, see `MenuBarControlImage`.
    var customImage: String?
    /// Drawn in the menu bar's own color, like a system icon.
    var customImageIsTemplate = true
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
        case controlIcon, customSymbol, customImage, customImageIsTemplate, barStyle, barBackground, barCornerRadius, barIconSize, shape, background, cornerRadius, shadow
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
        customSymbol = try? c.decodeIfPresent(String.self, forKey: .customSymbol)
        customImage = try? c.decodeIfPresent(String.self, forKey: .customImage)
        customImageIsTemplate = c.value(.customImageIsTemplate, or: true)
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

    /// The SF Symbol to draw. A chosen symbol fills in while the items show,
    /// when it has a filled form. Nil means no symbol: an image, or no icon.
    func controlSymbol(hidden: Bool, exists: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }) -> String? {
        guard controlIcon == .symbol else { return controlIcon.symbol(hidden: hidden) }
        guard let customSymbol, exists(customSymbol) else { return MenuBarControlIcon.eye.symbol(hidden: hidden) }
        let filled = customSymbol + ".fill"
        return !hidden && !customSymbol.hasSuffix(".fill") && exists(filled) ? filled : customSymbol
    }

    /// The artwork for the control, sized for the menu bar.
    func controlArtwork(hidden: Bool, description: String) -> NSImage? {
        if controlIcon == .image, let customImage, let image = MenuBarControlImage.load(customImage, isTemplate: customImageIsTemplate) {
            image.accessibilityDescription = description
            return image
        }
        guard let name = controlSymbol(hidden: hidden) ?? (controlIcon == .image ? MenuBarControlIcon.eye.symbol(hidden: hidden) : nil) else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: description)
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

/// The user's own menu bar icon: copied into Portside's support folder as a
/// small PNG, so the original can move or go away.
enum MenuBarControlImage {
    private static let largestFile = 10 * 1024 * 1024
    private static let largestSide: CGFloat = 64
    private static let menuBarHeight: CGFloat = 18
    private static let menuBarWidest: CGFloat = 26

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.james.portside", isDirectory: true)
    }

    /// Returns the new file's name and whether it suits being drawn in the
    /// menu bar's color (a shape on transparency does, a full picture doesn't).
    static func store(from source: URL, replacing previous: String?, in folder: URL = MenuBarControlImage.folder) -> (name: String, isTemplate: Bool)? {
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= largestFile,
              let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(largestSide / max(image.size.width, image.size.height), 1)
        let width = max(Int((image.size.width * scale).rounded()), 1)
        let height = max(Int((image.size.height * scale).rounded()), 1)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        // Scaling softens the edge of even a solid picture, so a few see-through
        // pixels do not make it a shape.
        var clear = 0
        for x in 0..<width {
            for y in 0..<height where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.5 { clear += 1 }
        }
        let transparent = clear * 100 > width * height
        let name = "menu-bar-icon-\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        if let previous { try? FileManager.default.removeItem(at: folder.appendingPathComponent(previous)) }
        return (name, transparent)
    }

    /// `name` comes from dock.json, so it may only name a file in the folder.
    static func load(_ name: String, isTemplate: Bool, in folder: URL = MenuBarControlImage.folder) -> NSImage? {
        guard name == (name as NSString).lastPathComponent, let image = NSImage(contentsOf: folder.appendingPathComponent(name)), image.size.height > 0 else { return nil }
        let ratio = image.size.width / image.size.height
        let width = min(menuBarHeight * ratio, menuBarWidest)
        image.size = NSSize(width: width, height: width / ratio)
        image.isTemplate = isTemplate
        return image
    }
}

/// Parts of the menu bar Portside itself occupies (the attached Agent Notch),
/// so a shape can stop at their edges. Main thread only.
enum MenuBarReservedSpans {
    struct Span: Equatable {
        /// The display it is on.
        var screen: CGRect
        /// From the display's left edge.
        var range: ClosedRange<CGFloat>
    }

    static let didChange = Notification.Name("com.james.portside.menuBarReservedSpansChanged")
    private(set) static var current: [Span] = []

    static func update(_ spans: [Span]) {
        guard spans != current else { return }
        current = spans
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// Where the outlines go, in a display's bar with its origin top-left. Pure.
enum MenuBarStylePlan {
    /// The hardware notch widened to cover whatever sits around it.
    static func blocked(notch: ClosedRange<CGFloat>?, reserved: ClosedRange<CGFloat>?) -> ClosedRange<CGFloat>? {
        guard let notch, let reserved else { return notch ?? reserved }
        return min(notch.lowerBound, reserved.lowerBound)...max(notch.upperBound, reserved.upperBound)
    }

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
            // Built like pills, so the two read as the same style.
            let height = size.height - pillInset * 2
            guard let notch else { return [CGRect(x: edge, y: pillInset, width: size.width - edge * 2, height: height)] }
            return [
                CGRect(x: edge, y: pillInset, width: notch.lowerBound - edge * 2, height: height),
                CGRect(x: notch.upperBound + edge, y: pillInset, width: size.width - notch.upperBound - edge * 2, height: height),
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
            (NotificationCenter.default, MenuBarReservedSpans.didChange),
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
            notch = MenuBarStylePlan.blocked(notch: notch, reserved: MenuBarReservedSpans.current.first { $0.screen == screen.frame }?.range)
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
            if index >= previous.count || previous[index] != layout || panel.contentView == nil {
                panel.contentView = NSHostingView(rootView: MenuBarStyleContent(rects: layout.rects, look: layout.look, shadow: layout.shadow))
            }
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
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary, .canJoinAllSpaces]
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
