import AppKit
import Carbon.HIToolbox
import Combine
import os.log

/// What the switcher reads and does outside Portside. Injected so tests
/// never read the real keyboard or activate an app.
struct SwitcherActions {
    /// The modifier keys down right now (`NSEvent.modifierFlags`: public,
    /// no Accessibility or Input Monitoring).
    var modifierFlags: @MainActor () -> NSEvent.ModifierFlags
    var frontmostPID: @MainActor () -> pid_t?
    /// Brings a running app forward (unhiding it). false when it is gone.
    /// `failed` runs on main if the request is later refused.
    var activate: @MainActor (SwitcherItem, _ failed: @escaping @MainActor () -> Void) -> Bool
    /// Brings one window forward; the result arrives on main. Defaults to
    /// refusing, so a test that does not set it never touches Accessibility.
    var focus: @MainActor (WindowFocusTarget, @escaping @MainActor (WindowFocusResult) -> Void) -> Void = { _, done in done(.refused) }
    /// Display names for window rows, empty with one display.
    var displayNames: @MainActor () -> [CGDirectDisplayID: String] = { [:] }
    /// The pointer, in screen coordinates. Hover selects only after it moves.
    var mouseLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    /// When a modifier key last changed anywhere in the session, on the
    /// `systemUptime` clock (`CGEventSource.secondsSinceLastEventType`:
    /// public, no permission, reads no key content).
    var lastModifierChange: @MainActor () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
            - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
    }
    var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// When the shortcut that is being handled was pressed. The handler runs
    /// on a later main-queue turn (after any work ahead of it), so this is
    /// the event's own time, not the time it is read.
    var pressTime: @MainActor () -> TimeInterval = { HotKey.pressTime ?? ProcessInfo.processInfo.systemUptime }
    /// How long the shortcut must be held before the panel shows. A quicker
    /// release switches without the panel ever appearing.
    var revealDelay: DispatchTimeInterval = .milliseconds(100)

    /// Activation goes through `AppLauncher`, the dock tiles' path, which
    /// unhides the app and works while Portside itself is not active. An
    /// app with no bundle URL is unhidden and activated directly.
    static let live = SwitcherActions(
        modifierFlags: { NSEvent.modifierFlags },
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        activate: { item, failed in
            guard let app = NSRunningApplication(processIdentifier: item.key.pid), !app.isTerminated,
                  app.bundleIdentifier == item.bundleIdentifier else { return false }
            if let url = app.bundleURL, let pinned = PinnedApp(appURL: url) {
                AppLauncher.open(pinned, running: app) { _, error in
                    if error != nil { MainActor.assumeIsolated { failed() } }
                }
            } else {
                app.unhide()
                app.activate()
            }
            return true
        },
        focus: WindowFocuser.focus,
        displayNames: WindowFocuser.displayNames
    )
}

/// The switcher's saved choices (`switcherMode`, `switcherTitleSearch`).
struct SwitcherPreferences: Equatable {
    var mode = SwitcherMode.apps
    /// `/` latches title search while the switcher is open.
    var titleSearch = true
}

/// Draws the switcher. The live one is `SwitcherPanelPresenter`; tests use a
/// recorder. Input (keys, modifier changes, focus loss) comes back through
/// `AppSwitcher.keyPressed`, `modifiersChanged` and `focusLost`.
@MainActor
protocol SwitcherPresenter: AnyObject {
    /// Order the panel in as key but transparent. Takes no activation.
    func present(_ switcher: AppSwitcher)
    func reveal()
    func dismiss()
    func announce(_ message: String)
}

/// Live switcher state for Settings: whether the module runs, and why macOS
/// refused the shortcut.
final class SwitcherStatus: ObservableObject {
    static let shared = SwitcherStatus()
    @Published var isEnabled = false
    @Published var hotkeyFailure: String?
}

/// The standalone switcher (P2-SW-01, windows P2-SW-02). A registered
/// Carbon shortcut (default ⌥Tab, never ⌘Tab) opens it; apps and windows
/// come from `WindowRegistry` snapshots in recent order, so apps need no
/// Accessibility and windows reuse the registry's observers. While open the panel is key without activating Portside,
/// so it reads Tab, arrows, Return, Escape and the modifier release as
/// ordinary local events: no event tap, no polling.
///
/// `SwitcherState` decides every transition; this class performs the
/// effects and holds the registry client and the shortcut while enabled.
@MainActor
final class AppSwitcher: ObservableObject {
    @Published private(set) var state = SwitcherState()

