import AppKit
import SwiftUI

/// Where the bar goes along the top of a display. Pure.
struct MenuBarBarPlacement {
    var location = MenuBarBarLocation.icon
    var pointer = NSPoint.zero
    var pointerOnEmptyBar = false

    /// Otherwise the bar opens on the display under the pointer.
    var usesAnchorDisplay: Bool {
        location == .icon || (location == .dynamic && !pointerOnEmptyBar)
    }

    func x(width: CGFloat, visible: NSRect, anchor: NSRect?) -> CGFloat {
        let margin: CGFloat = 8
        let centered = (anchor?.midX ?? visible.maxX) - width / 2
        let underPointer = pointer.x - width / 2
        let wanted: CGFloat
        switch location {
        case .dynamic: wanted = pointerOnEmptyBar ? underPointer : centered
        case .pointer: wanted = underPointer
        case .icon: wanted = centered
        case .left: wanted = visible.minX + margin
        case .right: wanted = visible.maxX - width - margin
        }
        return max(visible.minX + margin, min(wanted, visible.maxX - width - margin))
    }
}

/// The Portside Bar: hidden items as rows of icons under the menu bar, one row
/// per named group plus the rest. Opens instead of a reveal when chosen in
/// Settings, when macOS has run out of room, or from a group's own icon.
@MainActor
final class MenuBarOverflowPanel {
    struct Entry: Identifiable {
        let item: MenuBarItem
        let bundle: String
        let icon: NSImage?
        var menuBarOnly = false
        var id: String { item.id }
    }

    /// How the bar draws. A nil `dock` is the system material.
    struct Look {
        var dock: DockLook?
        var cornerRadius: CGFloat = 10
        var iconSize: CGFloat = 22
    }

    struct Row: Identifiable {
        let title: String?
        let entries: [Entry]
        var id: String { title ?? "" }
    }

    /// Portside's own menu is up, so nothing may hide the bar under it.
    static var ownMenuIsUp = false

    /// Apps found this session to open only from the real menu bar.
    final class Model: ObservableObject {
        @Published var learned = Set<String>()
    }

    private let model = Model()

    func markMenuBarOnly(_ bundle: String) { model.learned.insert(bundle) }

    private var panel: NSPanel?
    private var monitors: [Any] = []

    func show(
        _ rows: [Row],
        at placement: MenuBarBarPlacement = MenuBarBarPlacement(),
        look: Look = Look(),
        below anchor: NSRect?,
        ignoresOutsideClick: @escaping @MainActor (NSPoint) -> Bool = { _ in false },
        onDismiss: (@MainActor () -> Void)? = nil,
        onSecondary: @escaping (Entry, NSView) -> Void = { _, _ in },
        onOpen: @escaping (Entry, NSView) -> Void
    ) {
        close()
        model.learned = []
        let view = MenuBarBarHost(rootView: MenuBarOverflowContent(rows: rows, look: look, model: model, onOpen: onOpen, onSecondary: onSecondary))
        let size = view.fittingSize
        let made = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        made.isFloatingPanel = true
        made.level = .statusBar
        made.backgroundColor = .clear
        made.isOpaque = false
        made.hasShadow = true
        made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        made.contentView = view
        let anchorScreen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(placement.pointer) }
        let screen = (placement.usesAnchorDisplay ? anchorScreen : pointerScreen) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        made.setFrameOrigin(NSPoint(x: placement.x(width: size.width, visible: visible, anchor: anchor), y: visible.maxY - size.height - 6))
        made.orderFrontRegardless()
        panel = made
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard !ignoresOutsideClick(NSEvent.mouseLocation) else { return }
                self?.close()
                onDismiss?()
            }
        }) { monitors.append(outside) }
        if let escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                self?.close()
                onDismiss?()
            }
        }) { monitors.append(escape) }
        // Global monitors skip Portside's own events, so with Settings in
        // front a click or Esc would not reach the ones above.
        if let own = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self, weak made] event in
            let dismisses = event.type == .keyDown ? event.keyCode == 53 : event.window !== made && !ignoresOutsideClick(NSEvent.mouseLocation)
            if dismisses {
                self?.close()
                onDismiss?()
            }
            return event
        }) { monitors.append(own) }
    }

    var isShown: Bool { panel != nil }

    /// A native menu hanging from an icon. The bar stays open behind it.
    func popUp(_ menu: NSMenu, from view: NSView) {
        Self.ownMenuIsUp = true
        defer { Self.ownMenuIsUp = false }
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }

    func close() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Keeps the panel as big as its content, growing down from a fixed top edge,
