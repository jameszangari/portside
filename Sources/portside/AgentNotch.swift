import AppKit
import Combine
import SwiftUI

final class AgentNotchPresentation: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var preferences = AgentNotchSettings()
    @Published var headerHeight: CGFloat = 30
    @Published var notchWidth: CGFloat = 0
    /// Hangs from the screen's top edge (around the notch, or inside the
    /// menu bar on a display without one): square-ish top corners, no border.
    @Published var topAttached = false
    @Published var compactWidth: CGFloat = 184
    /// Shelf only: the side whose activity card is showing below the header.
    @Published private(set) var peekSide: NotchShelfSide?
    /// Shelf only: the side peeked at just before opening, so the open shelf
    /// can keep that card where the peek showed it.
    @Published private(set) var openedFrom: NotchShelfSide?
    /// Current panel width, for mapping hover points to shelf regions.
    var panelWidth: CGFloat = 0
    /// Shelf only: the size the view draws, top centered in the panel. The
    /// panel snaps to fit it and the view animates, so the top edge never
    /// moves. Nil fills the panel (classic island).
    @Published var surfaceSize: CGSize?
    /// Shelf only: shrinks the panel to `surfaceSize` once the view has
    /// animated down to it.
    var settleTask: DispatchWorkItem?
    /// Shelf only: whether a side has an activity card to peek at.
    var canPeek: (NotchShelfSide) -> Bool = { _ in false }
    var onExpansion: (() -> Void)?
    private var hoverTask: DispatchWorkItem?
    private var machine = NotchShelfMachine()

    private var shelf: Bool { preferences.shelfEnabled }

    func setExpanded(_ value: Bool) {
        hoverTask?.cancel()
        if shelf {
            if value { machine.open() } else { machine.close() }
            syncShelf()
            return
        }
        guard expanded != value else { return }
        expanded = value
        if !value { pinned = false }
        onExpansion?()
    }

    func setPinned(_ value: Bool) {
        guard shelf else { pinned = value; return }
        machine.setPinned(value)
        syncShelf()
    }

    /// Shelf only: the pointer moved to `region` (`.outside` when it left).
    func shelfPointer(_ region: NotchShelfRegion) {
        guard shelf else { return }
        machine.mode = preferences.shelfOpenMode
        let timer = machine.pointer(region, canPeek: canPeek)
        schedule(timer)
    }

    /// Shelf only: a click on the header.
    func shelfClick() {
        guard shelf else { return }
        machine.mode = preferences.shelfOpenMode
        hoverTask?.cancel()
        machine.click()
        syncShelf()
    }

    private func schedule(_ timer: NotchShelfTimer?) {
        hoverTask?.cancel()
        hoverTask = nil
        guard let timer else { return }
        let delay: Double = switch timer {
        case .peek, .open: preferences.hoverDelay
        case .collapse: preferences.collapseDelay
        case .collapsePeek: min(preferences.collapseDelay, 0.2)
        }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.machine.fire(timer)
            self.syncShelf()
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func syncShelf() {
        let changed = expanded != machine.isOpen || peekSide != machine.peekSide
        if machine.isOpen { if !expanded { openedFrom = peekSide } } else { openedFrom = nil }
        expanded = machine.isOpen
        peekSide = machine.peekSide
        if pinned != machine.pinned { pinned = machine.pinned }
        if changed { onExpansion?() }
    }

    func hover(_ inside: Bool) {
        guard !shelf else { return }
        hoverTask?.cancel()
        guard inside ? preferences.expandOnHover && !expanded : expanded && !pinned else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, inside || !self.pinned else { return }
            self.setExpanded(inside)
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? preferences.hoverDelay : preferences.collapseDelay), execute: task)
    }

    func stop() { hoverTask?.cancel(); hoverTask = nil; settleTask?.cancel(); settleTask = nil; onExpansion = nil }
}

final class AgentNotch {
    private struct Surface {
        let panel: NSPanel
        let state: AgentNotchPresentation
        let screen: NSScreen
    }
    private let widgets: WidgetStore
    private var surfaces: [Surface] = []
    private var subscription: AnyCancellable?
    private var sessionsSubscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var enabled = false
    private var preferences = AgentNotchSettings()
    private weak var agents: AgentStatusWidget?
    private weak var usage: UsageWidget?
    private weak var nowPlaying: NowPlayingWidget?
    private var mediaSubscription: AnyCancellable?

