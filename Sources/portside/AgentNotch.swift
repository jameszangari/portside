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
    /// The activity whose card shows below the strip.
    @Published private(set) var card: NotchShelfActivity?
    /// The music card is a fresh song banner, so it shows the
    /// song's name only until the pointer reaches it.
    @Published private(set) var banner = false
    /// The volume or brightness level, shown on the strip for a
    /// moment after it changes (SHELF-09).
    @Published var hud: NotchHUD?
    /// What the compact strip shows on each side.
    @Published var strip = NotchShelfStrip()
    /// A short alert (an agent finished or needs you, battery,
    /// weather) on the strip's right side for a few seconds.
    @Published var alert: NotchShelfAlert?
    /// The meeting the strip is counting down to.
    @Published var meeting: CalendarWidget.NextEvent?
    /// The Agents page's provider chip, nil for all. Kept for
    /// this run only.
    @Published var agentProvider: String?
    /// Redraws once a finished session's dismiss time passes.
    @Published var dismissTick = 0
    /// Current panel width, for mapping hover points to shelf regions.
    var panelWidth: CGFloat = 0
    /// The size the view draws, top centered in the panel. The
    /// panel snaps to fit it and the view animates, so the top edge never
    /// moves. Nil fills the panel (before the first layout).
    @Published var surfaceSize: CGSize?
    /// Shrinks the panel to `surfaceSize` once the view has
    /// animated down to it.
    var settleTask: DispatchWorkItem?
    /// The open shelf's page. Nil while closed, or when every
    /// page is off or unavailable.
    @Published private(set) var page: NotchShelfPage?
    /// The page shown last, for the "Last used" starting page.
    /// Kept for this run only.
    private var lastUsedPage: NotchShelfPage?
    /// Whether the pointer is over this panel now.
    var pointerInside: () -> Bool = { false }
    /// A file drag is over the panel.
    @Published private(set) var fileDragOver = false
    /// The Clipboard page's search field is up and takes the keyboard
    /// (SHELF-11's search hotkey); `query` is what was typed.
    @Published private(set) var searching = false
    @Published var query = ""
    /// The panel takes the keyboard (a search started) or gives it back
    /// (the shelf closed).
    var onSearch: ((Bool) -> Void)?
    /// The panel has the keyboard: from a search's start until the shelf
    /// closes, even once the search ends. Giving it back orders the panel
    /// out and in, which blinks an open shelf (maintainer report: the
    /// search field's close button closed and reopened the shelf).
    private var holdsKeys = false
    /// The connected AirPods and Beats, for the AirPods page.
    @Published var airPods: [AirPodsReading] = []
    /// Whether a page can show now (Clipboard needs its module,
    /// AirPods a connected pair).
    var pageAvailable: (NotchShelfPage) -> Bool = { $0 != .clipboard && $0 != .airPods }
    /// A running widget, for the Widgets page.
    var widgetHost: (String) -> WidgetHost? = { _ in nil }
    /// The chosen page while it is still on, else the first that is.
    var currentPage: NotchShelfPage? {
        let pages = preferences.shelfPages.visible(available: pageAvailable)
        return page.flatMap { pages.contains($0) ? $0 : nil } ?? pages.first
    }
    var onExpansion: (() -> Void)?
    private var hoverTask: DispatchWorkItem?
    private var machine = NotchShelfMachine()
    private var lastHaptic = Date.distantPast

    func setExpanded(_ value: Bool) {
        hoverTask?.cancel()
        if value { machine.open() } else { machine.close() }
        syncShelf()
    }

    func setPinned(_ value: Bool) {
        machine.setPinned(value)
        syncShelf()
    }

    /// False for the Settings preview, which sets its scene itself: the
    /// pointer, or its window losing focus (SwiftUI ends hover tracking
    /// then), never moves it (maintainer report: testing the notch with a
    /// section open changed the preview).
    var followsPointer = true

    /// The pointer moved to `region` (`.outside` when it left). `force`
    /// applies it even when the pointer is not followed (the preview's own
    /// card).
    func shelfPointer(_ region: NotchShelfRegion, force: Bool = false) {
        guard followsPointer || force else { return }
        let strip = strip
        // A hotkey's shelf runs its own timer; the pointer only notes where it is.
        let hotkey = machine.viaHotkey && machine.isOpen
        let agentsPage = preferences.shelfPages.visible(available: pageAvailable).contains(.agents)
        let timer = machine.pointer(region, activity: { strip.activity($0) },
                                    page: { $0 == .agents && agentsPage && !force ? .agents : nil })
        if !hotkey { schedule(timer) }
        if banner != machine.banner { syncShelf() }
    }

    /// The track changed; show the music card for a moment.
    func showBanner() {
        guard let timer = machine.showBanner() else { return }
        syncShelf()
        schedule(timer)
    }

    /// A click on the header.
    func shelfClick() {
        hoverTask?.cancel()
        machine.click()
        syncShelf()
    }

    private func schedule(_ timer: NotchShelfTimer?) {
        hoverTask?.cancel()
        hoverTask = nil
        guard let timer else { return }
        let delay: Double = switch timer {
        case .card, .open, .page: preferences.shelfHoverDelay
        case .collapse: preferences.shelfCollapseDelay
        case .collapseCard: 0.2
        case .bannerEnd: 3
        case .hotkeyEnd: TimeInterval(preferences.hotkeyOpenSeconds)
        }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = self.machine.phase
            self.machine.fire(timer)
            if self.machine.phase != before, timer == .open || timer == .page(.agents) || timer == .card(.music) { self.haptic() }
            self.syncShelf()
            if case .page(let page) = timer, self.machine.isOpen { self.showPage(page) }
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// The Files page is on, so a file drop has somewhere to go.
    var acceptsFiles: Bool { preferences.shelfPages.visible(available: pageAvailable).contains(.files) }

    /// A file drag entered or left the panel. Entering opens the
    /// shelf on Files, as Bartender does; leaving without a drop closes it
    /// after the collapse delay, like the pointer leaving.
    func fileDrag(_ over: Bool) {
        guard acceptsFiles, fileDragOver != over else { return }
        fileDragOver = over
        if over {
            hoverTask?.cancel()
            machine.open()
            syncShelf()
            showPage(.files)
        } else if !pointerInside() {
            // Dropped, or dragged away. After a drop the pointer is still on
            // the shelf; hover takes over from there.
            shelfPointer(.outside)
        }
    }

    /// A hotkey (SHELF-11). `page` nil opens on the usual start
    /// page; `toggle` closes an open shelf instead; `search` puts up the
    /// Clipboard page's search field.
    func hotkey(page: NotchShelfPage?, toggle: Bool = false, search: Bool = false) {
        if toggle, expanded {
            setExpanded(false)
            return
        }
        schedule(machine.openViaHotkey())
        syncShelf()
        if let page { showPage(page) }
        setSearching(search && page == .clipboard && self.page == .clipboard)
    }

    func setSearching(_ value: Bool) {
        if !value { query = "" }
        if !value, !expanded, holdsKeys {
            holdsKeys = false
            onSearch?(false)
        }
        guard searching != value else { return }
        searching = value
        if value, !holdsKeys {
            holdsKeys = true
            onSearch?(true)
        }
        // The field changes the page's height.
        if expanded { onExpansion?() }
    }

    /// A tab was picked.
    func showPage(_ next: NotchShelfPage) {
        guard page != next else { return }
        if next != .clipboard { setSearching(false) }
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
        let changed = expanded != machine.isOpen || card != machine.card || banner != machine.banner
        if machine.isOpen, !expanded {
            page = preferences.shelfPages.opening(lastUsed: lastUsedPage, available: pageAvailable)
            lastUsedPage = page ?? lastUsedPage
        }
        expanded = machine.isOpen
        if !expanded { setSearching(false) }
        card = machine.card
        banner = machine.banner
        if pinned != machine.pinned { pinned = machine.pinned }
        if changed { onExpansion?() }
    }

    func stop() { hoverTask?.cancel(); hoverTask = nil; settleTask?.cancel(); settleTask = nil; onExpansion = nil }
}

