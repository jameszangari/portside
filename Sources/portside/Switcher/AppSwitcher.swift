import AppKit
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
    var activate: @MainActor (SwitcherItem) -> Bool
    /// How long the shortcut must be held before the panel shows. A quicker
    /// release switches without the panel ever appearing.
    var revealDelay: DispatchTimeInterval = .milliseconds(100)

    /// Activation goes through `AppLauncher`, the dock tiles' path, which
    /// unhides the app and works while Portside itself is not active. An
    /// app with no bundle URL is unhidden and activated directly.
    static let live = SwitcherActions(
        modifierFlags: { NSEvent.modifierFlags },
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        activate: { item in
            guard let app = NSRunningApplication(processIdentifier: item.key.pid), !app.isTerminated,
                  app.bundleIdentifier == item.bundleIdentifier else { return false }
            if let url = app.bundleURL, let pinned = PinnedApp(appURL: url) {
                AppLauncher.open(pinned, running: app)
            } else {
                app.unhide()
                app.activate()
            }
            return true
        }
    )
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

/// The standalone app-first switcher (P2-SW-01). A registered Carbon
/// shortcut (default ⌥Tab, never ⌘Tab) opens it; apps come from
/// `WindowRegistry` snapshots in recent-activation order, so it needs no
/// Accessibility. While open the panel is key without activating Portside,
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
    private let logger = Logger(subsystem: "com.james.portside", category: "Switcher")
    private(set) var isEnabled = false
    private var releaseClient: (() -> Void)?
    private var registryWatch: AnyCancellable?
    private var revealWork: DispatchWorkItem?
    private var required: NSEvent.ModifierFlags = []

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
        hotkey = CommandCenterHotkey(registrar: registrar ?? carbon, report: report) { [weak self] in
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
            registryWatch = registry.$snapshot.dropFirst().sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let self, self.state.isOpen else { return }
                    self.send(.appsChanged(snapshot.apps.map(SwitcherItem.init)))
                }
            }
        } else {
            send(.disable)
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
        if case .failed(let chord) = hotkey.status {
            logger.error("switcher hotkey \(chord.displayString, privacy: .public) not registered")
        }
    }

    /// The shortcut fired. Its own keyDown never reaches the panel (Carbon
    /// takes it), so a second press while open arrives here too.
    func hotkeyPressed() {
        guard isEnabled else { return }
        let held = SwitcherModifiers.isHeld(actions.modifierFlags(), required: required)
        send(.trigger(items: registry.snapshot.apps.map(SwitcherItem.init), frontmost: actions.frontmostPID(), held: held))
        // A release between the press and the panel taking key went to the
        // other app. Read the keyboard once now; the reveal reads it again.
        if state.isOpen { recheckModifiers() }
    }

    // MARK: Input from the presenter

    @discardableResult
    func keyPressed(_ key: SwitcherKey) -> Bool {
        guard state.isOpen else { return false }
        send(.key(key))
        return true
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard state.isOpen, !SwitcherModifiers.isHeld(flags, required: required) else { return }
        send(.modifiersReleased)
    }

    func choose(_ key: AppKey) {
        send(.choose(key))
    }

    func focusLost() {
        send(.focusLost)
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
            presenter.present(self)
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
            presenter.dismiss()
            pruneIcons()
        case .activate(let item):
            // Checked right before acting: a quit app or a reused pid is
            // refused and focus stays where it was.
            guard registry.app(item.key) != nil, actions.activate(item) else {
                logger.info("switcher target \(item.name, privacy: .public) is gone; nothing activated")
                return
            }
        case .announce(let message):
            presenter.announce(message)
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