    init(model: DockModel, widgets: WidgetStore) {
        self.widgets = widgets
        subscription = widgets.$hosts.combineLatest(model.$showAgentNotch, model.$agentNotchSettings)
            .receive(on: DispatchQueue.main).sink { [weak self] _, enabled, preferences in
                guard let self else { return }
                let nextAgents = widgets.widget(AgentStatusWidget.kind) as? AgentStatusWidget
                let nextUsage = preferences.showUsage ? widgets.widget(UsageWidget.kind) as? UsageWidget : nil
                let nextMedia = preferences.showMedia ? widgets.widget(NowPlayingWidget.kind) as? NowPlayingWidget : nil
                let changed = self.enabled != enabled || self.agents !== nextAgents || self.usage !== nextUsage
                    || self.nowPlaying !== nextMedia
                    || self.preferences.display != preferences.display
                self.preferences = preferences
                self.enabled = enabled
                self.agents = nextAgents
                self.usage = nextUsage
                self.nowPlaying = nextMedia
                if changed { self.rebuildPanels() }
                else {
                    self.surfaces.forEach { $0.state.preferences = preferences }
                    self.layoutPanels()
                }
            }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildPanels() }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.collapseUnpinned()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53,
               self.surfaces.contains(where: { $0.panel.isVisible && $0.state.expanded }) {
                self.surfaces.forEach { $0.state.setExpanded(false) }
                return nil
            }
            if event.type != .keyDown, !self.surfaces.contains(where: { $0.panel == event.window }) { self.collapseUnpinned() }
            return event
        }
    }

    func stop() {
        subscription = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil
        localMonitor = nil
        enabled = false
        rebuildPanels()
    }

    private func collapseUnpinned() {
        // The shelf closes on any click outside, pinned or not; the classic
        // island keeps a pinned dashboard.
        surfaces.filter { preferences.shelfEnabled || !$0.state.pinned }.forEach { $0.state.setExpanded(false) }
    }

    private func rebuildPanels() {
        sessionsSubscription = nil
        mediaSubscription = nil
        surfaces.forEach { $0.state.stop(); $0.panel.close() }
        surfaces = []
        guard enabled, let agents else {
            publishBarSpans()
            return
        }
        let screens: [NSScreen]
        switch preferences.display {
        case .automatic: screens = (NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first).map { [$0] } ?? []
        case .primary: screens = Array(NSScreen.screens.prefix(1))
        case .all: screens = NSScreen.screens
        }
        for screen in screens {
            let state = AgentNotchPresentation()
            state.preferences = preferences
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = preferences.showBorder
            panel.hidesOnDeactivate = false
            state.onExpansion = { [weak self] in self?.layoutPanels() }
            state.canPeek = { [weak self] side in self?.hasPeekCard(side) ?? false }
            panel.contentView = NSHostingView(rootView: AgentNotchView(agents: agents, usage: usage, nowPlaying: nowPlaying, state: state))
            surfaces.append(Surface(panel: panel, state: state, screen: screen))
        }
        sessionsSubscription = agents.$sessions.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layoutPanels() }
        if let nowPlaying {
            mediaSubscription = nowPlaying.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.layoutPanels()
            }
        }
        layoutPanels()
    }

    /// Leading side peeks at the latest session; trailing at Now Playing,
    /// or the latest session when nothing plays.
    private func hasPeekCard(_ side: NotchShelfSide) -> Bool {
        let sessions = agents.map { preferences.sessions(from: $0.sessions) } ?? []
        return side == .trailing && mediaPlaying || !sessions.isEmpty
    }

    private var mediaPlaying: Bool {
        preferences.showMedia && nowPlaying?.track?.isPlaying == true
    }

    private func layoutPanels() {
        guard let agents else { return }
        let sessions = preferences.sessions(from: agents.sessions)
        let playing = mediaPlaying
        for surface in surfaces {
            let screen = surface.screen
            let state = surface.state
            let notched = screen.safeAreaInsets.top > 0
            let attached = notched && preferences.position == .attached
            // No notch to wrap: attached mode sits inside the menu bar instead,
            // hanging from the top edge at the bar's height.
            let inMenuBar = !notched && preferences.position == .attached
            let beside = notched && (preferences.position == .left || preferences.position == .right)
            let notchWidth = max(0, (screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX)
                                 - (screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX))
            state.notchWidth = attached ? notchWidth : 0
            state.topAttached = attached || inMenuBar
            state.headerHeight = attached ? max(screen.safeAreaInsets.top, preferences.compactHeight)
                : inMenuBar ? Self.menuBarHeight(on: screen) : preferences.compactHeight
            // Attached, the flared top corners sit inside the frame; widen it so the body keeps its width.
            state.compactWidth = min(screen.frame.width - 24, preferences.compactWidth + state.notchWidth
                                     + (state.topAttached ? 2 * NotchShape.flare : 0))
            let peeking = state.peekSide != nil && !state.expanded
            let width = state.expanded ? min(screen.frame.width - 24, max(preferences.expandedWidth, state.compactWidth))
                // Peek at the open width, so opening from a peek only grows downward.
                : peeking ? min(screen.frame.width - 24, max(preferences.expandedWidth, state.compactWidth)) : state.compactWidth
            let contentHeight = AgentNotchView.dashboardHeight(preferences: preferences, sessionCount: sessions.count)
            let height = min(screen.visibleFrame.height - 16, state.headerHeight
                             + (state.expanded ? contentHeight : peeking ? AgentNotchView.peekHeight(preferences: preferences) : 0))
            state.panelWidth = width
            var x = screen.frame.midX - width / 2 + (state.topAttached ? 0 : preferences.horizontalOffset)
            if beside {
                x = preferences.position == .left
                    ? (screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX - 100) - width - 6
                    : (screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 100) + 6
                x += preferences.horizontalOffset
            }
            x = min(screen.frame.maxX - width - 8, max(screen.frame.minX + 8, x))
            let top = state.topAttached || beside ? screen.frame.maxY : min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - 4
            let frame = NSRect(x: x, y: top - height - (state.topAttached ? 0 : preferences.verticalOffset), width: width, height: height)
            // The window shadow is the other half of the border: it rims the
            // pill's edge, so "Show border" off turns it off too.
            if surface.panel.hasShadow != preferences.showBorder {
                surface.panel.hasShadow = preferences.showBorder
                surface.panel.invalidateShadow()
            }
            let animate = preferences.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && surface.panel.isVisible
            if preferences.shelfEnabled {
                let openWidth = min(screen.frame.width - 24, max(preferences.expandedWidth, state.compactWidth))
                settleShelf(surface, to: frame, panelWidth: openWidth, animate: animate)
            } else {
                if state.surfaceSize != nil { state.surfaceSize = nil }
                if surface.panel.frame != frame { NSAnimationContext.runAnimationGroup { context in
                    context.duration = preferences.animationDuration
                    if animate { surface.panel.animator().setFrame(frame, display: true) }
                    else { surface.panel.setFrame(frame, display: true) }
                } }
            }
            if preferences.hideWhenEmpty && sessions.isEmpty && !playing && !state.expanded && !peeking { surface.panel.orderOut(nil) }
            else if !surface.panel.isVisible { surface.panel.orderFrontRegardless() }
        }
        publishBarSpans()
    }

    /// Shelf frames never animate the window: an animated `setFrame` moves
    /// the origin and size separately, so the top edge dips and bounces.
    /// The panel grows to cover both the old and new size at once, the view
    /// animates its shape from the top, then the panel shrinks to fit.
    /// The panel keeps one width, the open width, in every state: if it
    /// changed width under the animating shape, the shape's centering offset
    /// would not animate and it would grow from one side.
    private func settleShelf(_ surface: Surface, to shape: NSRect, panelWidth: CGFloat, animate: Bool) {
        let width = max(panelWidth, shape.width)
        let frame = NSRect(x: shape.midX - width / 2, y: shape.minY, width: width, height: shape.height)
        let state = surface.state
        let panel = surface.panel
        state.settleTask?.cancel()
        state.settleTask = nil
        let size = shape.size
        guard animate, state.surfaceSize != nil else {
            state.surfaceSize = size
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            return
        }
        let current = panel.frame
        let height = max(current.height, frame.height)
        let cover = NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
        if current != cover { panel.setFrame(cover, display: true) }
        state.surfaceSize = size
        guard cover != frame else { return }
        let task = DispatchWorkItem { [weak panel, weak state] in
            guard let panel, let state, state.surfaceSize == size else { return }
            state.settleTask = nil
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        state.settleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.animationDuration + 0.05, execute: task)
    }

    /// Where an attached notch sits in the menu bar. Always the compact width:
    /// expanding draws over the bar without changing what it should go around.
    private func publishBarSpans() {
        // The shelf owns the notch and its header whether or not the panel
        // shows, so no menu bar trigger reveals hidden items there.
        MenuBarShelfExclusion.update(preferences.shelfEnabled ? surfaces.compactMap { surface in
            let screen = surface.screen.frame
            let height = max(Self.menuBarHeight(on: surface.screen), surface.screen.safeAreaInsets.top)
            let band = CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
            var notch: ClosedRange<CGFloat>?
            if surface.screen.safeAreaInsets.top > 0, let left = surface.screen.auxiliaryTopLeftArea, let right = surface.screen.auxiliaryTopRightArea,
               left.maxX < right.minX { notch = left.maxX...right.minX }
            let width = surface.state.compactWidth
            let header = surface.state.topAttached ? (screen.midX - width / 2)...(screen.midX + width / 2) : nil
            return MenuBarShelfExclusion.rect(band: band, notch: notch, header: header)
        } : [])
        MenuBarReservedSpans.update(surfaces.filter { $0.state.topAttached && $0.panel.isVisible }.map { surface in
            let width = surface.state.compactWidth
            // Window positions land on whole points, rounding down.
            let left = (surface.screen.frame.width / 2 - width / 2).rounded(.down)
            return MenuBarReservedSpans.Span(screen: surface.screen.frame, range: left...(left + width))
        })
    }

    /// The menu bar's height on `screen`: the strip above `visibleFrame`.
    /// Falls back to the system status bar thickness when the menu bar
    /// auto-hides or this display has none.
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return bar > 0 ? bar : NSStatusBar.system.thickness
    }
}
