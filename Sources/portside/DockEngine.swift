import AppKit
import Combine
import os.log

/// Central coordinator for the dock.
///
/// React analogy: this is the container component. `EdgeTracker` and
/// `DockPanel` are dumb children that only emit enter/exit events; all the
/// state (is the cursor "inside" the dock zone, is a hide pending) lives here.
///
/// Timers in the reveal/hide path: exactly one cancelable hide-delay work
/// item, plus an optional cancelable reveal-delay work item that is only
/// used when `DockModel.revealDelay > 0` (it is 0 by default).
final class DockEngine {
    let dockModel: DockModel
    private let runningApps: RunningApps
    /// Live widgets; Settings previews them.
    let widgets: WidgetStore
    /// Shared with the Settings window for the icon size fit limit.
    let layout: DockLayout

    /// Called from the dock's own menus (separator right-click).
    var onOpenSettings: (() -> Void)? {
        get { interactions.onOpenSettings }
        set { interactions.onOpenSettings = newValue }
    }
    private let dockPanel: DockPanel
    private let edgeTracker: EdgeTracker
    private let hover: DockHover
    private let groups: GroupController
    private let stacks: StackController
    private let bouncer: LaunchBouncer
    private let magnifier = Magnifier()
    /// The Trash tile's state. Shared with Settings (Full Disk Access hint).
    let trash = TrashController()
    /// Notification badges from LaunchServices. Shared with Settings.
    let badges = DockBadges()
    /// Screen space the dock takes while hiding is off.
    let reservation = DockReservation()
    /// Fits other apps' windows clear of the reservation.
    private let windowFitter = WindowFitter()
    private var reservationUpdateQueued = false
    private var reservationObservers: [NSObjectProtocol] = []
    private var reservationSubscriptions: [AnyCancellable] = []
    private let flipKeys = MagnifyFlipKeys()
    private var magnifySubscriptions: [AnyCancellable] = []
    private var bounceSettingSubscription: AnyCancellable?
    private var badgeSettingSubscription: AnyCancellable?
    private var activitySettingSubscription: AnyCancellable?
    private let logger = Logger(subsystem: "com.james.portside", category: "DockEngine")

    private var pendingHide: DispatchWorkItem?
    private var pendingReveal: DispatchWorkItem?

    /// True while any menu in Portside is open (item context menus). The menu
    /// sits outside the panel, so without this the hide timer would slide
    /// the dock away from under it.
    private var menuIsOpen = false
    private var menuObservers: [NSObjectProtocol] = []

    /// True while the separator is being dragged. The cursor can leave the
    /// panel mid-drag, and the dock must stay up until the drag ends.
    private var isResizing = false
    /// True while the "Remove group?" alert is up. The cursor is over the
    /// alert, not the dock, but the dock stays revealed until it is closed.
    private var isConfirmingRemoval = false
    /// Drag an item out to remove it. While a drag is on (button held),
    /// exits do not arm the hide and the hide timer will not hide.
    private let dragOut = DragOutController()
    private let interactions = DockInteractions()
    private var edgeSubscription: AnyCancellable?
    private var iconStyleSubscription: AnyCancellable?
    private var autoHideSubscription: AnyCancellable?
    private var accessibilityObserver: NSObjectProtocol?
    private var glassTintObserver: SystemGlassTintObserver?
    /// Global mouse-up: after a button-held edge suppress, reveal if the
    /// cursor is still in an edge zone when the button releases.
    private var mouseUpMonitor: Any?
    /// True while an edge enter was skipped because a mouse button was down
    /// (window drag). Cleared on exit, reveal, or a successful mouse-up check.
    private var revealSuppressedForButtonHold = false
    /// Settings is the key window. While true, auto-hide is suppressed so
    /// live Settings changes stay visible on the strip; the saved
    /// `dockModel.autoHide` preference is not changed.
    private var settingsIsKey = false

    /// Timestamp (CACurrentMediaTime) of the mouseEntered that started the
    /// current reveal, used for the enter -> animation start -> interactive logs.
    private var revealRequestedAt: CFTimeInterval = 0
    /// Event that started the current reveal (mouseEntered or draggingEntered).
    private var revealTrigger = "mouseEntered"

    /// Drag destinations ("edge", "panel", "strip", "group", "stack") a file
    /// drag is over. While any is set and the button is held, exits do not
    /// arm the hide and the hide timer will not hide.
    private var dragTargets: Set<String> = []