    private let registry: WindowRegistry
    private let actions: SwitcherActions
    private let presenter: SwitcherPresenter
    private let report: (String?) -> Void
    private var hotkey: CommandCenterHotkey!
    private let registrar: CommandCenterHotkey.Registrar
    /// The shortcut's modifiers plus Escape, held only while open. macOS can
    /// take a modifier-Escape chord before it reaches any window (⌥Esc is
    /// Spoken Content's default), so Escape pressed with the modifier still
    /// down would never arrive as a key event and the release would commit.
    private var escape: AnyObject?
    private var escapeChord: HotkeyChord?
    /// Apps this switcher asked macOS to activate that macOS has not yet
    /// reported active, oldest first. Launch Services answers after the next
    /// press can arrive, so a fast second tap reads these as the most recent
    /// (as the Dock updates ⌘Tab's order at commit, not when the app arrives).
    private(set) var requested: [AppKey] = []
    /// Windows this switcher asked to focus that the registry does not yet
    /// list as most recently focused, oldest first (window-first order).
    private var requestedWindows: [WindowID] = []
    private var lastActive: AppKey?
    /// Event times (`systemUptime` clock) of the press that opened the panel
    /// and of the last modifier event the panel received. Event times, not
    /// handling times, so a main thread that was busy cannot hide a release.
    private var openedAt: TimeInterval = 0
    private var lastLocalModifier: TimeInterval = 0
    private var pressedAt: TimeInterval = 0
    /// Handling times of the open and of the last activation of ours that
    /// macOS reported, to tell our own app arriving from the person leaving.
    private var presentedAt: TimeInterval = 0
    private var landedAt: TimeInterval = -1
    /// Where the pointer was at the open or the last hover it caused.
    private var lastPointer: NSPoint?
    private let logger = Logger(subsystem: "com.james.portside", category: "Switcher")
    private(set) var isEnabled = false
    private var releaseClient: (() -> Void)?
    private var registryWatch: AnyCancellable?
    private var revealWork: DispatchWorkItem?
    private var required: NSEvent.ModifierFlags = []
    private(set) var preferences = SwitcherPreferences()
    /// Display names read when the switcher opened, kept while it is open.
    private var displays: [CGDirectDisplayID: String] = [:]

    init(
        registry: WindowRegistry,
        actions: SwitcherActions = .live,
        presenter: SwitcherPresenter? = nil,
        registrar: CommandCenterHotkey.Registrar? = nil,
        report: @escaping (String?) -> Void = { SwitcherStatus.shared.hotkeyFailure = $0 }
    ) {
        self.registry = registry
        self.actions = actions
        self.presenter = presenter ?? SwitcherPanelPresenter()
        self.report = report
        let carbon: CommandCenterHotkey.Registrar = { chord, action in
            HotKey(chord: chord, name: "App Switcher \(chord.displayString)", action: action)
        }
        self.registrar = registrar ?? carbon
        hotkey = CommandCenterHotkey(registrar: self.registrar, report: report) { [weak self] in
            MainActor.assumeIsolated { self?.hotkeyPressed() }
        }
    }

    var hotkeyStatus: CommandCenterHotkey.Status { hotkey.status }
    var hasRegistryClient: Bool { releaseClient != nil }

