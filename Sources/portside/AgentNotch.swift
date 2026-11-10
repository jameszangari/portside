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
    var onExpansion: (() -> Void)?
    private var hoverTask: DispatchWorkItem?

    func setExpanded(_ value: Bool) {
        hoverTask?.cancel()
        guard expanded != value else { return }
        expanded = value
        if !value { pinned = false }
        onExpansion?()
    }

    func hover(_ inside: Bool) {
        hoverTask?.cancel()
        guard inside ? preferences.expandOnHover && !expanded : expanded && !pinned else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, inside || !self.pinned else { return }
            self.setExpanded(inside)
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? preferences.hoverDelay : preferences.collapseDelay), execute: task)
    }

    func stop() { hoverTask?.cancel(); hoverTask = nil; onExpansion = nil }
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
        surfaces.filter { !$0.state.pinned }.forEach { $0.state.setExpanded(false) }
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
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = preferences.showBorder
            panel.hidesOnDeactivate = false
            state.onExpansion = { [weak self] in self?.layoutPanels() }
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
            state.compactWidth = min(screen.frame.width - 24, preferences.compactWidth + state.notchWidth)
            let width = state.expanded ? min(screen.frame.width - 24, max(preferences.expandedWidth, state.compactWidth)) : state.compactWidth
            let contentHeight = AgentNotchView.dashboardHeight(preferences: preferences, sessionCount: sessions.count)
            let height = min(screen.visibleFrame.height - 16, state.headerHeight + (state.expanded ? contentHeight : 0))
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
            if surface.panel.frame != frame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = preferences.animationDuration
                    if animate { surface.panel.animator().setFrame(frame, display: true) }
                    else { surface.panel.setFrame(frame, display: true) }
                }
            }
            if preferences.hideWhenEmpty && sessions.isEmpty && !playing && !state.expanded { surface.panel.orderOut(nil) }
            else if !surface.panel.isVisible { surface.panel.orderFrontRegardless() }
        }
        publishBarSpans()
    }

    /// Where an attached notch sits in the menu bar. Always the compact width:
    /// expanding draws over the bar without changing what it should go around.
    private func publishBarSpans() {
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