final class AgentNotch {
    private struct Surface {
        let panel: NotchShelfPanel
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
    private var filesSubscription: AnyCancellable?
    private let volume = SystemVolumeObserver()
    private let brightness = DisplayBrightnessObserver()
    private var brightnessFilter = NotchBrightnessFilter()
    private var hudTask: DispatchWorkItem?
    private let keyTap = SystemLevelKeyTap()
    private let dragCatcher = NotchDragCatcher()
    private let airPods = AirPodsMonitor()
    /// The pairs last seen; nil until the first read, which never alerts.
    private var lastAirPods: [AirPodsReading]?
    private var keyTapSubscription: AnyCancellable?
    private var focusObservers: [NSObjectProtocol] = []
    /// The screen "Display you're using" shows on, by its display ID.
    private var focusedDisplay: CGDirectDisplayID?

    init(model: DockModel, widgets: WidgetStore) {
        self.widgets = widgets
        self.model = model
        // Restricted mode is here too: it holds off the meeting countdown
        // and live AirPods, and stops the key tap.
        subscription = widgets.$hosts.combineLatest(model.$showAgentNotch, model.$agentNotchSettings, model.$restrictedMode)
            .receive(on: DispatchQueue.main).sink { [weak self] _, enabled, preferences, _ in
                guard let self else { return }
                let nextAgents = widgets.widget(AgentStatusWidget.kind) as? AgentStatusWidget
                let nextUsage = preferences.showUsage ? widgets.widget(UsageWidget.kind) as? UsageWidget : nil
                let musicSlot = [preferences.shelfLeadingWidget, preferences.shelfTrailingWidget].contains(.music)
                let nextMedia = preferences.showMedia || musicSlot ? widgets.widget(NowPlayingWidget.kind) as? NowPlayingWidget : nil
                let changed = self.enabled != enabled || self.agents !== nextAgents || self.usage !== nextUsage
                    || self.nowPlaying !== nextMedia
                    || self.preferences.display != preferences.display
                    || self.preferences.showInFullScreen != preferences.showInFullScreen
                self.preferences = preferences
                NotchFileShelf.shared.keep = preferences.filesKeep
                self.enabled = enabled
                self.agents = nextAgents
                self.usage = nextUsage
                self.nowPlaying = nextMedia
                self.bindAlertSources(widgets)
                if changed { self.rebuildPanels() }
                else {
                    self.surfaces.forEach { $0.state.preferences = preferences }
                    self.bindLevels()
                    self.layoutPanels()
                }
            }
        // The key tap starts once Accessibility is granted.
        keyTapSubscription = AccessibilityTrust.shared.$isTrusted.dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.bindLevels() }
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
        // A click outside closes what is not pinned. A pinned shelf stays
        // while you work in other windows (maintainer request), until it is
        // unpinned, closed with its button or Escape, or the toggle hotkey.
        surfaces.filter { !$0.state.pinned }.forEach { $0.state.setExpanded(false) }
    }

