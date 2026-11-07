import AppKit
import os.log
import SwiftUI

/// Command Center: a key-capable, non-activating search panel over the
/// command registry. The frontmost app stays active while it is open (like
/// Spotlight), so cancel normally needs no focus hand-back; focus is restored
/// only if Portside itself became active during the session.
///
/// `CommandCenterState` decides every transition; this class performs the
/// effects (panel, focus, running a command, VoiceOver). It installs a key
/// monitor only while the panel is visible and never polls.
@MainActor
final class CommandCenter: ObservableObject {
    @Published private(set) var state = CommandCenterState()

    private let commands: CommandRegistry
    private let moduleTitle: (String) -> String?
    private let logger = Logger(subsystem: "com.james.portside", category: "CommandCenter")
    private var hotkey: CommandCenterHotkey!
    /// The `commandCenter` module runs. Off: no shortcut, and opening does nothing.
    private(set) var isEnabled = false
    private var panel: CommandCenterPanel?
    private var hostingView: CommandCenterHostingView?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var previousApp: NSRunningApplication?
    private var runTask: Task<Void, Never>?
    private var pendingAnnouncement: DispatchWorkItem?
    /// Top center of the panel in screen coordinates, fixed while it is open
    /// so a result count change grows the panel downward.
    private var anchorTop: NSPoint?

    weak var searchField: NSTextField?
    weak var actionField: NSTextField?

    /// `moduleTitle` maps a command namespace to its module's title. The
    /// registrar and report are for tests; the default is Carbon.
    init(
        commands: CommandRegistry,
        moduleTitle: @escaping (String) -> String?,
        registrar: @escaping CommandCenterHotkey.Registrar = CommandCenterHotkey.carbon,
        report: @escaping (String?) -> Void = { CommandCenterStatus.shared.hotkeyFailure = $0 }
    ) {
        self.commands = commands
        self.moduleTitle = moduleTitle
        hotkey = CommandCenterHotkey(registrar: registrar, report: report) { [weak self] in
            MainActor.assumeIsolated { self?.hotkeyPressed() }
        }
    }

    var hotkeyStatus: CommandCenterHotkey.Status { hotkey.status }

