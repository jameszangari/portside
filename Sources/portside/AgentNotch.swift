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
    /// Shelf only: the activity whose card shows below the strip.
    @Published private(set) var card: NotchShelfActivity?
    /// Shelf only: what the compact strip shows on each side.
    @Published var strip = NotchShelfStrip()
    /// Shelf only: a short alert (an agent finished or needs you, battery,
    /// weather) on the strip's right side for a few seconds.
    @Published var alert: NotchShelfAlert?
    /// Shelf only: the meeting the strip is counting down to.
    @Published var meeting: CalendarWidget.NextEvent?
    /// Shelf only: the Agents page's provider chip, nil for all. Kept for
    /// this run only.
    @Published var agentProvider: String?
    /// Redraws once a finished session's dismiss time passes.
    @Published var dismissTick = 0
    /// Current panel width, for mapping hover points to shelf regions.
    var panelWidth: CGFloat = 0
    /// Shelf only: the size the view draws, top centered in the panel. The
    /// panel snaps to fit it and the view animates, so the top edge never
    /// moves. Nil fills the panel (classic island).
    @Published var surfaceSize: CGSize?
    /// Shelf only: shrinks the panel to `surfaceSize` once the view has
    /// animated down to it.
    var settleTask: DispatchWorkItem?
    /// Shelf only: the open shelf's page. Nil while closed, or when every
    /// page is off or unavailable.
    @Published private(set) var page: NotchShelfPage?
    /// Shelf only: the page shown last, for the "Last used" starting page.
    /// Kept for this run only.
    private var lastUsedPage: NotchShelfPage?
    /// Shelf only: whether a page can show now (Clipboard needs its module).
    var pageAvailable: (NotchShelfPage) -> Bool = { $0 != .clipboard }
    /// Shelf only: a running widget, for the Widgets page.
    var widgetHost: (String) -> WidgetHost? = { _ in nil }
    /// Shelf only: the chosen page while it is still on, else the first that is.
    var currentPage: NotchShelfPage? {
        let pages = preferences.shelfPages.visible(available: pageAvailable)
        return page.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first
    }
    var onExpansion: (() -> Void)?
    private var hoverTask: DispatchWorkItem?
    private var machine = NotchShelfMachine()
    private var lastHaptic = Date.distantPast

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
        let strip = strip
        schedule(machine.pointer(region) { strip.activity($0) })
    }

    /// Shelf only: the track changed; show the music card for a moment.
    func showBanner() {
        guard shelf, let timer = machine.showBanner() else { return }
        syncShelf()
        schedule(timer)
    }

    /// Shelf only: a click on the header.
    func shelfClick() {
        guard shelf else { return }
        hoverTask?.cancel()
        machine.click()
        syncShelf()
    }

    private func schedule(_ timer: NotchShelfTimer?) {
        hoverTask?.cancel()
        hoverTask = nil
        guard let timer else { return }
        let delay: Double = switch timer {
        case .card, .open: preferences.shelfHoverDelay
        case .collapse: preferences.shelfCollapseDelay
        case .collapseCard: 0.2
        case .bannerEnd: 3
        }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = self.machine.phase
            self.machine.fire(timer)
            if self.machine.phase != before, timer == .open || timer == .card(.music) || timer == .card(.agents) { self.haptic() }
            self.syncShelf()
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Shelf only: a tab was picked.
    func showPage(_ next: NotchShelfPage) {
        guard page != next else { return }
        page = next
        lastUsedPage = next
        // Pages differ in height.
        if expanded { onExpansion?() }
    }

    /// Bartender's hover tap: at most every 0.35 s, when turned on.
    private func haptic() {
        guard preferences.shelfHaptics, Date().timeIntervalSince(lastHaptic) > 0.35 else { return }
        lastHaptic = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func syncShelf() {
        let changed = expanded != machine.isOpen || card != machine.card
        if machine.isOpen, !expanded {
            page = preferences.shelfPages.opening(lastUsed: lastUsedPage, available: pageAvailable)
            lastUsedPage = page ?? lastUsedPage
        }
        expanded = machine.isOpen
        card = machine.card
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
    private weak var model: DockModel?
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
    private var clipboardSubscription: AnyCancellable?
    private var focusObservers: [NSObjectProtocol] = []
    /// The screen "Display you're using" shows on, by its display ID.
    private var focusedDisplay: CGDirectDisplayID?

    init(model: DockModel, widgets: WidgetStore) {
        self.widgets = widgets
        self.model = model
        subscription = widgets.$hosts.combineLatest(model.$showAgentNotch, model.$agentNotchSettings)
            .receive(on: DispatchQueue.main).sink { [weak self] _, enabled, preferences in
                guard let self else { return }
                let nextAgents = widgets.widget(AgentStatusWidget.kind) as? AgentStatusWidget
                let nextUsage = preferences.showUsage ? widgets.widget(UsageWidget.kind) as? UsageWidget : nil
                let musicSlot = preferences.shelfEnabled && [preferences.shelfLeadingWidget, preferences.shelfTrailingWidget].contains(.music)
                let nextMedia = preferences.showMedia || musicSlot ? widgets.widget(NowPlayingWidget.kind) as? NowPlayingWidget : nil
                let changed = self.enabled != enabled || self.agents !== nextAgents || self.usage !== nextUsage
                    || self.nowPlaying !== nextMedia
                    || self.preferences.display != preferences.display
                    || self.preferences.showInFullScreen != preferences.showInFullScreen
                    || self.preferences.shelfEnabled != preferences.shelfEnabled
                self.preferences = preferences
                self.enabled = enabled
                self.agents = nextAgents
                self.usage = nextUsage
                self.nowPlaying = nextMedia
                self.bindAlertSources(widgets)
                if changed { self.rebuildPanels() }
                else {
                    self.surfaces.forEach { $0.state.preferences = preferences }
                    self.layoutPanels()
                }
            }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildPanels() }
        // "Display you're using": follow the frontmost app's window when the
        // active app or Space changes. Event-driven; nothing polls.
        let workspace = NSWorkspace.shared.notificationCenter
        focusObservers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.followFocus() }
        }
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
        focusObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        focusObservers = []
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil
        localMonitor = nil
        dismissTask?.cancel()
        dismissTask = nil
        meetingTask?.cancel()
        meetingTask = nil
        alertSubscriptions = []
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
        case .focused:
            screens = [NSScreen.screens.first { $0.displayID == focusedDisplay } ?? Self.focusedScreen() ?? NSScreen.screens.first].compactMap { $0 }
            focusedDisplay = screens.first?.displayID
        case .primary: screens = Array(NSScreen.screens.prefix(1))
        case .all: screens = NSScreen.screens
        }
        for screen in screens {
            let state = AgentNotchPresentation()
            state.preferences = preferences
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            // Without fullScreenAuxiliary the panel stays out of full-screen
            // Spaces, which is the default (SHELF-08).
            var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            // The classic island keeps showing there, as it always has.
            if preferences.showInFullScreen || !preferences.shelfEnabled { behavior.insert(.fullScreenAuxiliary) }
            panel.collectionBehavior = behavior
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = preferences.showBorder
            panel.hidesOnDeactivate = false
            state.onExpansion = { [weak self] in self?.layoutPanels() }
            state.widgetHost = { [weak self] kind in self?.widgets.host(kind) }
            state.pageAvailable = { [weak self] page in
                page != .clipboard || MainActor.assumeIsolated { self?.model?.clipboardHistoryOn == true }
            }
            panel.contentView = NSHostingView(rootView: AgentNotchView(agents: agents, usage: usage, nowPlaying: nowPlaying, state: state))
            surfaces.append(Surface(panel: panel, state: state, screen: screen))
        }
        alerted = Set(preferences.sessions(from: agents.sessions).filter(Self.alerting).map(\.id))
        sessionsSubscription = agents.$sessions.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.alertNewAgents()
            self?.layoutPanels()
        }
        builtAt = Date()
        // The Clipboard page's height follows its entries and pause state.
        clipboardSubscription = preferences.shelfEnabled ? MainActor.assumeIsolated {
            ClipboardService.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layoutPanels() }
        } : nil
        bannerTrack = nowPlaying?.track?.id
        if let nowPlaying {
            mediaSubscription = nowPlaying.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.layoutPanels()
                self?.bannerOnNewTrack()
            }
        }
        layoutPanels()
    }

    private weak var battery: BatteryWidget?
    private weak var weather: WeatherWidget?
    private weak var calendar: CalendarWidget?
    private var alertSubscriptions: [AnyCancellable] = []
    private var lastBattery: (percent: Int, onAC: Bool)?
    private var weatherAlerted: Set<String> = []
    private var meetingTask: DispatchWorkItem?

    /// Battery, weather and calendar feed the strip while the shelf is on
    /// (the widget store runs them for it). Rebound when their hosts change.
    private func bindAlertSources(_ widgets: WidgetStore) {
        let shelf = preferences.shelfEnabled
        let nextBattery = shelf && preferences.alertBattery ? widgets.widget(BatteryWidget.kind) as? BatteryWidget : nil
        let nextWeather = shelf && preferences.alertWeather ? widgets.widget(WeatherWidget.kind) as? WeatherWidget : nil
        let nextCalendar = shelf && preferences.meetingMinutes > 0 ? widgets.widget(CalendarWidget.kind) as? CalendarWidget : nil
        guard nextBattery !== battery || nextWeather !== weather || nextCalendar !== calendar else { return }
        battery = nextBattery
        weather = nextWeather
        calendar = nextCalendar
        lastBattery = nil
        alertSubscriptions = []
        if let nextBattery {
            alertSubscriptions.append(nextBattery.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.checkBattery() })
            checkBattery()
        }
        if let nextWeather {
            alertSubscriptions.append(nextWeather.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.checkWeather() })
        }
        if let nextCalendar {
            alertSubscriptions.append(nextCalendar.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layoutPanels() })
        }
    }

    private func checkBattery() {
        guard let battery, let percent = battery.percent else { return }
        let current = (percent: percent, onAC: battery.onAC)
        defer { lastBattery = current }
        switch NotchBatteryAlert.detect(previous: lastBattery, current: current, low: preferences.batteryLowPercent) {
        case .pluggedIn?:
            showAlert(NotchShelfAlert(activity: .battery, symbol: "battery.100percent.bolt", short: "\(percent)%",
                                      title: "Charging", detail: "Battery at \(percent)%"))
        case .low?:
            showAlert(NotchShelfAlert(activity: .battery, symbol: "battery.25percent", short: "\(percent)%",
                                      title: "Low battery", detail: "\(percent)% left. Plug in soon.", isWarning: true))
        case nil: break
        }
    }

    private func checkWeather() {
        guard let weather, let found = NotchWeatherAlert.detect(now: weather.code, hours: weather.hourly, at: Date()) else { return }
        let key = "\(found.kind.rawValue)-\(Int(found.date.timeIntervalSince1970))"
        guard weatherAlerted.insert(key).inserted else { return }
        let minutes = max(0, Int(found.date.timeIntervalSinceNow / 60))
        let word = found.kind == .rain ? "Rain" : found.kind == .snow ? "Snow" : "Storms"
        let symbol = found.kind == .rain ? "cloud.rain.fill" : found.kind == .snow ? "cloud.snow.fill" : "cloud.bolt.rain.fill"
        showAlert(NotchShelfAlert(activity: .weather, symbol: symbol, short: "",
                                  title: minutes < 5 ? "\(word) starting" : "\(word) in about \(minutes) min",
                                  detail: weather.place.map { "Forecast for \($0)" } ?? "From the forecast"))
    }

    /// Shows `alert` on the strip's right side for 4 s.
    private func showAlert(_ alert: NotchShelfAlert) {
        guard preferences.shelfEnabled else { return }
        surfaces.forEach { $0.state.alert = alert }
        alertTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.surfaces.forEach { $0.state.alert = nil }
            self?.layoutPanels()
        }
        alertTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
        layoutPanels()
    }

    /// Sessions already alerted for, so each finish or question alerts once.
    private var alerted: Set<String> = []
    private var alertTask: DispatchWorkItem?
    private var bannerTrack: String?
    private var builtAt = Date.distantPast

    private static func alerting(_ session: AgentSession) -> Bool { session.needsAttention || session.state == .done }

    /// A session that just finished or started waiting on you takes the
    /// strip's right side from music for 4 s.
    private func alertNewAgents() {
        guard let agents else { return }
        let now = Set(preferences.sessions(from: agents.sessions).filter(Self.alerting).map(\.id))
        let fresh = !now.subtracting(alerted).isEmpty
        let before = alerted
        alerted = now
        guard fresh, preferences.alertAgents, let session = preferences.sessions(from: agents.sessions)
            .filter({ Self.alerting($0) && !before.contains($0.id) }).first else { return }
        showAlert(NotchShelfAlert(activity: .agents, symbol: session.needsAttention ? "hand.raised.fill" : "checkmark.circle.fill",
                                  short: "", title: session.needsAttention ? "Needs you" : "Finished",
                                  detail: session.project ?? session.provider.name))
    }

    /// The song banner: a new track while music shows on the strip. Not for
    /// the track already playing when the panels were built.
    private func bannerOnNewTrack() {
        guard let track = nowPlaying?.track, track.id != bannerTrack else { return }
        bannerTrack = track.id
        guard preferences.shelfEnabled, preferences.musicBanner, track.isPlaying, musicShowing,
              Date().timeIntervalSince(builtAt) > 3 else { return }
        surfaces.forEach { $0.state.showBanner() }
    }

    /// Music on the strip: something plays, or is paused with Hide when
    /// paused off. The classic island shows bars only while playing.
    private var musicShowing: Bool {
        guard preferences.showMedia, let track = nowPlaying?.track else { return false }
        return track.isPlaying || preferences.shelfEnabled && !preferences.musicHideWhenPaused
    }

    static let idleCapsuleWidth: CGFloat = 96

    /// Bartender's open Top Shelf is about 605 pt wide on a 14-inch MacBook Pro.
    static let shelfOpenWidth: CGFloat = 600

    /// Moves the notch to the focused app's display when that changed.
    private func followFocus() {
        guard enabled, preferences.display == .focused, let screen = Self.focusedScreen(),
              screen.displayID != focusedDisplay else { return }
        focusedDisplay = screen.displayID
        rebuildPanels()
    }

    /// The screen holding the frontmost app's frontmost normal window
    /// (public window list; titles are not read), else the one under the
    /// pointer.
    static func focusedScreen() -> NSScreen? {
        let pointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let primary = NSScreen.screens.first else { return pointer }
        // Window bounds are top-left based on the primary display.
        let rect = CGRect(x: bounds["X"] ?? 0, y: primary.frame.maxY - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0),
                          width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? pointer
    }

    private var dismissTask: DispatchWorkItem?

    /// The meeting the strip counts down to, and one timer for the next
    /// time that can change (no polling).
    private func currentMeeting() -> CalendarWidget.NextEvent? {
        meetingTask?.cancel()
        meetingTask = nil
        guard preferences.shelfEnabled, let events = calendar?.upcoming, !events.isEmpty else { return nil }
        let starts = events.map { (start: $0.start, allDay: $0.isAllDay) }
        let now = Date()
        if let next = NotchMeetingSoon.nextChange(starts, now: now, minutes: preferences.meetingMinutes) {
            let task = DispatchWorkItem { [weak self] in self?.layoutPanels() }
            meetingTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.05, execute: task)
        }
        return NotchMeetingSoon.current(starts, now: now, minutes: preferences.meetingMinutes).map { events[$0] }
    }

    /// One timer for the next finished session to leave the list, so the
    /// list and the notch drop it on time without polling.
    private func scheduleDismiss(_ sessions: [AgentSession]) {
        dismissTask?.cancel()
        dismissTask = nil
        let now = Date()
        guard let next = sessions.compactMap(preferences.dismissDate).filter({ $0 > now }).min() else { return }
        let task = DispatchWorkItem { [weak self] in
            self?.surfaces.forEach { $0.state.dismissTick += 1 }
            self?.layoutPanels()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.05, execute: task)
    }

    private func layoutPanels() {
        guard let agents else { return }
        let sessions = preferences.sessions(from: agents.sessions)
        scheduleDismiss(sessions)
        let clipboard = MainActor.assumeIsolated { (ClipboardService.shared.entries.count, ClipboardService.shared.prefs.paused) }
        let meeting = currentMeeting()
        let playing = musicShowing
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
            if state.meeting != meeting { state.meeting = meeting }
            let active = preferences.stripOrder.filter { activity in
                switch activity {
                case .meeting: meeting != nil
                case .music: playing
                case .agents: !sessions.isEmpty
                case .battery, .weather: false
                }
            }
            let strip = NotchShelfStrip.layout(active: active, alert: state.alert?.activity)
            if state.strip != strip { state.strip = strip }
            // Without a notch, the shelf's capsule shrinks while nothing runs
            // (Bartender's smaller idle capsule), so the menu bar keeps its room.
            if preferences.shelfEnabled, !notched, strip == NotchShelfStrip() {
                state.compactWidth = min(state.compactWidth, Self.idleCapsuleWidth)
            }
            if let card = state.card, strip.leading != card, strip.trailing != card, !state.expanded {
                // Music stopped or the agents went away under the card.
                DispatchQueue.main.async { state.setExpanded(false) }
            }
            let peeking = state.card != nil && !state.expanded
            // The open shelf is wider than a card, as in Bartender: opening
            // from a card grows sideways and down.
            let cardWidth = min(screen.frame.width - 24, max(preferences.expandedWidth, state.compactWidth))
            let shelfWidth = min(screen.frame.width - 24, max(Self.shelfOpenWidth, state.compactWidth))
            let width = state.expanded ? (preferences.shelfEnabled ? shelfWidth : cardWidth)
                : peeking ? cardWidth : state.compactWidth
            let contentHeight = preferences.shelfEnabled
                ? AgentNotchView.shelfHeight(page: state.currentPage, preferences: preferences,
                                             sessionCount: AgentNotchView.providerFiltered(sessions, state.agentProvider).count,
                                             chips: AgentNotchView.providerChips(sessions).count > 1,
                                             usageRows: preferences.showUsage ? usage?.usage.count ?? 0 : 0,
                                             clipboard: clipboard)
                : AgentNotchView.dashboardHeight(preferences: preferences, sessionCount: sessions.count)
            let height = min(screen.visibleFrame.height - 16, state.headerHeight
                             + (state.expanded ? contentHeight : state.card.map {
                                 AgentNotchView.cardHeight($0, preferences: preferences, sessionCount: sessions.count)
                             } ?? 0))
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
                settleShelf(surface, to: frame, panelWidth: shelfWidth, animate: animate)
            } else {
                if state.surfaceSize != nil { state.surfaceSize = nil }
                if surface.panel.frame != frame { NSAnimationContext.runAnimationGroup { context in
                    context.duration = preferences.animationDuration
                    if animate { surface.panel.animator().setFrame(frame, display: true) }
                    else { surface.panel.setFrame(frame, display: true) }
                } }
            }
            if preferences.hideWhenEmpty && sessions.isEmpty && !playing && meeting == nil && state.alert == nil
                && !state.expanded && !peeking { surface.panel.orderOut(nil) }
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

private extension NSScreen {
    /// The display ID, stable while the display stays connected.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