    private func rebuildPanels() {
        sessionsSubscription = nil
        mediaSubscription = nil
        surfaces.forEach { $0.state.stop(); $0.panel.close() }
        surfaces = []
        guard enabled, let agents else {
            bindLevels()
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
            let panel = NotchShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            // Without fullScreenAuxiliary the panel stays out of full-screen
            // Spaces, which is the default (SHELF-08).
            var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if preferences.showInFullScreen { behavior.insert(.fullScreenAuxiliary) }
            panel.collectionBehavior = behavior
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = preferences.showBorder
            panel.hidesOnDeactivate = false
            state.onExpansion = { [weak self, weak state] in
                self?.layoutPanels()
                if state?.expanded == true, state?.currentPage == .airPods { self?.airPods.refresh() }
            }
            state.widgetHost = { [weak self] kind in self?.widgets.host(kind) }
            state.pageAvailable = { [weak self, weak state] page in
                switch page {
                case .clipboard: MainActor.assumeIsolated { self?.model?.clipboardHistoryOn == true }
                case .airPods: state?.airPods.isEmpty == false
                default: true
                }
            }
            state.onSearch = { [weak panel] on in panel?.takeKeys(on) }
            state.pointerInside = { [weak panel] in panel.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false }
            let hosting = NSHostingView(rootView: AgentNotchView(agents: agents, usage: usage, nowPlaying: nowPlaying, state: state))
            // `layoutPanels` sets the frame. Without this the hosting view
            // rebuilt its size constraints on every frame of the strip's
            // loader and bars.
            hosting.sizingOptions = []
            panel.contentView = hosting
            surfaces.append(Surface(panel: panel, state: state, screen: screen))
        }
        alerted = Set(preferences.sessions(from: agents.sessions).filter(Self.alerting).map(\.id))
        sessionsSubscription = agents.$sessions.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.alertNewAgents()
            self?.layoutPanels()
        }
        builtAt = Date()
        // The Clipboard page's height follows its entries and pause state.
        clipboardSubscription = MainActor.assumeIsolated {
            ClipboardService.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layoutPanels() }
        }
        // So does the Files page's, with its files.
        filesSubscription = NotchFileShelf.shared.$tray.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layoutPanels() }
        bannerTrack = nowPlaying?.track?.id
        if let nowPlaying {
            mediaSubscription = nowPlaying.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.layoutPanels()
                self?.bannerOnNewTrack()
            }
        }
        bindLevels()
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
    /// Restricted mode keeps calendar events off the strip.
    private func bindAlertSources(_ widgets: WidgetStore) {
        let restricted = MainActor.assumeIsolated { model?.restrictedMode ?? false }
        let nextBattery = preferences.alertBattery ? widgets.widget(BatteryWidget.kind) as? BatteryWidget : nil
        let nextWeather = preferences.alertWeather ? widgets.widget(WeatherWidget.kind) as? WeatherWidget : nil
        let nextCalendar = preferences.meetingsOn(restricted: restricted) ? widgets.widget(CalendarWidget.kind) as? CalendarWidget : nil
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

    private func checkAirPods(_ readings: [AirPodsReading]) {
        defer { lastAirPods = readings }
        // The AirPods page shows while a pair is connected.
        for surface in surfaces where surface.state.airPods != readings { surface.state.airPods = readings }
        layoutPanels()
        guard preferences.alertAirPods, let previous = lastAirPods else { return }
        for alert in AirPodsAlert.detect(previous: previous, current: readings, low: preferences.airPodsLowPercent) {
            switch alert {
            case .connected(let pair):
                showAlert(NotchShelfAlert(activity: .airPods, symbol: pair.symbol, short: pair.lowest.map { "\($0)%" } ?? "",
                                          title: pair.name, detail: pair.detail, parts: pair.parts))
            case .low(let pair):
                showAlert(NotchShelfAlert(activity: .airPods, symbol: pair.symbol, short: pair.lowest.map { "\($0)%" } ?? "",
                                          title: "\(pair.name) low", detail: pair.detail, isWarning: true, parts: pair.parts))
            }
        }
    }

    /// Shelf hotkeys (SHELF-11): registered while the shelf is on, one
    /// Carbon hotkey each (no permission). A press acts on the shelf under
    /// the pointer's display, else the first.
    private var hotkeys: [String: (chord: HotkeyChord, key: HotKey?)] = [:]

    private func bindHotkeys() {
        let shelf = enabled && !surfaces.isEmpty
        let wanted: [(name: String, chord: HotkeyChord?, action: (AgentNotchPresentation) -> Void)] = [
            ("Open or close the shelf", preferences.shelfToggleHotkey, { $0.hotkey(page: nil, toggle: true) }),
            ("Open on Files", preferences.shelfFilesHotkey, { $0.hotkey(page: .files) }),
            ("Search clipboard", preferences.shelfClipboardHotkey, { $0.hotkey(page: .clipboard, search: true) }),
        ]
        var failures: [String: String] = [:]
        for (name, chord, action) in wanted {
            guard shelf, let chord, chord.isRegisterable else {
                hotkeys[name] = nil
                continue
            }
            if hotkeys[name]?.chord == chord, hotkeys[name]?.key != nil { continue }
            // Release first: the same chord cannot be held twice.
            hotkeys[name] = nil
            let key = HotKey(chord: chord, name: "Notch Shelf \(name)") { [weak self] in
                guard let self, let surface = self.hotkeySurface() else { return }
                action(surface.state)
            }
            hotkeys[name] = (chord, key)
            if key == nil { failures[name] = "macOS refused \(chord.displayString). Another app may already use it. Choose another shortcut." }
        }
        if NotchShelfHotkeyStatus.shared.failures != failures { NotchShelfHotkeyStatus.shared.failures = failures }
    }

    private func hotkeySurface() -> Surface? {
        let mouse = NSEvent.mouseLocation
        return surfaces.first { $0.screen.frame.contains(mouse) && $0.panel.isVisible } ?? surfaces.first { $0.panel.isVisible } ?? surfaces.first
    }

    /// Volume and brightness HUD (SHELF-09): listen while the shelf and each
    /// switch are on. Rebound on settings and display changes (the built-in
    /// display goes away with the lid closed).
    private func bindLevels() {
        bindHotkeys()
        let shelf = enabled && !surfaces.isEmpty
        if shelf && preferences.hudVolume {
            volume.onChange = { [weak self] level in
                self?.showHUD(NotchHUD(kind: .volume, level: Double(level.volume), muted: level.muted))
            }
            volume.start()
        } else {
            volume.stop()
        }
        brightness.stop()
        if shelf && preferences.hudBrightness, brightness.start() {
            brightnessFilter = NotchBrightnessFilter(last: brightness.brightness)
            brightness.onChange = { [weak self] value in
                guard let self else { return }
                let showing = self.surfaces.contains { $0.state.hud?.kind == .brightness }
                guard self.brightnessFilter.accept(value, at: Date(), showing: showing) else { return }
                self.showHUD(NotchHUD(kind: .brightness, level: Double(value)))
            }
        }
        let restricted = MainActor.assumeIsolated { model?.restrictedMode ?? false }
        if shelf && preferences.hudReplaceSystem && !restricted && (preferences.hudVolume || preferences.hudBrightness) {
            keyTap.handle = { [weak self] key, fine in self?.levelKey(key, fine: fine) ?? false }
            keyTap.start()
        } else {
            keyTap.stop()
        }
        // A file drag needs a target over the menu bar, or macOS 27 opens
        // Mission Control before it reaches the notch.
        if shelf && surfaces.contains(where: { $0.state.acceptsFiles }) {
            dragCatcher.above = { [weak self] in self?.surfaces.map(\.panel) ?? [] }
            dragCatcher.onHover = { [weak self] screen, inside in self?.surface(on: screen)?.state.fileDrag(inside) }
            dragCatcher.onDrop = { [weak self] screen, urls in
                NotchFileShelf.shared.add(urls)
                self?.surface(on: screen)?.state.fileDrag(false)
            }
            dragCatcher.start()
        } else {
            dragCatcher.stop()
        }
        // AirPods connect and low alerts (SHELF-10), and the AirPods page.
        if shelf && (preferences.alertAirPods || preferences.shelfPages.isOn(.airPods)) {
            airPods.onChange = { [weak self] readings in self?.checkAirPods(readings) }
            airPods.start()
            // Live levels scan Bluetooth LE; restricted mode keeps to the
            // system's own battery report.
            airPods.live = preferences.liveAirPodsOn(restricted: restricted)
        } else {
            airPods.stop()
            lastAirPods = nil
            surfaces.forEach { $0.state.airPods = [] }
        }
        if !shelf, surfaces.contains(where: { $0.state.hud != nil }) {
            hudTask?.cancel()
            surfaces.forEach { $0.state.hud = nil }
        }
    }

    /// A volume or brightness key the tap took (SHELF-09b): applies it as
    /// macOS would and shows the HUD. False sends the key on to macOS.
    private func levelKey(_ key: SystemLevelKey, fine: Bool) -> Bool {
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard preferences.hudVolume, let device = SystemVolumeObserver.defaultDevice(),
                  let level = SystemVolumeObserver.level(device) else { return false }
            if key == .mute {
                guard SystemVolumeObserver.setMuted(!level.muted) else { return false }
                showHUD(NotchHUD(kind: .volume, level: Double(level.volume), muted: !level.muted))
                return true
            }
            let next = SystemLevelKey.step(level.volume, up: key == .volumeUp, fine: fine)
            guard SystemVolumeObserver.setVolume(next) else { return false }
            // Like macOS, a volume key unmutes.
            if level.muted { _ = SystemVolumeObserver.setMuted(false) }
            showHUD(NotchHUD(kind: .volume, level: Double(next)))
            return true
        case .brightnessUp, .brightnessDown:
            guard preferences.hudBrightness, let current = brightness.brightness else { return false }
            let next = SystemLevelKey.step(current, up: key == .brightnessUp, fine: fine)
            guard brightness.setBrightness(next) else { return false }
            showHUD(NotchHUD(kind: .brightness, level: Double(next)))
            return true
        }
    }

    /// The shelf on `screen`, else the first one (a single-display choice).
    private func surface(on screen: NSScreen) -> Surface? {
        surfaces.first { $0.screen.displayID == screen.displayID } ?? surfaces.first
    }

    /// Shows `hud` on the strip for `NotchHUD.duration`; each change restarts it.
    private func showHUD(_ hud: NotchHUD) {
        let appearing = surfaces.contains { $0.state.hud == nil }
        surfaces.forEach { if $0.state.hud != hud { $0.state.hud = hud } }
        hudTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.surfaces.forEach { $0.state.hud = nil }
            self?.layoutPanels()
        }
        hudTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchHUD.duration, execute: task)
        if appearing { layoutPanels() }
    }

    /// Shows `alert` on the strip's right side for 4 s.
    private func showAlert(_ alert: NotchShelfAlert) {
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
        guard preferences.musicBanner, track.isPlaying, musicShowing,
              Date().timeIntervalSince(builtAt) > 3 else { return }
        surfaces.forEach { $0.state.showBanner() }
    }

    /// Music on the strip: something plays, or is paused with Hide when
    /// paused off.
    private var musicShowing: Bool {
        guard preferences.showMedia, let track = nowPlaying?.track else { return false }
        return track.isPlaying || !preferences.musicHideWhenPaused
    }

    static let idleCapsuleWidth: CGFloat = 96
    static let bannerMinWidth: CGFloat = 280

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
        guard let events = calendar?.upcoming, !events.isEmpty else { return nil }
        let starts = events.map { (start: $0.start, end: $0.end, allDay: $0.isAllDay) }
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
            // It wraps the notch; with no notch to wrap it sits inside the
            // menu bar instead, hanging from the top edge at the bar's height.
            let attached = notched
            let inMenuBar = !notched
            let notchWidth = max(0, (screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX)
                                 - (screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX))
            state.notchWidth = attached ? notchWidth : 0
            state.topAttached = attached || inMenuBar
            state.headerHeight = attached ? max(screen.safeAreaInsets.top, preferences.compactHeight) : Self.menuBarHeight(on: screen)
            // Attached, the flared top corners sit inside the frame; widen it so the body keeps its width.
            state.compactWidth = min(screen.frame.width - 24, preferences.compactWidth + state.notchWidth
                                     + (state.topAttached ? 2 * NotchShape.flare : 0))
            // The HUD's bar and number need more room than a narrow strip has.
            if state.hud != nil {
                state.compactWidth = min(screen.frame.width - 24, max(state.compactWidth, NotchHUD.stripWidth(
                    notch: state.notchWidth, flare: state.topAttached ? 2 * NotchShape.flare : 0)))
            }
            if state.meeting != meeting { state.meeting = meeting }
            let active = preferences.stripOrder.filter { activity in
                switch activity {
                case .meeting: meeting != nil
                case .music: playing
                case .agents: !sessions.isEmpty
                case .battery, .weather, .airPods: false
                }
            }
            let strip = NotchShelfStrip.layout(active: active, alert: state.alert?.activity)
            if state.strip != strip { state.strip = strip }
            // Two activities widen a narrow strip rather than crowd its ends.
            if strip.isSplit {
                state.compactWidth = min(screen.frame.width - 24, max(state.compactWidth, NotchShelfStrip.splitWidth(
                    notch: state.notchWidth, flare: state.topAttached ? 2 * NotchShape.flare : 0)))
            }
            // A narrow strip wraps the meeting's timer, or an alert's "20%",
            // under itself.
            if strip.leading == .meeting || strip.trailing == .meeting || state.alert?.short.isEmpty == false {
                state.compactWidth = min(screen.frame.width - 24, max(state.compactWidth, NotchMeetingCard.stripWidth(
                    notch: state.notchWidth, flare: state.topAttached ? 2 * NotchShape.flare : 0)))
            }
            // Without a notch, the shelf's capsule shrinks while nothing runs
            // (Bartender's smaller idle capsule), so the menu bar keeps its room.
            if !notched, strip == NotchShelfStrip(), state.hud == nil {
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
            // The song banner is a name under the strip, barely wider than it.
            let bannerWidth = min(cardWidth, max(state.compactWidth, Self.bannerMinWidth))
            let width = state.expanded ? shelfWidth
                : peeking ? (state.banner && state.card == .music ? bannerWidth : cardWidth) : state.compactWidth
            let contentHeight = AgentNotchView.shelfHeight(page: state.currentPage, preferences: preferences,
                                                           sessionCount: AgentNotchView.providerFiltered(sessions, state.agentProvider).count,
                                                           chips: AgentNotchView.providerChips(sessions).count > 1,
                                                           usageRows: preferences.showUsage ? usage?.usage.count ?? 0 : 0,
                                                           clipboard: clipboard, searching: state.searching,
                                                           files: NotchFileShelf.shared.items.count, airPods: state.airPods.count)
            let height = min(screen.visibleFrame.height - 16, state.headerHeight
                             + (state.expanded ? contentHeight : state.card.map {
                                 state.banner && $0 == .music ? AgentNotchView.bannerHeight
                                     : AgentNotchView.cardHeight($0, preferences: preferences, sessionCount: sessions.count)
                             } ?? 0))
            state.panelWidth = width
            let x = min(screen.frame.maxX - width - 8, max(screen.frame.minX + 8, screen.frame.midX - width / 2))
            let frame = NSRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
            // The window shadow is the other half of the border: it rims the
            // pill's edge, so "Show border" off turns it off too.
            if surface.panel.hasShadow != preferences.showBorder {
                surface.panel.hasShadow = preferences.showBorder
                surface.panel.invalidateShadow()
            }
            let animate = preferences.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && surface.panel.isVisible
            settleShelf(surface, to: frame, panelWidth: shelfWidth, animate: animate)
            // Always shown, so the notch opens with nothing running.
            if !surface.panel.isVisible { surface.panel.orderFrontRegardless() }
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
        MenuBarShelfExclusion.update(surfaces.compactMap { surface in
            let screen = surface.screen.frame
            let height = max(Self.menuBarHeight(on: surface.screen), surface.screen.safeAreaInsets.top)
            let band = CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
            var notch: ClosedRange<CGFloat>?
            if surface.screen.safeAreaInsets.top > 0, let left = surface.screen.auxiliaryTopLeftArea, let right = surface.screen.auxiliaryTopRightArea,
               left.maxX < right.minX { notch = left.maxX...right.minX }
            let width = surface.state.compactWidth
            let header = surface.state.topAttached ? (screen.midX - width / 2)...(screen.midX + width / 2) : nil
            return MenuBarShelfExclusion.rect(band: band, notch: notch, header: header)
        })
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

/// The shelf's panel. It takes the keyboard only while the Clipboard
/// page's search field is up (SHELF-11); otherwise, as in Bartender, the
/// shelf never takes the keyboard from your app. Non-activating, so your
/// app stays frontmost either way.
final class NotchShelfPanel: NSPanel {
    private var takesKeys = false
    override var canBecomeKey: Bool { takesKeys }

    func takeKeys(_ on: Bool) {
        guard on != takesKeys else { return }
        takesKeys = on
        if on {
            orderFrontRegardless()
            makeKey()
        } else if isKeyWindow {
            // Ordering out hands the keyboard back to the app that had it.
            orderOut(nil)
            orderFrontRegardless()
        }
    }
}

/// Shelf hotkeys macOS refused, by name, for Settings.
final class NotchShelfHotkeyStatus: ObservableObject {
    static let shared = NotchShelfHotkeyStatus()
    @Published var failures: [String: String] = [:]
}