    /// Module start and stop. Turning off releases the shortcut and closes
    /// the panel, canceling a running command.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        CommandCenterStatus.shared.isEnabled = enabled
        if !enabled {
            setHotkey(nil)
            if state.isVisible { send(.key(.commandEscape)) }
        }
    }

    func setHotkey(_ chord: HotkeyChord?) {
        hotkey.update(isEnabled ? chord : nil)
        if case .failed(let chord) = hotkey.status {
            logger.error("command center hotkey \(chord.displayString, privacy: .public) not registered")
        } else if let chord, let conflict = HotkeyConflicts.conflict(for: chord, system: HotkeyConflicts.systemHotkeys(), portside: []) {
            logger.info("command center hotkey: \(conflict, privacy: .public)")
        }
    }

    /// Menu bar entry.
    func open() {
        guard isEnabled else { return }
        send(.open(snapshot()))
    }

    private func hotkeyPressed() {
        guard isEnabled else { return }
        send(.hotkey(snapshot(), panelIsKey: panel?.isKeyWindow ?? false))
    }

    /// Sends one event and performs its effects. Returns whether it was consumed.
    @discardableResult
    func send(_ event: CommandCenterEvent) -> Bool {
        let outcome = state.send(event)
        for effect in outcome.effects { perform(effect) }
        if state.isVisible { syncFocus() }
        return outcome.handled
    }

    /// Fresh registry read: titles and availability as of this moment.
    private func snapshot() -> [CommandCenterItem] {
        commands.descriptors.map { descriptor in
            CommandCenterItem(
                id: descriptor.id,
                title: descriptor.title,
                subtitle: moduleTitle(descriptor.id.namespace) ?? descriptor.id.namespace,
                symbolName: descriptor.symbolName,
                keywords: descriptor.keywords,
                unavailableReason: descriptor.unavailableReason(),
                permissions: descriptor.requiredPermissions.map(\.description)
            )
        }
    }

    // MARK: Effects

    private func perform(_ effect: CommandCenterEffect) {
        switch effect {
        case .present: present()
        case .focusPanel: panel?.makeKey()
        case .dismiss(let restoreFocus): dismiss(restoreFocus: restoreFocus)
        case .run(let id): run(id)
        case .cancelRun: runTask?.cancel()
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .announce(let message): announce(message)
        }
    }

    private func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Build the SwiftUI tree now so the search field exists to take
        // the first keystroke.
        hostingView?.layoutSubtreeIfNeeded()
        anchorTop = Self.anchor(on: Self.screenWithMouse())
        place(size: hostingView?.fittingSize ?? panel.frame.size)
        panel.orderFrontRegardless()
        panel.makeKey()
        if let searchField { panel.makeFirstResponder(searchField) }
        installMonitors()
    }

    private func dismiss(restoreFocus: Bool) {
        removeMonitors()
        pendingAnnouncement?.cancel()
        let previous = previousApp
        previousApp = nil
        anchorTop = nil
        panel?.orderOut(nil)
        if Self.shouldRestoreFocus(
            requested: restoreFocus,
            previousPID: previous?.isTerminated == false ? previous?.processIdentifier : nil,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) {
            previous?.activate(from: .current, options: [])
        }
    }

    /// Restore only on cancel, only to an app that is still running, and
    /// only when Portside took activation during the session. If another
    /// app is frontmost the person moved on; if the previous app still is,
    /// ordering out already hands focus back.
    nonisolated static func shouldRestoreFocus(requested: Bool, previousPID: pid_t?, frontmostPID: pid_t?, ownPID: pid_t) -> Bool {
        guard requested, let previousPID, previousPID != ownPID else { return false }
        return frontmostPID == ownPID
    }

    private func run(_ id: CommandID) {
        runTask?.cancel()
        runTask = Task { @MainActor [weak self, commands] in
            let result = await commands.execute(id)
            self?.send(.finished(id, result))
        }
    }

    /// Coalesced so fast arrow presses or typing speak only the last state.
    private func announce(_ message: String) {
        pendingAnnouncement?.cancel()
        guard !message.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return }
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        pendingAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Focus

    /// Keeps the first responder on the field the mode types into. Deferred
    /// one turn so SwiftUI has inserted a newly shown field.
    private func syncFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, panel.isKeyWindow else { return }
            switch self.state.mode {
            case .searching, .running:
                Self.focus(self.searchField, in: panel)
            case .actions:
                Self.focus(self.actionField, in: panel)
            case .screen:
                if panel.firstResponder is NSTextView { panel.makeFirstResponder(nil) }
            case .hidden:
                break
            }
        }
    }

    private static func focus(_ field: NSTextField?, in panel: NSPanel) {
        guard let field, field.window === panel, field.currentEditor() == nil else { return }
        panel.makeFirstResponder(field)
    }

    // MARK: Events in

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel else { return false }
                return self.handleKeyDown(event, in: panel)
            }
            return consumed ? nil : event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { _ = self?.send(.focusLost) }
        })
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private func handleKeyDown(_ event: NSEvent, in panel: NSPanel) -> Bool {
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        guard let key = CommandCenterKey(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers,
            isComposing: composing
        ) else { return false }
        return send(.key(key))
    }

    // MARK: Panel

    private func makePanel() -> CommandCenterPanel {
        let panel = CommandCenterPanel(
            contentRect: NSRect(x: 0, y: 0, width: CommandCenterLayout.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Command Center"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = CommandCenterPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Instant in and out; no system zoom or fade.
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityLabel("Command Center")
        panel.onResignKey = { [weak self] in
            MainActor.assumeIsolated { _ = self?.send(.focusLost) }
        }

        let root = CommandCenterView(center: self)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.place(size: size)
            }
        let hosting = CommandCenterHostingView(rootView: AnyView(root))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hostingView = hosting
        return panel
    }

    private func place(size: CGSize) {
        guard let panel, let anchorTop, size.width > 0, size.height > 0 else { return }
        let frame = NSRect(
            x: (anchorTop.x - size.width / 2).rounded(),
            y: (anchorTop.y - size.height).rounded(),
            width: size.width,
            height: size.height
        )
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Centered, a fifth of the way down the visible frame (below the menu
    /// bar and the notch).
    private static func anchor(on screen: NSScreen?) -> NSPoint {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.midX, y: visible.maxY - visible.height * 0.2)
    }
}

enum CommandCenterLayout {
    static let width: CGFloat = 640
    static let cornerRadius: CGFloat = 18
    static let rowHeight: CGFloat = 40
    static let visibleRows = 7
}

/// Key-capable but never main, so it takes typing without activating
/// Portside and without changing the Dock or notch panels.
final class CommandCenterPanel: NSPanel {
    /// Above the Dock's overlays: it is the one thing being typed into.
    static let windowLevel = NSWindow.Level(rawValue: OverlayPanel.windowLevel.rawValue + 1)

    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Ordering out also resigns key; only a visible panel losing focus counts.
        if isVisible { onResignKey?() }
    }

    /// Unhandled keys (typing on a details screen) stay silent.
    override func noResponder(for eventSelector: Selector) {}
}

/// Takes the first click while another app is active, so a row click works
/// without a wake-up click.
final class CommandCenterHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
