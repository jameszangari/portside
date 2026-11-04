import AppKit
import ApplicationServices
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
        let native = NativeDockMenu.snapshot(of: app)

        if let native {
            for entry in native.entries {
                menu.addItem(menuItem(for: entry, in: native))
            }
            if !native.entries.isEmpty { menu.addItem(.separator()) }
        } else if !AXIsProcessTrusted() {
            menu.addItem(ClosureMenuItem("Show Windows and Recents...") { AccessibilityTrust.shared.requestAccess() })
            menu.addItem(.separator())
        }

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
        let openAtLogin = ClosureMenuItem("Open at Login") {
            let want = !AppLoginItem.isEnabled(for: app)
            if let error = AppLoginItem.setEnabled(want, for: app) {
                AppLoginItem.presentError(error)
            }
        }
        openAtLogin.state = AppLoginItem.isEnabled(for: app) ? .on : .off
        menu.addItem(openAtLogin)
        if app.bundleIdentifier != nil, model.activityIcons.working {
            let watched = model.watchesWorking(app)
            let working = ClosureMenuItem("Show Working Icon") { model.setWatchesWorking(app, !watched) }
            working.state = watched ? .on : .off
            menu.addItem(working)
        }
        menu.addItem(ClosureMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        })

        if let running = context.running {
            menu.addItem(.separator())
            if let native {
                menu.addItem(ClosureMenuItem("Show All Windows") { native.showAllWindows() })
            }
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

    /// One line copied from the native Dock's menu: a separator, a section
    /// heading (disabled), or an action that presses the real item.
    private static func menuItem(for entry: NativeDockMenu.Entry, in native: NativeDockMenu.Snapshot) -> NSMenuItem {
        guard let title = entry.title else { return .separator() }
        let item = ClosureMenuItem(NativeDockMenu.displayTitle(title)) { native.press(entry) }
        item.isEnabled = entry.isEnabled
        item.state = entry.isMarked ? .on : .off
        return item
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

    /// Press-and-hold opens the same menu as right-click, like the native Dock.
    /// Simultaneous with the tap, not exclusive: an exclusive LongPress/Tap
    /// sequence can swallow short clicks in this non-activating hosting view.
    /// Moving more than 4pt fails the long press so reorder / drag-out wins.
    func menuHold(_ hold: MenuHold, onTap: @escaping () -> Void) -> some View {
        onTapGesture {
            if !hold.fired { onTap() }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: MenuHold.delay, maximumDistance: MenuHold.maxDistance)
                .onChanged { _ in hold.fired = false }
                .onEnded { completed in
                    if completed { hold.fire() }
                }
        )
    }
}

/// Connects a tile's press-and-hold to its right-click menu host.
final class MenuHold {
    static let delay: TimeInterval = 0.5
    static let maxDistance: CGFloat = 4

    fileprivate var show: (() -> Void)?
    fileprivate var fired = false

    fileprivate func fire() {
        fired = true
        actionsLogger.info("press and hold: opening menu")
        show?()
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
        MenuKeyFocus.shared.popUp(menu, at: origin, from: window)
    }
}

/// Portside is never the active app, so keys pressed while one of its
/// menus is open went to the frontmost app: Escape did not close the menu
/// and the arrow keys did not move through it. While a menu tracks, a tiny
/// invisible non-activating panel takes key focus (the frontmost app stays
/// active, like the rename field in a group grid), so key events come to
/// Portside's menu tracking. Ordering it out afterwards gives keyboard focus
/// back to the frontmost app.
final class MenuKeyFocus {
    static let shared = MenuKeyFocus()

    private let panel: KeyOnlyPanel

    private init() {
        panel = KeyOnlyPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = DockPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
    }

    /// Pops `menu` with its top-left corner at `origin` (screen points) and
    /// returns when it closes.
    ///
    /// Pass `from` when the click came from a window above `.popUpMenu` (the
    /// stack / group overlay). NSMenu windows sit at pop-up level, so a higher
    /// overlay would cover them; that window is demoted for the tracking run.
    func popUp(_ menu: NSMenu, at origin: NSPoint, from window: NSWindow? = nil) {
        // Settings open: Portside is active and already gets the keys.
        let borrow = !NSApp.isActive
        if borrow {
            panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 1))
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        let priorLevel: NSWindow.Level?
        if let window, window.level.rawValue > NSWindow.Level.popUpMenu.rawValue {
            priorLevel = window.level
            window.level = .popUpMenu
        } else {
            priorLevel = nil
        }
        actionsLogger.info("menu opened (key focus borrowed: \(borrow), key: \(self.panel.isKeyWindow))")
        menu.popUp(positioning: nil, at: origin, in: nil)
        if let window, let priorLevel { window.level = priorLevel }
        if borrow { panel.orderOut(nil) }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        actionsLogger.info("menu closed, frontmost app \(front, privacy: .public), portside active: \(NSApp.isActive)")
    }
}

private final class KeyOnlyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
