import AppKit
import SwiftUI
import os.log

private let actionsLogger = Logger(subsystem: "com.james.portside", category: "TileActions")

/// Native-Dock modifier clicks on app tiles (strip tiles and group grid cells).
///
/// - Cmd-click: reveal the app in Finder. No launch, no bounce.
/// - Option-click: switch to the app and hide the app that was frontmost.
/// - Cmd+Option-click: switch to the app and hide every other regular app.
enum TileClick {
    enum Kind: Equatable {
        case open
        case reveal
        case hideFrontmost
        case hideOthers
    }

    static func kind(for flags: NSEvent.ModifierFlags) -> Kind {
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        if command && option { return .hideOthers }
        if command { return .reveal }
        if option { return .hideFrontmost }
        return .open
    }

    /// Runs `open` (the tile's normal launch or activate, with the bounce if
    /// it applies) unless the click is a Cmd-click. `open` takes a callback
    /// to run once the app is up, which does the hiding. The apps to hide are
    /// worked out now, before the switch changes who is frontmost.
    static func perform(_ app: PinnedApp, running: NSRunningApplication?, flags: NSEvent.ModifierFlags,
                        open: (_ afterOpen: ((NSRunningApplication?) -> Void)?) -> Void) {
        let kind = kind(for: flags)
        if kind == .reveal {
            actionsLogger.info("cmd-click: revealing \(app.displayName, privacy: .public) in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
            return
        }
        guard kind != .open else { return open(nil) }

        let victims = appsToHide(kind, clicked: app, running: running)
        actionsLogger.info("\(kind == .hideOthers ? "cmd+option" : "option", privacy: .public)-click: \(app.displayName, privacy: .public), hiding \(victims.count) app(s)")
        open { _ in
            for victim in victims { victim.hide() }
        }
    }

    /// Regular apps other than Portside and the clicked app. For Option-click
    /// that is only the frontmost one.
    private static func appsToHide(_ kind: Kind, clicked: PinnedApp, running: NSRunningApplication?) -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        func isClicked(_ other: NSRunningApplication) -> Bool {
            if let running, other.processIdentifier == running.processIdentifier { return true }
            if let id = clicked.bundleIdentifier, other.bundleIdentifier == id { return true }
            return other.bundleURL?.path == clicked.path
        }
        func hideable(_ other: NSRunningApplication) -> Bool {
            other.processIdentifier != me && other.activationPolicy == .regular && !other.isHidden
                && !other.isTerminated && !isClicked(other)
        }
        switch kind {
        case .hideFrontmost:
            if let front = NSWorkspace.shared.frontmostApplication, hideable(front) { return [front] }
            return []
        case .hideOthers:
            return NSWorkspace.shared.runningApplications.filter(hideable)
        case .open, .reveal:
            return []
        }
    }
}

// MARK: - Context menu

/// Builds the right-click menu of an app tile. AppKit rather than SwiftUI's
/// `.contextMenu` because only NSMenu supports alternate items (Option turns
/// Quit into Force Quit).
enum AppTileMenu {
    struct Context {
        let app: PinnedApp
        let running: NSRunningApplication?
        /// Pinned in the strip (or a group member), so it can be removed.
        let isPinned: Bool
        let dockModel: DockModel
        /// Items that come first, for the group grid ("Remove from Group").
        var leading: [(title: String, action: () -> Void)] = []
        /// Offer "Keep in Dock"/"Remove from Dock" and "Add to Group".
        var offersDockItems = true
    }

    static func build(_ context: Context) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let model = context.dockModel
        let app = context.app

        for item in context.leading {
            menu.addItem(ClosureMenuItem(item.title, item.action))
        }
        if context.offersDockItems {
            if context.isPinned {
                menu.addItem(ClosureMenuItem("Remove from Dock") { model.unpin(app) })
            } else {
                menu.addItem(ClosureMenuItem("Keep in Dock") { model.pin(app) })
            }
            let groupItem = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
            let groupMenu = NSMenu()
            groupMenu.autoenablesItems = false
            for group in model.groups {
                groupMenu.addItem(ClosureMenuItem(group.name) { model.addToGroup(app, groupID: group.id) })
            }
            if !model.groups.isEmpty { groupMenu.addItem(.separator()) }
            groupMenu.addItem(ClosureMenuItem("New Group") { model.createGroup(with: app) })
            groupItem.submenu = groupMenu
            menu.addItem(groupItem)
        } else if context.isPinned {
            menu.addItem(ClosureMenuItem("Remove from Dock") { model.unpin(app) })
        }
        menu.addItem(ClosureMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        })

        if let running = context.running {
            menu.addItem(.separator())
            if running.isHidden {
                menu.addItem(ClosureMenuItem("Show") { running.unhide() })
            } else {
                menu.addItem(ClosureMenuItem("Hide") { running.hide() })
            }
            menu.addItem(ClosureMenuItem("Quit") { running.terminate() })
            // Holding Option swaps the item above for this one while the menu is open.
            let force = ClosureMenuItem("Force Quit") {
                actionsLogger.info("force quitting \(app.displayName, privacy: .public)")
                running.forceTerminate()
            }
            force.keyEquivalentModifierMask = .option
            force.isAlternate = true
            menu.addItem(force)
        }
        return menu
    }
}