    /// Module start and stop. Running, it is a `WindowRegistry` client so
    /// activation order is tracked; off, it releases the client and the
    /// shortcut and cancels an open switcher without activating anything.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        SwitcherStatus.shared.isEnabled = enabled
        if enabled {
            releaseClient = registry.addClient()
            lastActive = registry.snapshot.apps.first(where: \.isActive)?.key
            registryWatch = registry.$snapshot.dropFirst().sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.track(snapshot)
                    guard self.state.isOpen else { return }
                    self.send(.appsChanged(SwitcherCatalog.items(snapshot, mode: self.preferences.mode, displays: self.displays)))
                }
            }
        } else {
            send(.disable)
            requested = []
            requestedWindows = []
            lastActive = nil
            setHotkey(nil)
            registryWatch = nil
            releaseClient?()
            releaseClient = nil
        }
    }

    /// A refused chord (⌘Tab) is never registered.
    func setHotkey(_ chord: HotkeyChord?) {
        let allowed = chord.flatMap { SwitcherShortcut.isAllowed($0) ? $0 : nil }
        hotkey.update(isEnabled ? allowed : nil)
        if isEnabled, let chord, let refusal = SwitcherShortcut.refusal(for: chord) {
            report(refusal)
        }
        required = allowed.map(SwitcherModifiers.required) ?? []
        escapeChord = allowed.map {
            HotkeyChord(keyCode: UInt32(kVK_Escape), modifiers: $0.modifiers & UInt32(cmdKey | optionKey | controlKey))
        }
        if case .failed(let chord) = hotkey.status {
            logger.error("switcher hotkey \(chord.displayString, privacy: .public) not registered")
        }
    }

    /// Takes effect the next time the switcher opens.
    func setPreferences(_ preferences: SwitcherPreferences) {
        self.preferences = preferences
    }

    /// Whether window titles can be listed at all (Accessibility allowed).
    var windowsAvailable: Bool { registry.snapshot.accessibilityGranted }

    /// The shortcut fired. Its own keyDown never reaches the panel (Carbon
    /// takes it), so a second press while open arrives here too.
    func hotkeyPressed() {
        guard isEnabled else { return }
        pressedAt = actions.pressTime()
        // A press while open moves on only if the modifier stayed down. One
        // that changed after the open without reaching the panel (still
        // taking key) was a release: that tap commits, and this is a new one.
        if state.isOpen, actions.lastModifierChange() > max(openedAt, lastLocalModifier) + Self.sameEvent {
            send(.modifiersReleased)
        }
        let held = SwitcherModifiers.isHeld(actions.modifierFlags(), required: required)
        if !state.isOpen { displays = actions.displayNames() }
        let items = SwitcherCatalog.items(recentSnapshot(), mode: preferences.mode, displays: displays)
        send(.trigger(items: items, frontmost: requested.last?.pid ?? actions.frontmostPID(), held: held))
        // A release between the press and the panel taking key went to the
        // other app. Read the keyboard once now; the reveal reads it again.
        if state.isOpen { recheckModifiers() }
    }

    // MARK: Input from the presenter

    @discardableResult
    func keyPressed(_ key: SwitcherKey) -> Bool {
        guard state.isOpen else { return false }
        // Search turned off in Settings: / is swallowed like any other key.
        if key == .search, !preferences.titleSearch { return true }
        send(.key(key))
        return true
    }

    /// Two readings of one event's time can differ by rounding; real key
    /// changes are never this close together.
    private static let sameEvent: TimeInterval = 0.002

    /// `keyCode` and `timestamp` come with a local event.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil, timestamp: TimeInterval? = nil) {
        guard state.isOpen else { return }
        if keyCode != nil { lastLocalModifier = timestamp ?? actions.now() }
        // A required modifier going down while it was held since the open
        // means its release went to the other app while the panel was taking
        // key: that release committed, and this press starts the next tap.
        if let keyCode, SwitcherModifiers.isRepress(keyCode: keyCode, flags: flags, required: required) {
            send(.modifiersReleased)
            return
        }
        guard !SwitcherModifiers.isHeld(flags, required: required) else { return }
        send(.modifiersReleased)
    }

    func choose(_ id: SwitcherItem.ID, window: WindowID? = nil) {
        send(.choose(id, window: window))
    }

    /// The pointer is over an entry. Ignored unless the pointer itself moved
    /// (since the open, then since the last hover), so an entry that appears
    /// under a resting pointer, or a list the keys scroll under it, is not
    /// selected (⌘Tab behaves the same).
    func hovered(_ id: SwitcherItem.ID) {
        guard state.isOpen, let lastPointer else { return }
        let point = actions.mouseLocation()
        guard point != lastPointer else { return }
        self.lastPointer = point
        send(.hover(id))
    }

    func focusLost() {
        send(.focusLost)
    }

    /// The panel lost key. While an app this switcher activated is arriving
    /// (its activation not reported yet, or reported since the open), that
    /// app taking key is not the person leaving: true means keep the panel
    /// open and take key back. Anything else cancels. Another app coming
    /// forward still cancels through the registry.
    func panelLostKey() -> Bool {
        guard state.isOpen else { return false }
        if !requested.isEmpty || landedAt >= presentedAt { return true }
        send(.focusLost)
        return false
    }

    /// The panel took key: every later release arrives as a local event, and
    /// one before this moment is caught by reading the keyboard now rather
    /// than at the reveal, so a quick second tap is never taken for "next".
    func panelBecameKey() {
        recheckModifiers()
    }

    /// The reveal delay passed. Internal so tests can fire it.
    func revealDue() {
        revealWork = nil
        recheckModifiers()
        send(.revealDue)
    }

    private func recheckModifiers() {
        modifiersChanged(actions.modifierFlags())
    }

    // MARK: Effects

    private func send(_ event: SwitcherEvent) {
        let effects = state.send(event)
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: SwitcherEffect) {
        switch effect {
        case .present:
            lastPointer = actions.mouseLocation()
            openedAt = pressedAt
            presentedAt = actions.now()
            lastLocalModifier = 0
            if let escapeChord {
                escape = registrar(escapeChord) { [weak self] in
                    MainActor.assumeIsolated { _ = self?.keyPressed(.cancel) }
                }
            }
            presenter.present(self)
            revealWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.revealDue() }
            }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + actions.revealDelay, execute: work)
        case .reveal:
            presenter.reveal()
        case .dismiss:
            revealWork?.cancel()
            revealWork = nil
            escape = nil
            lastPointer = nil
            presenter.dismiss()
            pruneIcons()
        case .activate(let item):
            // Checked right before acting: a quit app or a reused pid is
            // refused and focus stays where it was.
            let key = item.key
            guard registry.app(key) != nil, actions.activate(item, { [weak self] in
                if let index = self?.requested.firstIndex(of: key) { self?.requested.remove(at: index) }
            }) else {
                logger.info("switcher target \(item.name, privacy: .public) is gone; nothing activated")
                return
            }
            // One entry per request: each expects its own activation report.
            requested.append(key)
        case .focus(let item, let window):
            // Checked right before acting: a closed window, a quit app or a
            // reused pid has no target, and nothing else is focused instead.
            guard let target = registry.focusTarget(window.id) else {
                logger.info("switcher window of \(item.name, privacy: .public) is gone; nothing focused")
                return
            }
            // Another app's window also activates that app, so it is a
            // request like `.activate`; one of the app already in front is
            // not (no activation will be reported).
            let key = item.key
            let activates = key != (requested.last ?? lastActive)
            if activates { requested.append(key) }
            requestedWindows.append(window.id)
            actions.focus(target) { [weak self, logger] result in
                guard result != .focused else { return }
                logger.info("switcher window of \(item.name, privacy: .public) not focused: \(String(describing: result), privacy: .public)")
                guard let self else { return }
                if activates, let index = self.requested.lastIndex(of: key) { self.requested.remove(at: index) }
                self.requestedWindows.removeAll { $0 == window.id }
            }
        case .announce(let message):
            presenter.announce(message)
        }
    }

    // MARK: Recent order

    /// The registry snapshot with this switcher's unconfirmed requests first,
    /// the latest first: apps for the app row, windows for window-first mode.
    private func recentSnapshot() -> WindowRegistrySnapshot {
        var snapshot = registry.snapshot
        for key in requested {
            guard let index = snapshot.apps.firstIndex(where: { $0.key == key }) else { continue }
            snapshot.apps.insert(snapshot.apps.remove(at: index), at: 0)
        }
        for id in requestedWindows {
            guard let index = snapshot.windows.firstIndex(where: { $0.id == id }) else { continue }
            snapshot.windows.insert(snapshot.windows.remove(at: index), at: 0)
        }
        // The latest request per app is its focused window, so a tap back to
        // the window that was focused before is not taken for a no-op.
        var focused: [AppKey: WindowID] = [:]
        for id in requestedWindows { focused[id.app] = id }
        snapshot.windows = snapshot.windows.map { window in
            guard let id = focused[window.id.app], window.isFocused != (window.id == id) else { return window }
            return WindowSnapshot(id: window.id, title: window.title, isFocused: window.id == id, isMain: window.isMain,
                                  isMinimized: window.isMinimized, isFullScreen: window.isFullScreen,
                                  frame: window.frame, displayID: window.displayID)
        }
        return snapshot
    }

    /// macOS reported an activation. One of ours confirms it and every
    /// earlier request; any other app means the person moved on without the
    /// switcher, so nothing pending is trusted any more. Quit apps drop out.
    private func track(_ snapshot: WindowRegistrySnapshot) {
        let live = Set(snapshot.apps.map(\.key))
        requested.removeAll { !live.contains($0) }
        // A window request is done once the registry lists it first (or it closed).
        let open = Set(snapshot.windows.map(\.id))
        requestedWindows.removeAll { !open.contains($0) }
        if let first = snapshot.windows.first?.id, let index = requestedWindows.firstIndex(of: first) {
            requestedWindows.removeFirst(index + 1)
        }
        let active = snapshot.apps.first(where: \.isActive)?.key
        guard active != lastActive else { return }
        lastActive = active
        guard let active else { return }
        if let index = requested.firstIndex(of: active) {
            requested.removeFirst(index + 1)
            landedAt = actions.now()
        } else {
            requested = []
            requestedWindows = []
            // Another app came forward (a click, the Dock, ⌘Tab): cancel.
            if state.isOpen { send(.focusLost) }
        }
    }

    // MARK: Icons

    private var icons: [AppKey: NSImage] = [:]

    /// The dock's cached icon for the app's bundle, else the running app's.
    func icon(for item: SwitcherItem) -> NSImage {
        if let cached = icons[item.key] { return cached }
        let app = NSRunningApplication(processIdentifier: item.key.pid)
        let image = app?.bundleURL.map { IconCache.shared.icon(for: $0) } ?? app?.icon
            ?? NSWorkspace.shared.icon(for: .application)
        icons[item.key] = image
        return image
    }

    /// Drops icons of apps that are no longer listed.
    func pruneIcons() {
        let live = Set(registry.snapshot.apps.map(\.key))
        icons = icons.filter { live.contains($0.key) }
    }
}