    init(dockModel: DockModel = DockModel.load()) {
        self.dockModel = dockModel
        let runningApps = RunningApps()
        runningApps.onQuit = { [weak dockModel] app in
            if let quit = PinnedApp(runningApp: app) { dockModel?.noteAppQuit(quit) }
        }
        self.runningApps = runningApps
        self.widgets = WidgetStore(dockModel: dockModel)
        self.layout = DockLayout()
        self.hover = DockHover(overlay: OverlayPanel())
        self.bouncer = LaunchBouncer(dockModel: dockModel, hover: hover)
        self.groups = GroupController(dockModel: dockModel, runningApps: runningApps, hover: hover, bouncer: bouncer, dragOut: dragOut, badges: badges)
        self.stacks = StackController(dockModel: dockModel, hover: hover)
        let strip = DockStrip(dockModel: dockModel, runningApps: runningApps, widgets: widgets, layout: layout, groups: groups, stacks: stacks, bouncer: bouncer, hover: hover, interactions: interactions, dragOut: dragOut, magnifier: magnifier, trash: trash, badges: badges)
        self.dockPanel = DockPanel(dockModel: dockModel, strip: strip, magnifier: magnifier)
        self.edgeTracker = EdgeTracker(edge: dockModel.edge)
        hover.setEdge(dockModel.edge)
        hover.look = { [weak dockModel] in dockModel?.look }

        reservation.onChange = { [weak windowFitter] _, new in windowFitter?.setReservation(new) }
        reservationSubscriptions = [
            dockModel.$reserveSpace.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.queueReservationUpdate(reason: "keep windows clear setting") },
            // Granted or revoked in System Settings: start or stop fitting.
            AccessibilityTrust.shared.$isTrusted.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.windowFitter.setReservation(self.reservation.current)
                },
        ]

        interactions.onResizingChanged = { [weak self] resizing in
            guard let self else { return }
            self.isResizing = resizing
            self.updateMagnifierSuspension()
            if !resizing {
                self.rearmHideIfCursorOutside(source: "resize ended")
            }
        }

        interactions.onContentSizeChanged = { [weak self, weak dockPanel, weak bouncer] size in
            dockPanel?.contentSizeChanged(size)
            // The panel recenters when it resizes, which moves every tile.
            bouncer?.tilesChanged()
            self?.queueReservationUpdate(reason: "dock resized")
        }

        dragOut.stripRegion = { [weak dockPanel] in dockPanel?.screenFrame }
        dragOut.gridRegion = { [weak groups, weak stacks] in groups?.gridScreenFrame ?? stacks?.gridScreenFrame }
        dragOut.look = { [weak dockModel] in dockModel?.look }
        dragOut.onDraggingChanged = { [weak self] dragging in
            guard let self else { return }
            self.groups.itemDragChanged(dragging, fromStrip: self.dragOut.isFromStrip)
            self.stacks.itemDragChanged(dragging, fromStrip: self.dragOut.isFromStrip)
            self.updateMagnifierSuspension()
            if dragging {
                self.hover.clear()
                if let pendingHide = self.pendingHide {
                    pendingHide.cancel()
                    self.pendingHide = nil
                    self.logger.info("item drag started: pending hide canceled")
                }
            } else {
                // Normal hide delay from here if the drop left the cursor
                // outside the dock.
                self.rearmHideIfCursorOutside(source: "item drag ended")
            }
        }

        hover.stripToScreen = { [weak dockPanel] rect in dockPanel?.screenRect(forStripRect: rect) }
        hover.displayFrame = { [weak magnifier] target in
            magnifier?.displayFrame(id: target.id, base: target.frame) ?? target.frame
        }
        magnifier.onIconPresented = { [weak hover, weak magnifier] id, scale, shift in
            guard let hover, let magnifier, let base = hover.baseFrame(for: id) else { return }
            hover.iconPresented(id: id, frame: magnifier.presentedFrame(base: base, scale: scale, shift: shift))
        }
        magnifier.onRoomChanged = { [weak dockPanel] room in dockPanel?.setMagnifyRoom(room) }
        magnifier.contentSizeProvider = { [weak dockPanel] in dockPanel?.stripSize ?? .zero }
        magnifier.alongLimitsProvider = { [weak dockPanel] in dockPanel?.magnifyAlongLimits ?? (.infinity, .infinity) }
        // A bouncing strip tile keeps its magnified size and follows it.
        magnifier.onLayoutChanged = { [weak bouncer] in bouncer?.magnificationChanged() }
        bouncer.magnifiedDrawSize = { [weak magnifier] in magnifier?.maxDrawnSize ?? 0 }
        bouncer.magnifiedReach = { [weak magnifier] in magnifier?.maxDisplacement ?? 0 }
        bouncer.magnifyMotion = { [weak magnifier] in magnifier?.lastMotion }
        flipKeys.onChange = { [weak self] held in self?.magnifyFlipChanged(held) }
        dockPanel.onStripMouseMoved = { [weak self] point in
            guard let self, self.dockPanel.isRevealed else { return }
            // Control-Shift state rides along with every move (works even
            // when the global flags monitor gets nothing).
            self.flipKeys.update(NSEvent.modifierFlags)
            // Magnify first, so the label hit-tests the new layout.
            self.magnifier.cursorMoved(to: point)
            self.hover.cursorMoved(to: point)
        }
        dockPanel.onMouseDown = { [weak self] in
            self?.hover.clear()
            self?.groups.stripMouseDown(at: NSEvent.mouseLocation)
            self?.stacks.stripMouseDown(at: NSEvent.mouseLocation)
        }

        // The open group's panel is part of "inside the dock": entering it
        // cancels a pending hide, leaving it arms one, like the panel itself.
        interactions.confirmRemoveGroup = { [weak self] group in
            guard let self else { return .cancel }
            self.isConfirmingRemoval = true
            self.updateMagnifierSuspension()
            self.pendingHide?.cancel()
            self.pendingHide = nil
            let choice = GroupRemoval.confirm(group)
            self.isConfirmingRemoval = false
            self.updateMagnifierSuspension()
            self.rearmHideIfCursorOutside(source: "group removal alert closed")
            return choice
        }
        interactions.confirmTrashDrop = { [weak self] target in
            guard let self else { return .cancel }
            self.isConfirmingRemoval = true
            self.updateMagnifierSuspension()
            self.pendingHide?.cancel()
            self.pendingHide = nil
            let choice = DockTrashDrop.confirm(target)
            self.isConfirmingRemoval = false
            self.updateMagnifierSuspension()
            self.rearmHideIfCursorOutside(source: "trash drop alert closed")
            return choice
        }
        interactions.onGroupTapped = { [weak self] id in
            self?.stacks.collapse(reason: "group opened", animated: false)
            self?.groups.toggle(id)
        }
        interactions.onStackTapped = { [weak self] id in
            self?.groups.collapse(reason: "stack opened", animated: false)
            self?.stacks.toggle(id)
        }
        hover.onTargetsChanged = { [weak self] in
            self?.groups.targetsChanged()
            self?.stacks.targetsChanged()
            self?.bouncer.tilesChanged()
        }
        groups.onMouseEntered = { [weak self] in self?.handleEnter(source: "group", event: nil) }
        groups.onMouseExited = { [weak self] in self?.handleExit(source: "group") }
        groups.onCollapsed = { [weak self] in self?.rearmHideIfCursorOutside(source: "group closed") }
        groups.onEditingChanged = { [weak self] editing in
            if !editing { self?.rearmHideIfCursorOutside(source: "rename ended") }
        }
        stacks.onMouseEntered = { [weak self] in self?.handleEnter(source: "stack", event: nil) }
        stacks.onMouseExited = { [weak self] in self?.handleExit(source: "stack") }
        stacks.onCollapsed = { [weak self] in self?.rearmHideIfCursorOutside(source: "stack closed") }
        interactions.onRenameGroup = { [weak self] id in self?.groups.beginRename(id, reason: "tile menu") }
        hover.onHoveredTargetChanged = { [weak self] id in
            self?.groups.hoveredTargetChanged(id)
            self?.trash.hoveredTargetChanged(id)
            self?.magnifier.labelTargetID = id
        }
        // File/app drag over a group or stack tile opens its grid immediately.
        interactions.onDragOverGroupTile = { [weak self] id in self?.groups.dragOverGroupTileChanged(id) }
        interactions.onDragOverStackTile = { [weak self] id in self?.stacks.dragOverStackTileChanged(id) }
        groups.onDragOverGrid = { [weak self] inside, reason in
            if inside {
                self?.handleDragEntered("group")
            } else {
                self?.handleDragExited("group", reason: reason)
            }
        }
        stacks.onDragOverGrid = { [weak self] inside, reason in
            if inside {
                self?.handleDragEntered("stack")
            } else {
                self?.handleDragExited("stack", reason: reason)
            }
        }

        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.menuIsOpen = true
            self.updateMagnifierSuspension()
            // The menu opens where the hover label is; the native Dock hides it.
            self.hover.isSuppressed = true
            let location = NSEvent.mouseLocation
            if self.dockPanel.containsScreenPoint(location),
               !self.groups.containsScreenPoint(location),
               !self.stacks.containsScreenPoint(location) {
                self.groups.stripMenuOpened()
                self.stacks.stripMenuOpened()
            }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.menuIsOpen = false
            self.updateMagnifierSuspension()
            // Forget the cursor first: it is stale after menu tracking (a
            // press-and-hold menu starts with the button down), so no label
            // appears until the next real mouse move reports a fresh point.
            self.hover.clear()
            // An open group or stack grid keeps its own suppression.
            if self.groups.expandedID == nil, self.stacks.expandedID == nil {
                self.hover.isSuppressed = false
            }
            // The hide timer skipped while the menu was up; re-arm it if the
            // cursor ended up outside the dock.
            self.rearmHideIfCursorOutside(source: "menu closed")
        })

        // @Published emits from willSet, before the property holds the new
        // value. Moving the panel there forces a synchronous SwiftUI layout
        // that reads the old edge and leaves the strip stale, so the change
        // is applied on the next main loop turn instead.
        edgeSubscription = dockModel.$edge
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] edge in self?.applyEdge(edge) }
        autoHideSubscription = dockModel.$autoHide
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyEffectiveAutoHide(reason: "preference")
                self?.queueReservationUpdate(reason: "hiding preference")
            }
        IconCache.shared.setStyle(dockModel.iconStyle)
        IconCache.shared.startObservingTheme()
        // Next main loop turn, like the edge: @Published emits from willSet.
        iconStyleSubscription = dockModel.$iconStyle
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { IconCache.shared.setStyle($0) }
        // Settings apply live. Next main loop turn: @Published emits from
        // willSet, and the magnifier reads the model's current values.
        magnifySubscriptions = [
            dockModel.$magnificationEnabled.map { _ in () }.eraseToAnyPublisher(),
            dockModel.$magnifiedSize.map { _ in () }.eraseToAnyPublisher(),
            dockModel.$iconGap.map { _ in () }.eraseToAnyPublisher(),
            dockModel.$edge.map { _ in () }.eraseToAnyPublisher(),
        ].map {
            $0.receive(on: DispatchQueue.main).sink { [weak self] in self?.configureMagnifier() }
        }
        // An open group or stack grid turns magnification off until it closes.
        magnifySubscriptions.append(groups.$expandedID.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMagnifierSuspension() })
        magnifySubscriptions.append(stacks.$expandedID.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMagnifierSuspension() })
        bounceSettingSubscription = dockModel.$animateOpeningApplications
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.bouncer.cancel(reason: "setting turned off") }
        badgeSettingSubscription = dockModel.$showBadges
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.badges.setEnabled(on) }
        activitySettingSubscription = dockModel.$activityIcons
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { AppActivity.shared.configure($0) }

        edgeTracker.onMouseEntered = { [weak self] event, screen in
            self?.handleEdgeEnter(event: event, screen: screen)
        }
        edgeTracker.onMouseExited = { [weak self] in
            self?.revealSuppressedForButtonHold = false
            self?.handleExit(source: "edge")
        }
        dockPanel.onMouseEntered = { [weak self] event in
            self?.handleEnter(source: "panel", event: event)
        }
        dockPanel.onMouseExited = { [weak self] in
            self?.hover.clear()
            self?.magnifier.cursorExited()
            self?.handleExit(source: "panel")
        }
        edgeTracker.onDragEntered = { [weak self] screen in
            self?.applyScreen(screen)
            self?.handleDragEntered("edge")
        }
        edgeTracker.onDragExited = { [weak self] reason in self?.handleDragExited("edge", reason: reason) }
        dockPanel.onDragEntered = { [weak self] in self?.handleDragEntered("panel") }
        dockPanel.onDragExited = { [weak self] reason in self?.handleDragExited("panel", reason: reason) }
        interactions.onDragOverStrip = { [weak self] inside, reason in
            if inside {
                self?.handleDragEntered("strip")
            } else {
                self?.handleDragExited("strip", reason: reason)
            }
        }
        dockPanel.onRevealAnimationStarted = { [weak self] in
            self?.logTiming(label: "animation start")
            // After the timing log: the reveal path itself is unchanged.
            self?.flipKeys.start()
            // Next runloop turn, so nothing is added to the reveal path. The
            // read runs off the main thread and lands during the slide.
            DispatchQueue.main.async {
                self?.badges.setVisible(true)
                AppActivity.shared.setDockVisible(true)
            }
        }
        dockPanel.onHidden = { [weak self] in
            self?.flipKeys.stop()
            self?.badges.setVisible(false)
            AppActivity.shared.setDockVisible(false)
        }
        dockPanel.onPanelInteractive = { [weak self] in
            self?.logTiming(label: "panel interactive")
        }
        dockPanel.onRevealAnimationFinished = { [weak self] in
            guard let self else { return }
            self.logTiming(label: "animation finished")
            // The panel slid under a possibly stationary cursor, so no
            // mouseMoved will arrive. Check the cursor once.
            if let point = self.dockPanel.stripPoint(forScreenPoint: NSEvent.mouseLocation),
               self.dockPanel.containsScreenPoint(NSEvent.mouseLocation) {
                self.magnifier.cursorMoved(to: point)
                self.hover.cursorMoved(to: point)
            }
        }
    }

    /// Start the engine. With auto-hide on, the panel starts hidden and only
    /// the edge window is shown. With it off, the panel is simply up.
    func start() {
        trash.start()
        badges.start(enabled: dockModel.showBadges)
        AppActivity.shared.start(settings: dockModel.activityIcons)
        configureMagnifier()
        // Seed active screen from the cursor before the first layout.
        if let screen = DockScreen.screen(containing: NSEvent.mouseLocation) {
            DockScreen.setActive(screen)
        }
        dockPanel.prepareHidden()
        installMouseUpMonitor()
        if accessibilityObserver == nil {
            accessibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.dockModel.syncReduceTransparency()
            }
            dockModel.syncReduceTransparency()
        }
        if glassTintObserver == nil {
            glassTintObserver = SystemGlassTintObserver { [weak self] in self?.dockModel.syncSystemGlassTint() }
            dockModel.syncSystemGlassTint()
        }
        for name in [NSApplication.didChangeScreenParametersNotification, .dockScreenDidChange] {
            reservationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.queueReservationUpdate(reason: "screen changed")
            })
        }
        queueReservationUpdate(reason: "engine started")
        if effectiveAutoHide {
            edgeTracker.start()
            logger.info("engine started, panel hidden, edge tracker armed on \(NSScreen.screens.count) screen(s)")
        } else {
            dockPanel.show(animated: false)
            logger.info("engine started, auto-hide off, panel revealed, edge tracker idle")
        }
    }

    /// Auto-hide as applied right now: the saved preference, unless Settings
    /// is focused (then the dock stays revealed for live preview).
    private var effectiveAutoHide: Bool {
        dockModel.autoHide && !settingsIsKey
    }

    /// Settings became or resigned the key window. Pin or release auto-hide
    /// without writing `dockModel.autoHide`.
    func settingsKeyFocusChanged(_ focused: Bool) {
        guard settingsIsKey != focused else { return }
        settingsIsKey = focused
        applyEffectiveAutoHide(reason: focused ? "settings focused" : "settings unfocused")
    }

    /// Turn effective auto-hide on or off, live. Off: the edge window goes
    /// away (no tracking at all) and the panel stays revealed. On: the edge
    /// window comes back and the panel hides once the cursor is outside it.
    private func applyEffectiveAutoHide(reason: String) {
        pendingHide?.cancel()
        pendingHide = nil
        pendingReveal?.cancel()
        pendingReveal = nil
        let on = effectiveAutoHide
        if on {
            edgeTracker.start()
            logger.info("auto-hide on (\(reason, privacy: .public)), edge tracker armed")
            rearmHideIfCursorOutside(source: "auto-hide on")
        } else {
            edgeTracker.stop()
            revealRequestedAt = CACurrentMediaTime()
            revealTrigger = "mouseEntered"
            dockPanel.show(animated: true)
            if settingsIsKey, dockModel.autoHide {
                logger.info("auto-hide suppressed (\(reason, privacy: .public)), panel stays revealed")
            } else {
                logger.info("auto-hide off (\(reason, privacy: .public)), panel stays revealed")
            }
        }
    }

    /// Portside switched between regular and accessory (Settings opened or
    /// closed), which decides whether its own tile shows in the strip.
    func activationPolicyChanged() {
        runningApps.activationPolicyChanged()
    }

    /// Stop the engine: hide the panel and tear down the edge tracker.
    func stop() {
        pendingHide?.cancel()
        pendingHide = nil
        pendingReveal?.cancel()
        pendingReveal = nil
        revealSuppressedForButtonHold = false
        settingsIsKey = false
        removeMouseUpMonitor()
        hover.clear()
        magnifier.reset()
        bouncer.cancel(reason: "engine stopped")
        dockPanel.hide(animated: false)
        groups.collapse(reason: "engine stopped", animated: false)
        stacks.collapse(reason: "engine stopped", animated: false)
        edgeTracker.stop()
        widgets.stopAll()
        trash.stop()
        badges.stop()
        AppActivity.shared.stop()
        reservationObservers.forEach(NotificationCenter.default.removeObserver)
        reservationObservers = []
        reservation.update(active: false, edge: dockModel.edge, depth: 0, screenFrame: .zero, reason: "engine stopped")
        logger.info("engine stopped")
    }

    // MARK: - Multi-display

    /// Switch the dock to `screen` and relocate the panel if it changed.
    @discardableResult
    private func applyScreen(_ screen: NSScreen) -> Bool {
        guard DockScreen.setActive(screen) else { return false }
        groups.collapse(reason: "dock moved screens", animated: false)
        stacks.collapse(reason: "dock moved screens", animated: false)
        bouncer.cancel(reason: "dock moved screens")
        magnifier.reset()
        // Panel observes dockScreenDidChange and relocates itself.
        logger.info("dock active screen \(screen.frame.width, format: .fixed(precision: 0))x\(screen.frame.height, format: .fixed(precision: 0))")
        return true
    }

    /// Edge zone enter: pick that display first, then the normal enter path.
    private func handleEdgeEnter(event: NSEvent, screen: NSScreen) {
        applyScreen(screen)
        handleEnter(source: "edge", event: event)
    }

    // MARK: - Button-hold suppress (window drag)

    /// Global mouse-up so a suppressed edge enter can reveal after the
    /// window drag (or any button hold) ends, if the cursor is still on an
    /// edge. Local monitors miss ups owned by other apps.
    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            self?.considerRevealAfterButtonUp()
        }
    }

    private func removeMouseUpMonitor() {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }

    /// After a button release: if we suppressed an edge reveal and the
    /// cursor is still in an edge zone, reveal now.
    private func considerRevealAfterButtonUp() {
        guard revealSuppressedForButtonHold else { return }
        revealSuppressedForButtonHold = false
        guard effectiveAutoHide, !dockPanel.isRevealedOrRevealing else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let location = NSEvent.mouseLocation
        guard edgeTracker.containsScreenPoint(location) else { return }
        if let screen = DockScreen.screen(containing: location) {
            applyScreen(screen)
        }
        logger.info("edge mouseUp after button-hold suppress: revealing")
        handleEnter(source: "edge", event: nil, trigger: "mouseUp")
    }

    /// Move the dock to another screen edge, live. The panel snaps hidden on
    /// the new edge; the next edge touch reveals it from there.
    private func applyEdge(_ edge: DockEdge) {
        groups.collapse(reason: "dock moved", animated: false)
        stacks.collapse(reason: "dock moved", animated: false)
        bouncer.cancel(reason: "dock moved")
        magnifier.reset()
        pendingHide?.cancel()
        pendingHide = nil
        pendingReveal?.cancel()
        pendingReveal = nil
        hover.setEdge(edge)
        dockPanel.setEdge(edge)
        edgeTracker.setEdge(edge)
        if !effectiveAutoHide {
            dockPanel.show(animated: true)
        }
        logger.info("dock moved to the \(edge.rawValue, privacy: .public) edge")
        queueReservationUpdate(reason: "edge changed")
    }

    // MARK: - Reserved space

    /// Recompute the reservation on the next main loop turn. Edge, size,
    /// and screen changes arrive in bursts (an edge change re-measures the
    /// strip); one pass after the burst avoids reporting stale depths.
    private func queueReservationUpdate(reason: String) {
        guard !reservationUpdateQueued else { return }
        reservationUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reservationUpdateQueued = false
            // The saved preference, not `effectiveAutoHide`: Settings pinning
            // the dock for live preview should not move other apps' windows.
            self.reservation.update(
                active: !self.dockModel.autoHide && self.dockModel.reserveSpace,
                edge: self.dockPanel.edge,
                depth: self.dockPanel.reservedDepth,
                screenFrame: DockScreen.frame,
                reason: reason
            )
        }
    }

    // MARK: - Magnification

    private func configureMagnifier() {
        hover.iconGap = dockModel.iconGap
        magnifier.configure(
            enabled: dockModel.magnificationEnabled,
            size: dockModel.magnifiedSize,
            edge: dockModel.edge,
            iconGap: dockModel.iconGap
        )
    }

    /// Control-Shift went down or up while the dock is up: flip
    /// magnification and apply it at once if the cursor is over the dock.
    private func magnifyFlipChanged(_ held: Bool) {
        guard magnifier.setFlipped(held), dockPanel.isRevealed else { return }
        let location = NSEvent.mouseLocation
        guard dockPanel.containsScreenPoint(location),
              let point = dockPanel.stripPoint(forScreenPoint: location) else { return }
        magnifier.cursorMoved(to: point)
        hover.cursorMoved(to: point)
    }

    /// Off during any drag (reorder, drag-out, file drag, separator resize),
    /// and while a group grid, menu or the remove-group alert is open. Back
    /// on with the next mouse move after. A launch bounce does not stop it:
    /// the bouncing icon follows its magnified tile.
    private func updateMagnifierSuspension() {
        var reasons: [String] = []
        if menuIsOpen { reasons.append("menu") }
        if isResizing { reasons.append("resize") }
        if dragOut.isDragging { reasons.append("item drag") }
        if !dragTargets.isEmpty { reasons.append("file drag") }
        if groups.expandedID != nil { reasons.append("group open") }
        if stacks.expandedID != nil { reasons.append("stack open") }
        if isConfirmingRemoval { reasons.append("alert") }
        magnifier.setSuspended(!reasons.isEmpty, reason: reasons.isEmpty ? "clear" : reasons.joined(separator: ", "))
    }

    private func rearmHideIfCursorOutside(source: String) {
        if !isCursorInsideDock(NSEvent.mouseLocation) {
            handleExit(source: source)
        }
    }

    /// Over the panel, the edge zone, or an open group/stack.
    private func isCursorInsideDock(_ location: NSPoint) -> Bool {
        dockPanel.containsScreenPoint(location)
            || edgeTracker.containsScreenPoint(location)
            || groups.containsScreenPoint(location)
            || stacks.containsScreenPoint(location)
    }

    // MARK: - Drag handling
    //
    // A file drag owned by another app (Finder) does not reliably produce
    // mouseEntered on the tracking areas, so the edge zone, the panel and
    // the strip also act as drag destinations and feed the same enter/exit
    // path. None of them polls: AppKit calls them as the drag moves.

    /// A drag is over the dock right now. The button check drops stale
    /// entries if AppKit ever skipped an exit (the drag is over by then).
    private var isDragOverDock: Bool {
        !dragTargets.isEmpty && NSEvent.pressedMouseButtons & 1 != 0
    }

    /// An item is being dragged out of (or around) the dock. Same button
    /// check, in case a drag never saw its end.
    private var isItemDragging: Bool {
        dragOut.isDragging && NSEvent.pressedMouseButtons & 1 != 0
    }

    private func handleDragEntered(_ target: String) {
        dragTargets.insert(target)
        updateMagnifierSuspension()
        if dockPanel.isRevealedOrRevealing {
            logger.info("\(target, privacy: .public) draggingEntered (dock already up)")
        }
        handleEnter(source: target, event: nil, trigger: "draggingEntered")
    }

    /// Exited, ended (released or canceled inside), or dropped on the strip.
    /// Arms the normal hide unless the drag is still over another part of
    /// the dock; the hide timer's own check keeps the dock up while the
    /// cursor stays over it after a drop.
    private func handleDragExited(_ target: String, reason: String) {
        dragTargets.remove(target)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            dragTargets.removeAll()
        }
        updateMagnifierSuspension()
        handleExit(source: target, trigger: "drag \(reason)")
    }

    // MARK: - Enter / exit handling

    private func handleEnter(source: String, event: NSEvent?, trigger: String = "mouseEntered") {
        // Any enter (edge zone or the panel itself) cancels a pending hide.
        if let pendingHide {
            pendingHide.cancel()
            self.pendingHide = nil
            logger.info("\(source, privacy: .public) enter: pending hide canceled")
        }

        if dockPanel.isRevealedOrRevealing {
            return
        }

        // Do not reveal while a mouse button is held (window drag, etc.).
        // File drags use trigger "draggingEntered" and still reveal. After
        // the button releases, considerRevealAfterButtonUp may reveal if the
        // cursor is still on the edge.
        if trigger == "mouseEntered", NSEvent.pressedMouseButtons != 0 {
            revealSuppressedForButtonHold = true
            logger.info("\(source, privacy: .public) enter suppressed: mouse button held (buttons \(NSEvent.pressedMouseButtons))")
            return
        }
        revealSuppressedForButtonHold = false

        revealRequestedAt = CACurrentMediaTime()
        revealTrigger = trigger
        if let event {
            // NSEvent.timestamp is system uptime; compare against the same clock
            // to see how long the event sat in the queue before we got it.
            let queueLatencyMs = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
            logger.info("\(source, privacy: .public) \(trigger, privacy: .public) (event -> handler \(queueLatencyMs, format: .fixed(precision: 2))ms)")
        } else {
            logger.info("\(source, privacy: .public) \(trigger, privacy: .public)")
        }

        let delay = dockModel.revealDelay
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingReveal = nil
                self?.reveal()
            }
            pendingReveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            reveal()
        }
    }

    private func handleExit(source: String, trigger: String = "mouseExited") {
        guard effectiveAutoHide else { return }
        // A drag moving between the edge zone, the panel and the strip, or
        // a tracking-area exit that slips through during the drag.
        if isDragOverDock {
            logger.info("\(source, privacy: .public) \(trigger, privacy: .public): drag still over the dock, hide not armed")
            return
        }
        if isItemDragging {
            logger.info("\(source, privacy: .public) \(trigger, privacy: .public): item drag in progress, hide not armed")
            return
        }
        if let pendingReveal {
            pendingReveal.cancel()
            self.pendingReveal = nil
            logger.info("\(source, privacy: .public) exit: pending reveal canceled")
        }

        guard dockPanel.isRevealedOrRevealing else { return }

        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHide = nil
            guard self.effectiveAutoHide else { return }
            if self.menuIsOpen {
                self.logger.info("hide timer fired but a menu is open, staying revealed")
                return
            }
            if self.isConfirmingRemoval {
                self.logger.info("hide timer fired while the remove-group alert is up, staying revealed")
                return
            }
            if self.isResizing {
                self.logger.info("hide timer fired during a resize drag, staying revealed")
                return
            }
            if self.isDragOverDock {
                self.logger.info("hide timer fired during a drag over the dock, staying revealed")
                return
            }
            if self.isItemDragging {
                self.logger.info("hide timer fired during an item drag, staying revealed")
                return
            }
            if self.groups.isEditing {
                self.logger.info("hide timer fired while a group name is being edited, staying revealed")
                return
            }
            if self.groups.isPinnedOpen || self.stacks.isPinnedOpen {
                self.logger.info("hide timer fired while a clicked-open grid is up, staying revealed")
                return
            }
            // One-shot sanity check, not polling: if the cursor is still over
            // the panel or the edge zone (for example because enter/exit
            // events raced while the panel slid under a stationary cursor),
            // leave the panel up. A later mouseExited will re-arm the hide.
            if self.isCursorInsideDock(NSEvent.mouseLocation) {
                self.logger.info("hide timer fired but cursor is still inside, staying revealed")
                return
            }
            self.logger.info("hide timer fired, hiding")
            self.hover.clear()
            self.magnifier.reset()
            self.bouncer.cancel(reason: "dock hiding")
            self.dockPanel.hide(animated: true)
            // After hide() so the collapse's re-check sees the dock hiding.
            self.groups.collapse(reason: "dock hiding", animated: false)
            self.stacks.collapse(reason: "dock hiding", animated: false)
        }
        pendingHide = work
        let delayMs = dockModel.hideDelay * 1000
        logger.info("\(source, privacy: .public) \(trigger, privacy: .public): hide armed in \(delayMs, format: .fixed(precision: 0))ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + dockModel.hideDelay, execute: work)
    }

    private func reveal() {
        dockPanel.show(animated: true)
    }

    private func logTiming(label: String) {
        guard revealRequestedAt > 0 else { return }
        let ms = (CACurrentMediaTime() - revealRequestedAt) * 1000
        logger.info("timing: \(self.revealTrigger, privacy: .public) -> \(label, privacy: .public) = \(ms, format: .fixed(precision: 2))ms")
    }
}