/// Menu item that runs a closure. The menu owns its items, so the closure
/// lives as long as the menu does.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

// MARK: - Right-click host

extension View {
    /// Pops an AppKit menu on right-click (or Control-click). The overlay only
    /// takes mouse-down events of those two kinds, so taps, drags and hover
    /// pass through to the SwiftUI view underneath.
    /// The menu opens beside the tile on the side away from the screen edge
    /// (above it on the bottom dock), centered on it, like the native Dock.
    /// With a `hold`, the same menu can be opened by `menuHold(_:)` on the tile.
    /// With a `magnifyID`, the right-click area and the menu's anchor follow
    /// the magnified tile.
    func appKitContextMenu(edge: DockEdge = .bottom, hold: MenuHold? = nil, magnifyID: String? = nil,
                           _ menu: @escaping () -> NSMenu) -> some View {
        overlay(RightClickMenuHost(edge: edge, hold: hold, menu: menu).magnifiedHitArea(id: magnifyID))
    }

    /// Click-and-hold opens the tile's context menu, like the native Dock.
    /// A one-shot press recognizer (no timer of ours): it fires after 0.5s if
    /// the cursor stays within 4pt, and fails on earlier movement so the
    /// reorder drag takes over. A short click is untouched. Put this next to
    /// the tile's tap gesture, and have the tap call `hold.consumeFired()`.
    func menuHold(_ hold: MenuHold) -> some View {
        onLongPressGesture(minimumDuration: 0.5, maximumDistance: 4, perform: {
            hold.fire()
        }, onPressingChanged: { pressing in
            if pressing { hold.reset() }
        })
    }
}

/// Connects a tile's press-and-hold to its right-click menu host.
final class MenuHold {
    fileprivate var show: (() -> Void)?
    private var fired = false

    fileprivate func fire() {
        fired = true
        actionsLogger.info("press and hold: opening menu")
        show?()
    }

    fileprivate func reset() { fired = false }

    /// True once after a hold opened the menu, so the release is not a click.
    func consumeFired() -> Bool {
        defer { fired = false }
        return fired
    }
}

private struct RightClickMenuHost: NSViewRepresentable {
    let edge: DockEdge
    let hold: MenuHold?
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        update(view)
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) { update(view) }

    private func update(_ view: RightClickView) {
        view.menuProvider = menu
        view.edge = edge
        hold?.show = { [weak view] in view?.show() }
    }
}

private final class RightClickView: NSView {
    var menuProvider: (() -> NSMenu)?
    var edge: DockEdge = .bottom
    private static let gap: CGFloat = 4

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let wantsMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return wantsMenu ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) { show() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { show() } else { super.mouseDown(with: event) }
    }

    func show() {
        guard let menu = menuProvider?() else { return }
        // popUp puts the menu's top-left corner at the point. Screen
        // coordinates (y up) avoid any view flipping; AppKit nudges the menu
        // back on screen if needed.
        guard let window else { return }
        let tile = window.convertToScreen(convert(bounds, to: nil))
        // Alternate items (Force Quit) count toward `size` but are not shown
        // until Option is held, so measure the menu without them.
        let alternates = menu.items.filter(\.isAlternate)
        alternates.forEach { menu.removeItem($0) }
        let size = menu.size
        alternates.forEach { menu.addItem($0) }
        let gap = Self.gap
        let origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: tile.midX - size.width / 2, y: tile.maxY + gap + size.height)
        case .left: origin = NSPoint(x: tile.maxX + gap, y: tile.midY + size.height / 2)
        case .right: origin = NSPoint(x: tile.minX - gap - size.width, y: tile.midY + size.height / 2)
        }
        menu.popUp(positioning: nil, at: origin, in: nil)
    }
}