/// so the caption takes room only while there is one.
private final class MenuBarBarHost: NSHostingView<MenuBarOverflowContent> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    override func layout() {
        super.layout()
        fitWindow()
    }

    private func fitWindow() {
        guard let window else { return }
        let size = fittingSize
        let current = window.frame
        guard abs(size.width - current.width) > 0.5 || abs(size.height - current.height) > 0.5 else { return }
        window.setFrame(NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

private final class MenuBarBarIconButton: NSButton {
    var onOpen: ((NSView) -> Void)?
    var onSecondary: ((NSView) -> Void)?
    var onHover: ((Bool) -> Void)?

    @objc func pressed() { onOpen?(self) }

    // The panel never becomes key, so the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onSecondary?(self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) { onSecondary?(self) }

    // Drawn inside the button's own bounds so a hover never reaches a neighbor.
    private var hover: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hover = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        onHover?(false)
    }
}

private struct MenuBarBarIcon: NSViewRepresentable {
    let entry: MenuBarOverflowPanel.Entry
    let iconSize: CGFloat
    let dimmed: Bool
    let onOpen: (MenuBarOverflowPanel.Entry, NSView) -> Void
    let onSecondary: (MenuBarOverflowPanel.Entry, NSView) -> Void
    let onHover: (MenuBarOverflowPanel.Entry?) -> Void

    /// The icon with a small lock, so a disabled one reads as disabled
    /// without being hard to recognize.
    private func image(size: CGFloat) -> NSImage? {
        guard let base = entry.icon ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil) else { return nil }
        guard dimmed else {
            let plain = base.copy() as? NSImage
            plain?.size = NSSize(width: size, height: size)
            return plain
        }
        let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 11, y: rect.minY - 1, width: 12, height: 12)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: badge).fill()
            lock?.draw(in: badge.insetBy(dx: 2.5, dy: 2.5))
            return true
        }
    }

    func makeNSView(context: Context) -> MenuBarBarIconButton {
        let button = MenuBarBarIconButton()
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = button
        button.action = #selector(MenuBarBarIconButton.pressed)
        return button
    }

    func updateNSView(_ button: MenuBarBarIconButton, context: Context) {
        button.image = image(size: iconSize)
        button.alphaValue = dimmed ? 0.65 : 1
        button.toolTip = MenuBarBarCaption.text(for: entry, dimmed: dimmed)
        button.setAccessibilityLabel(MenuBarBarCaption.text(for: entry, dimmed: dimmed))
        button.onHover = { [entry, onHover] inside in onHover(inside ? entry : nil) }
        button.onOpen = { [entry, onOpen] view in onOpen(entry, view) }
        button.onSecondary = { [entry, onSecondary] view in onSecondary(entry, view) }
    }
}

private struct MenuBarOverflowContent: View {
    let rows: [MenuBarOverflowPanel.Row]
    let look: MenuBarOverflowPanel.Look
    @ObservedObject var model: MenuBarOverflowPanel.Model
    let onOpen: (MenuBarOverflowPanel.Entry, NSView) -> Void
    let onSecondary: (MenuBarOverflowPanel.Entry, NSView) -> Void

    @State private var hovered: MenuBarOverflowPanel.Entry?
    @State private var clearing: Task<Void, Never>?

    /// Leaving one icon for the next must not flicker the caption away.
    private func hover(_ entry: MenuBarOverflowPanel.Entry?) {
        clearing?.cancel()
        if let entry {
            hovered = entry
            return
        }
        clearing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hovered = nil
        }
    }

    /// The caption wraps at the width of the icons, never widening the bar.
    private var iconsWidth: CGFloat {
        let widest = rows.map(\.entries.count).max() ?? 1
        return max(CGFloat(widest) * (look.iconSize + 10) - 2, 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    if let title = row.title { Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4) }
                    HStack(spacing: 2) {
                        ForEach(row.entries) { entry in
                            MenuBarBarIcon(
                                entry: entry, iconSize: look.iconSize, dimmed: entry.menuBarOnly || model.learned.contains(entry.bundle),
                                onOpen: onOpen, onSecondary: onSecondary, onHover: { hover($0) }
                            )
                            .frame(width: look.iconSize + 8, height: look.iconSize + 8)
                        }
                    }
                }
            }
            caption
        }
        .padding(6)
        .modifier(MenuBarBarBackground(look: look))
    }
}

extension MenuBarOverflowContent {
    /// Only while an icon is hovered, and as tall as its text needs.
    @ViewBuilder
    fileprivate var caption: some View {
        if let hovered {
            let dimmed = hovered.menuBarOnly || model.learned.contains(hovered.bundle)
            Text(MenuBarBarCaption.attributed(for: hovered, dimmed: dimmed))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: iconsWidth - 8, alignment: .topLeading)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
        }
    }
}

/// What an icon is called, and why it may be disabled. Pure.
enum MenuBarBarCaption {
    static func name(for entry: MenuBarOverflowPanel.Entry) -> String {
        if entry.item.isSystemHost { return entry.item.displayTitle }
        let owner = entry.item.ownerName
        let title = entry.item.title
        guard !title.isEmpty, title != owner, title.count <= 30, !title.contains(".") else { return owner }
        return "\(owner) (\(title))"
    }

    /// The name in medium weight, the reason after it in a quieter color.
    static func attributed(for entry: MenuBarOverflowPanel.Entry, dimmed: Bool) -> AttributedString {
        var result = AttributedString(name(for: entry))
        result.font = .system(size: 11, weight: .medium)
        guard dimmed else { return result }
        var reason = AttributedString(" opens only from the menu bar. Keep it in Visible to use it.")
        reason.foregroundColor = .secondary
        result.append(reason)
        return result
    }

    static func text(for entry: MenuBarOverflowPanel.Entry, dimmed: Bool) -> String {
        dimmed ? "\(name(for: entry)) opens only from the menu bar" : name(for: entry)
    }
}

private struct MenuBarBarBackground: ViewModifier {
    let look: MenuBarOverflowPanel.Look

    func body(content: Content) -> some View {
        if let dock = look.dock {
            content.dockBackground(dock, in: RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous))
        }
    }
}
