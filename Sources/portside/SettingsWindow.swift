import SwiftUI

/// Owns the Settings window. Unlike the dock panel this is a normal window.
/// While it is open Portside is a regular app (in the native Dock, Cmd+Tab
/// and its own dock); closing it hands focus back to the app that was
/// frontmost before and returns Portside to an accessory app.
///
/// While Settings is the key window, DockEngine temporarily suppresses
/// auto-hide so the strip stays visible for live preview. Losing key
/// status (another app, miniaturize) or closing restores the saved
/// auto-hide preference without flipping the Settings toggle.
///
/// Every control writes straight to `DockModel`, which persists and
/// publishes, so the dock updates live (like a controlled input in React).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// The activation policy changed (regular while open, accessory after).
    var onActivationPolicyChanged: (() -> Void)?
    /// Settings became or resigned the key window. Used to pin the dock
    /// visible while auto-hide is on and Settings is focused.
    var onKeyFocusChanged: ((Bool) -> Void)?
    /// A screen's visible frame minus the pinned dock (`DockReservation`).
    var usableFrame: ((NSScreen) -> NSRect)?

    private let dockModel: DockModel
    private let layout: DockLayout
    private let trash: TrashController
    private let badges: DockBadges
    private let nativeDock: NativeDockController
    private let widgets: WidgetStore
    /// Read from the system each time the window opens.
    private let launchAtLogin = LaunchAtLogin()
    private var window: NSWindow?
    /// The other app that was frontmost most recently while Settings was
    /// open. Focus goes back to it on close; NSApp.deactivate() alone does
    /// not reliably do that.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var reservationObserver: NSObjectProtocol?
    /// Top-left corner `placeCentered` last set. While the window is still
    /// there, a reservation change re-centers it; once moved, it stays put.
    private var placedTopLeft: NSPoint?

    init(dockModel: DockModel, layout: DockLayout, nativeDock: NativeDockController, trash: TrashController, badges: DockBadges, widgets: WidgetStore) {
        self.widgets = widgets
        self.dockModel = dockModel
        self.layout = layout
        self.nativeDock = nativeDock
        self.trash = trash
        self.badges = badges
    }

    var isOpen: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Re-center whenever the window was closed or miniaturized so it
        // always opens in the same place (primary screen, dead center).
        // Cursor-screen centering drifted when Settings was opened from
        // different edges or displays.
        if !window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            placeCentered(window)
        }
        if reservationObserver == nil {
            // At launch Settings can open before the dock is measured.
            reservationObserver = NotificationCenter.default.addObserver(
                forName: .dockReservationDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window, window.isVisible,
                      self.isAtPlacedPosition(window) else { return }
                self.placeCentered(window, size: window.frame.size)
            }
        }
        launchAtLogin.refresh()
        trash.refresh(reason: "Settings opened")
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previousApp = front
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app != .current else { return }
                self?.previousApp = app
            }
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // The Dock tile is created by the policy change and starts with
            // the generic executable icon; an icon set while accessory does
            // not carry over.
            AppIcon.applyToDockTile()
            DispatchQueue.main.async { AppIcon.applyToDockTile() }
            onActivationPolicyChanged?()
        }
        // Plain activate() right after the policy change is dropped, which
        // leaves Portside last in Cmd+Tab until something else activates it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // activate() is cooperative and the system can decline it. The
        // window must still come up on top, where one click makes it key.
        window.orderFrontRegardless()
        // The toolbar attaches during the first layout and adds its height
        // below the placed frame; center again with the real size.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.isAtPlacedPosition(window) else { return }
            self.placeCentered(window, size: window.frame.size)
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(
            dockModel: dockModel, layout: layout, nativeDock: nativeDock,
            launchAtLogin: launchAtLogin, trash: trash, badges: badges, widgets: widgets
        ))
        // Fixed size, like System Settings: panes scroll instead of growing
        // the window. The toolbar carries the pane title.
        hosting.sizingOptions = []
        // Title only: the window owns its toolbar, so SwiftUI adds no sidebar
        // toggle and panes get the system scroll edge under the title.
        hosting.sceneBridgingOptions = [.title]
        let window = SettingsNSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsLayout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(SettingsLayout.windowSize)
        window.title = "Portside Settings"
        window.toolbar = NSToolbar(identifier: "PortsideSettings")
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Do not restore a saved frame: position is always the primary
        // screen center (see placeCentered).
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame PortsideSettings")
        return window
    }

    /// Dead center of the primary display's visible area (menu bar and a
    /// pinned Portside excluded, like the native Dock). Uses the fixed Settings size, not the live frame, so a
    /// stray resize cannot shift the next open. NSWindow.center() sits
    /// higher than center on purpose, so it is not used.
    private func placeCentered(_ window: NSWindow, size: NSSize? = nil) {
        guard let screen = NSScreen.screens.first else { return }
        let size = size ?? {
            window.setContentSize(SettingsLayout.windowSize)
            return window.frame.size
        }()
        let area = usableFrame?(screen) ?? screen.visibleFrame
        let frame = NSRect(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
        window.setFrame(frame, display: false)
        placedTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    /// Still where `placeCentered` put it. Compares the top-left corner: the
    /// toolbar attaches after placement and grows the window downward.
    private func isAtPlacedPosition(_ window: NSWindow) -> Bool {
        placedTopLeft == NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Tile menus borrow key focus; if Settings grabs it back mid-open the
        // menu dismisses. Hold the menu's key panel and defer dock pinning.
        if MenuKeyFocus.shared.isPresenting {
            MenuKeyFocus.shared.reclaimKey()
            return
        }
        onKeyFocusChanged?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        if MenuKeyFocus.shared.isPresenting { return }
        onKeyFocusChanged?(false)
    }

    func windowWillClose(_ notification: Notification) {
        onKeyFocusChanged?(false)
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        // Hand focus back first, while Portside is still a regular app that
        // owns activation. Dropping to accessory first lets macOS pick an
        // arbitrary app instead.
        if NSApp.isActive {
            if let previousApp, !previousApp.isTerminated {
                previousApp.activate(from: .current)
            } else {
                NSApp.deactivate()
            }
        }
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            guard self?.isOpen != true else { return }
            NSApp.setActivationPolicy(.accessory)
            self?.onActivationPolicyChanged?()
        }
    }
}

/// Cmd+W closes the window. Portside has no File menu to provide it.
private final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shared sizes so every pane lines up.
enum SettingsLayout {
    /// Wide and short: a sidebar plus a scrolling pane.
    static let windowSize: NSSize = {
        #if DEBUG
        // Debug builds: taller window for full-pane screenshots.
        if let height = ProcessInfo.processInfo.environment["PORTSIDE_SETTINGS_HEIGHT"].flatMap(Double.init) {
            return NSSize(width: 830, height: height)
        }
        #endif
        return NSSize(width: 830, height: 560)
    }()
    static let sidebarWidth: CGFloat = 215
    /// Label column for slider rows.
    static let labelWidth: CGFloat = 136
    /// Value column for slider rows ("150 ms", "Instant").
    static let valueWidth: CGFloat = 56
}

/// Secondary helper text under a control.
extension Text {
    func helperStyle() -> some View {
        font(.system(size: 12)).foregroundStyle(.secondary)
    }

    /// Section footer: helper style, leading-aligned under the section
    /// (grouped Forms align footers trailing by default).
    func footerStyle() -> some View {
        helperStyle()
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Root

private enum SettingsTab: String, CaseIterable, Identifiable {
    case dock, appearance, widgets, groups, notch, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .appearance: "Appearance"
        case .widgets: "Widgets"
        case .groups: "Groups"
        case .notch: "Agent Notch"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .dock: "dock.rectangle"
        case .appearance: "paintbrush"
        case .widgets: "square.grid.2x2"
        case .groups: "folder"
        case .notch: "macbook.gen2"
        case .general: "gearshape"
        }
    }
}

/// System Settings-style layout: a fixed sidebar of panes on the left, the
/// selected pane's form on the right. React analogy: a layout route with a
/// nav column and an outlet.
struct SettingsView: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    let nativeDock: NativeDockController
    let launchAtLogin: LaunchAtLogin
    let trash: TrashController
    @ObservedObject var badges: DockBadges
    let widgets: WidgetStore

    @State private var tab: SettingsTab = Self.initialTab

    /// Debug builds: `PORTSIDE_SETTINGS_TAB=widgets` opens that pane, for
    /// screenshots of a sandboxed run.
    private static var initialTab: SettingsTab {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["PORTSIDE_SETTINGS_TAB"], let tab = SettingsTab(rawValue: name) {
            return tab
        }
        #endif
        return .dock
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $tab)
                .navigationSplitViewColumnWidth(min: SettingsLayout.sidebarWidth, ideal: SettingsLayout.sidebarWidth, max: SettingsLayout.sidebarWidth)
        } detail: {
            Group {
                switch tab {
                case .dock: DockSettings(dockModel: dockModel, trash: trash)
                case .appearance: AppearanceSettings(dockModel: dockModel, layout: layout, badges: badges)
                case .widgets: WidgetSettings(dockModel: dockModel, widgets: widgets)
                case .groups: GroupSettings(dockModel: dockModel)
                case .notch: AgentNotchSettingsView(model: dockModel)
                case .general: GeneralSettings(dockModel: dockModel, layout: layout, nativeDock: nativeDock, launchAtLogin: launchAtLogin)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tab.title)
        }
        .frame(width: SettingsLayout.windowSize.width, height: SettingsLayout.windowSize.height)
    }
}

// MARK: - Sidebar

/// App identity at the top, the panes, and the update check at the bottom.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @State private var status: String?
    @State private var checking = false
    @State private var clearStatus: Task<Void, Never>?
    /// Set when a check finds a newer release; presents the update sheet.
    @State private var offer: UpdateOffer?
    /// Where the rows' icons start, from the sidebar's edge. The list's own
    /// insets differ between macOS versions and cannot be set, so the header
    /// and footer read them to share one left edge.
    @State private var rowLeading: CGFloat = 16
    @State private var sidebarLeading: CGFloat = 0
    @State private var firstRowLeading: CGFloat?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let tab = $0 { selection = tab } })) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { x in
                        if tab == SettingsTab.allCases.first { firstRowLeading = x }
                    }
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { identity }
        .safeAreaInset(edge: .bottom, spacing: 0) { updates }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { sidebarLeading = $0 }
        .onChange(of: firstRowLeading) { updateRowLeading() }
        .onChange(of: sidebarLeading) { updateRowLeading() }
    }

    private func updateRowLeading() {
        guard let firstRowLeading else { return }
        rowLeading = max(0, firstRowLeading - sidebarLeading)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(points: 36))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name).font(.headline)
                Text("v\(AppInfo.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Author and build details don't fit the sidebar; hover shows them.
        .help(AppInfo.versionLine)
        .padding(.horizontal, rowLeading)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Message sits above the button; the button stays pinned to the corner.
            if let status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Button(checking ? "Checking…" : "Check for Updates", action: checkForUpdates)
                .controlSize(.small)
                .disabled(checking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The button's bezel fills its frame, while the icons above it have
        // about this much empty margin.
        .padding(.horizontal, rowLeading + 3)
        .padding(.top, 8)
        .padding(.bottom, rowLeading + 3)
        .sheet(item: $offer) { offer in
            UpdateSheet(offer: offer, onClose: { self.offer = nil })
        }
    }

    private func checkForUpdates() {
        clearStatus?.cancel()
        clearStatus = Task { @MainActor in
            checking = true
            let result = await UpdateChecker.check()
            checking = false
            switch result {
            case .available(let version, let page, let dmgURL):
                withAnimation { status = nil }
                offer = UpdateOffer(version: version, releaseURL: page, dmgURL: dmgURL)
                return
            default:
                withAnimation { status = result.message }
            }
            await clearStatusLater()
        }
    }

    private func clearStatusLater() async {
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled else { return }
        withAnimation { status = nil }
    }
}

/// A newer release found by a check.
struct UpdateOffer: Identifiable {
    let version: String
    let releaseURL: URL
    let dmgURL: URL?
    var id: String { version }
}

/// Offers a newer release, then downloads and installs it from inside the
/// sheet. The browser opens only from the Open Release Page button.
struct UpdateSheet: View {
    let offer: UpdateOffer
    let onClose: () -> Void

    private enum Phase {
        case ready
        case working(UpdateStep)
        case failed(String)
    }

    @State private var phase = Phase.ready

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: AppIcon.image(points: 64))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title3.weight(.semibold))
                        Text("You have version \(AppInfo.version).")
                            .foregroundStyle(.secondary)
                    }
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
        }
        .padding(24)
        .frame(width: 460)
    }

    private var title: String {
        switch phase {
        case .ready: "Portside \(offer.version) is available"
        case .working: "Updating to Portside \(offer.version)"
        case .failed: "Couldn't install Portside \(offer.version)"
        }
    }

    /// Why this copy can't install the update itself, if so.
    private var blocker: String? {
        if !UpdateChecker.canInstallInPlace {
            return "This copy isn't running from an installed Portside.app, so it can't replace itself."
        }
        if offer.dmgURL == nil {
            return "This release has no disk image to install."
        }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .ready:
            Text(blocker ?? "Portside will download it, quit, replace itself, and reopen. Your settings are kept.")
                .fixedSize(horizontal: false, vertical: true)
        case .working(let step):
            progress(step)
        case .failed(let reason):
            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// A bar that fills while the size is known and sweeps otherwise.
    private func progress(_ step: UpdateStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch step {
            case .downloading(let received, let total) where total > 0:
                ProgressView(value: Double(received), total: Double(total))
                    .progressViewStyle(.linear)
            default:
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(stepTitle(step))
                Spacer()
                if case .downloading(let received, let total) = step, total > 0 {
                    Text("\(byteCount(received)) of \(byteCount(total))")
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func stepTitle(_ step: UpdateStep) -> String {
        switch step {
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .restarting: "Restarting…"
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .ready:
            HStack {
                Spacer()
                if blocker == nil {
                    Button("Later", action: onClose).keyboardShortcut(.cancelAction)
                    Button("Download and Install", action: install).keyboardShortcut(.defaultAction)
                } else {
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                    Button("Open Release Page", action: openReleasePage).keyboardShortcut(.defaultAction)
                }
            }
        case .working:
            // Nothing to cancel: the app quits as soon as the new one is staged.
            EmptyView()
        case .failed:
            HStack {
                Button("Open Release Page", action: openReleasePage)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Try Again", action: install).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func openReleasePage() {
        NSWorkspace.shared.open(offer.releaseURL)
        onClose()
    }

    private func install() {
        guard let dmgURL = offer.dmgURL else { return }
        phase = .working(.downloading(received: 0, total: -1))
        Task { @MainActor in
            do {
                try await UpdateChecker.downloadAndInstall(dmgURL: dmgURL, version: offer.version) { step in
                    phase = .working(step)
                }
                onClose()
                await UpdateChecker.quitForSwap()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Dock

/// Where the dock sits and how it behaves. Controls that only matter in some
/// states (the hide delays) appear only then, instead of sitting greyed out.
private struct DockSettings: View {
    @ObservedObject private var accessibility = AccessibilityTrust.shared
    @ObservedObject var dockModel: DockModel
    @ObservedObject var trash: TrashController
    @ObservedObject private var activity = AppActivity.shared

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Position", selection: Binding(
                    get: { dockModel.edge },
                    set: { dockModel.setEdge($0) }
                )) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Show Trash in dock", isOn: Binding(
                    get: { dockModel.showTrash },
                    set: { dockModel.setShowTrash($0) }
                ))
                if let notice = trash.notice {
                    Text(notice).helperStyle()
                }
                if trash.accessDenied && !dockModel.trashAccessHintDismissed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Portside needs Full Disk Access (or Finder Automation) to show whether the Trash is full").helperStyle()
                        HStack {
                            Button("Open Full Disk Access") {
                                dockModel.dismissTrashAccessHint()
                                TrashController.openFullDiskAccessSettings()
                            }
                            Button("Dismiss") { dockModel.dismissTrashAccessHint() }
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { dockModel.autoHide },
                    set: { dockModel.setAutoHide($0) }
                )) {
                    Text("Hide dock automatically")
                    Text(dockModel.autoHide
                         ? "The dock slides away until the pointer touches the screen edge."
                         : dockModel.reserveSpace
                            ? "The dock stays visible."
                            : "The dock stays visible, so windows can extend under it.")
                        .helperStyle()
                }

                if !dockModel.autoHide {
                    Toggle(isOn: Binding(
                        get: { dockModel.reserveSpace },
                        set: { on in
                            dockModel.setReserveSpace(on)
                            if on {
                                accessibility.requestAccess(forFeature: "keeping windows clear of the dock")
                            }
                        }
                    )) {
                        Text("Keep windows clear of the dock")
                        Text("Maximized and tiled windows stop at the dock, like they do at the macOS Dock.")
                            .helperStyle()
                    }
                    if dockModel.reserveSpace && !accessibility.isTrusted {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Portside needs Accessibility access to resize other apps' windows. Until then, windows can extend under the dock. If Portside already looks enabled after an update, use Grant Access to reset the stale permission, then quit and reopen Portside.").helperStyle()
                            HStack {
                                Button("Grant Access…") {
                                    accessibility.requestAccess(forFeature: "keeping windows clear of the dock")
                                }
                                Button("Open Accessibility Settings") { accessibility.openSettings() }
                            }
                        }
                    }
                }

                if dockModel.autoHide {
                    SettingsSlider(
                        title: "Reveal delay",
                        value: dockModel.revealDelay,
                        range: DockModel.revealDelayRange,
                        snap: 0.01,
                        format: milliseconds,
                        set: { dockModel.setRevealDelay($0, persist: $1) }
                    )
                    SettingsSlider(
                        title: "Hide delay",
                        value: dockModel.hideDelay,
                        range: DockModel.hideDelayRange,
                        snap: 0.01,
                        format: milliseconds,
                        set: { dockModel.setHideDelay($0, persist: $1) }
                    )
                }
            } header: {
                Text("Auto-hide")
            } footer: {
                if dockModel.autoHide {
                    Text("Auto-hide is paused while Settings is open so you can preview the dock.")
                        .footerStyle()
                }
            }

            Section("Motion") {
                SettingsSlider(
                    title: "Animation duration",
                    value: dockModel.animationDuration,
                    range: DockModel.animationDurationRange,
                    snap: 0.01,
                    format: { $0 == 0 ? "Instant" : milliseconds($0) },
                    set: { dockModel.setAnimationDuration($0, persist: $1) }
                )

                Toggle("Animate opening applications", isOn: Binding(
                    get: { dockModel.animateOpeningApplications },
                    set: { dockModel.setAnimateOpeningApplications($0) }
                ))
            }

            Section("Apps") {
                Toggle("Show indicators for open applications", isOn: Binding(
                    get: { dockModel.showIndicators },
                    set: { dockModel.setShowIndicators($0) }
                ))

                Toggle(isOn: Binding(
                    get: { dockModel.showRecents },
                    set: { dockModel.setShowRecents($0) }
                )) {
                    Text("Show suggested and recent apps in Dock")
                    Text("Up to \(DockModel.recentAppsLimit) apps you quit recently that are not in the dock, after the running apps.").helperStyle()
                }

                Toggle(isOn: Binding(
                    get: { dockModel.dimHiddenApps },
                    set: { dockModel.setDimHiddenApps($0) }
                )) {
                    Text("Make hidden apps translucent")
                    Text("Apps hidden with ⌘H show a faded icon, like the macOS Dock's hidden option.").helperStyle()
                }
            }

            Section {
                activityToggle(\.camera, "Camera", "Green, like the macOS camera dot. Shown on apps using the microphone while a camera is on.")
                activityToggle(\.microphone, "Microphone", "Orange, like the macOS microphone dot.")
                activityToggle(\.audio, "Audio activity", "Shows a static speaker for open audio streams, or an animated speaker for measured playback when enabled below.")
                if dockModel.activityIcons.audio {
                    activityToggle(\.measureAudioPlayback, "Measure actual playback", "Requires System Audio Recording permission. Measures app audio levels in memory; audio is never recorded, saved, or sent anywhere. Silent streams show no playback icon. The permission prompt appears when an app has an active output stream.")
                    if let notice = activity.audioMeasurementNotice {
                        Text(notice).helperStyle()
                    }
                    Button("Open System Audio Recording Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                activityToggle(\.working, "Working", "Pulsing dots while the app and its child processes are busy. Turn it on per app with Show Working Icon in the app's right-click menu.")
            } header: {
                Text("Activity Icons")
            }

            Section {
                Button("Reset Timing to Defaults") { dockModel.resetTimingToDefaults() }
            } footer: {
                Text("Resets reveal delay, hide delay and animation duration.").footerStyle()
            }
        }
    }

    private func activityToggle(_ key: WritableKeyPath<ActivityIconSettings, Bool>, _ title: String, _ help: String) -> some View {
        Toggle(isOn: Binding(
            get: { dockModel.activityIcons[keyPath: key] },
            set: {
                var next = dockModel.activityIcons
                next[keyPath: key] = $0
                dockModel.setActivityIcons(next)
            }
        )) {
            Text(title)
            Text(help).helperStyle()
        }
    }
}

// MARK: - Updates

/// Updates section: flags other installed Portside copies that Open at Login
/// or Spotlight might launch instead of this one.
private struct UpdatesAuthSection: View {
    @State private var status: String?
    @Binding var otherCopies: [InstalledCopy]

    /// Hidden while there is nothing to show, so no header sits alone.
    var body: some View {
        if !otherCopies.isEmpty || status != nil {
            Section {
                ForEach(otherCopies) { copy in
                    otherCopyRow(copy)
                }
                if let status {
                    Text(status).helperStyle()
                }
            } header: {
                Text("Updates")
            }
        }
    }

    /// Only shown when running from an installed .app; under `swift run`
    /// every built copy would be "other".
    static func currentCopies() -> [InstalledCopy] {
        UpdateChecker.canInstallInPlace ? UpdateChecker.otherInstalledCopies() : []
    }

    private func otherCopyRow(_ copy: InstalledCopy) -> some View {
        let path = (copy.url.path as NSString).abbreviatingWithTildeInPath
        let older = UpdateChecker.isNewer(AppInfo.version, than: copy.version)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Another copy: v\(copy.version)")
                Text("\(path)\(older ? ". Older than this one; Open at Login or Spotlight may launch it instead." : "")")
                    .helperStyle()
            }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([copy.url])
            }
            Button("Move to Trash") {
                NSWorkspace.shared.recycle([copy.url]) { _, error in
                    DispatchQueue.main.async {
                        status = error.map { "Couldn't move it to the Trash: \($0.localizedDescription)" }
                            ?? "Moved \(path) to the Trash."
                        otherCopies = Self.currentCopies()
                    }
                }
            }
        }
    }
}

// MARK: - General

/// App-level settings: startup, the Settings shortcut, hiding the macOS
/// Dock, and importing from it.
private struct GeneralSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    let nativeDock: NativeDockController
    @ObservedObject var launchAtLogin: LaunchAtLogin

    @State private var importRequest: ImportRequest?
    @State private var canUndoImport = DockModel.hasBeforeImport
    @State private var importStatus: String?
    @State private var otherCopies: [InstalledCopy] = []

    /// Import clamps the native icon size to what fits, like the slider.
    private var maxIconSize: CGFloat {
        max(layout.fitTileSize, DockModel.iconSizeRange.lowerBound + 1)
    }

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginRow(launchAtLogin: launchAtLogin)
                Toggle("Open Settings when Portside launches", isOn: Binding(
                    get: { dockModel.openSettingsOnLaunch },
                    set: { dockModel.setOpenSettingsOnLaunch($0) }
                ))
            }

            Section {
                HotkeyRecorderButton(
                    title: "Open Settings",
                    chord: dockModel.settingsHotkey,
                    defaultChord: .settingsDefault,
                    onChange: { dockModel.setSettingsHotkey($0) }
                )
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Opens Settings from any app. Default ⌘⇧D. The menu bar Settings… item always uses ⌘,.")
                    .footerStyle()
            }

            Section("Automatic updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { dockModel.automaticUpdateChecks },
                    set: { dockModel.setAutomaticUpdateChecks($0) }
                ))
                Text("Checks at launch and every 24 hours. Portside notifies you when an update is available; choose Install and Relaunch to apply it.").helperStyle()
            }

            Section("Permissions") {
                Button("Open Full Disk Access") { TrashController.openFullDiskAccessSettings() }
                Text("Enable Portside in System Settings, then restart it. macOS requires you to grant this permission yourself. It helps with protected files such as Trash; it does not override Gatekeeper or your employer's security policy.").helperStyle()
            }

            UpdatesAuthSection(otherCopies: $otherCopies)

            Section("macOS Dock") {
                Toggle(isOn: Binding(
                    get: { dockModel.hideNativeDock },
                    // Async: hiding may open a modal alert, which should not
                    // run inside SwiftUI's binding update. The toggle shows
                    // the model, so it only turns on after a verified hide.
                    set: { hidden in DispatchQueue.main.async { nativeDock.setHidden(hidden) } }
                )) {
                    Text("Hide the macOS Dock")
                    Text("Its settings are saved first and restored when you turn this off or quit.").helperStyle()
                    Text("⌥⌘D can interfere. Turn it off in Keyboard Shortcuts > Launchpad & Dock.").helperStyle()
                }
            }

            Section("Import") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Import from macOS Dock...") {
                            importStatus = nil
                            importRequest = ImportRequest(NativeDockImport.readSnapshot())
                        }
                        if canUndoImport {
                            Button("Undo last import") { undoImport() }
                        }
                    }
                    Text(importStatus ?? "Bring apps, position, and icon size over from the macOS Dock. Nothing in the macOS Dock changes.")
                        .helperStyle()
                }
            }
        }
        .sheet(item: $importRequest) { request in
            ImportSheet(
                snapshot: request.snapshot,
                hasExistingFile: true,
                onCancel: { importRequest = nil },
                onImport: { mode, look in
                    importRequest = nil
                    runImport(request.snapshot, replace: mode == .replace, applyLook: look)
                }
            )
        }
        .onAppear {
            canUndoImport = DockModel.hasBeforeImport
            otherCopies = UpdatesAuthSection.currentCopies()
        }
    }

    private func runImport(_ snapshot: NativeDockSnapshot, replace: Bool, applyLook: Bool) {
        do {
            let r = try dockModel.importFromNativeDock(snapshot, replace: replace, applyLook: applyLook, fitTileSize: maxIconSize)
            var parts = ["Added \(r.added) \(r.added == 1 ? "app" : "apps")"]
            if replace { parts.append("removed \(r.removed)") }
            if r.inGroups > 0 { parts.append("\(r.inGroups) already in groups") }
            if snapshot.missingApps > 0 { parts.append("skipped \(snapshot.missingApps) missing") }
            if !snapshot.folderStacks.isEmpty {
                parts.append("\(snapshot.folderStacks.count) folder \(snapshot.folderStacks.count == 1 ? "stack" : "stacks")")
            }
            if snapshot.othersSkipped > 0 {
                parts.append("skipped \(snapshot.othersSkipped) file or missing \(snapshot.othersSkipped == 1 ? "tile" : "tiles")")
            }
            if r.appliedLook { parts.append("set position and size") }
            importStatus = parts.joined(separator: ", ") + "."
        } catch {
            importLogger.error("import failed: \(error.localizedDescription, privacy: .public)")
            importStatus = "Import failed: \(error.localizedDescription)"
        }
        canUndoImport = DockModel.hasBeforeImport
    }

    private func undoImport() {
        do {
            try dockModel.undoLastImport()
            importStatus = "Restored your dock from before the last import."
        } catch {
            importLogger.error("undo failed: \(error.localizedDescription, privacy: .public)")
            importStatus = "Undo failed: \(error.localizedDescription)"
        }
        canUndoImport = DockModel.hasBeforeImport
    }
}


private struct ImportRequest: Identifiable, Equatable {
    let id = UUID()
    let snapshot: NativeDockSnapshot
    init(_ snapshot: NativeDockSnapshot) { self.snapshot = snapshot }
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// "Open Portside at login". Shows the system's status, never a stored
/// value: a failed toggle snaps back to whatever macOS reports.
private struct LaunchAtLoginRow: View {
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { launchAtLogin.isOn },
                set: { launchAtLogin.setEnabled($0) }
            )) {
                Text("Open Portside at login")
                if let helper {
                    Text(helper).helperStyle()
                }
                if let error = launchAtLogin.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .disabled(!launchAtLogin.isAvailable)

            if launchAtLogin.isAvailable && launchAtLogin.status == .requiresApproval {
                Button("Open Login Items Settings...") { launchAtLogin.openLoginItemsSettings() }
                    .font(.system(size: 12))
            }
        }
    }

    private var helper: String? {
        guard launchAtLogin.isAvailable else { return "Available when running Portside.app." }
        switch launchAtLogin.status {
        case .requiresApproval:
            return "Allow Portside in System Settings > General > Login Items."
        case .notFound:
            // Also what macOS 27 reports before the first registration.
            return "Not registered with macOS yet. Turning this on adds Portside to Login Items."
        default:
            return nil
        }
    }
}

private func milliseconds(_ seconds: Double) -> String {
    "\(Int((seconds * 1000).rounded())) ms"
}

/// Continuous Form slider: label in the Form column (aligned with toggles and
/// pickers), no tick marks, value right-aligned. Snaps in the binding.
/// Updates live while dragging and saves once when the drag ends; keyboard
/// and accessibility changes have no drag, so they save at once.
struct SettingsSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// Values round to a multiple of this (0.01 s = 10 ms, 1 pt).
    let snap: Double
    let format: (Double) -> String
    var labelWidth = SettingsLayout.labelWidth
    var valueWidth = SettingsLayout.valueWidth
    /// (new value, persist)
    let set: (Double, Bool) -> Void

    /// The thumb's value while dragging. The slider shows this rather than
    /// `value`, so it always follows the cursor, and the release commits it
    /// (not a `value` captured before the drag, which snapped back).
    @State private var draft: Double?

    var body: some View {
        let shown = draft ?? value
        LabeledContent {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { draft ?? value },
                        set: { raw in
                            let next = snapped(raw)
                            if draft != nil { draft = next }
                            set(next, draft == nil)
                        }
                    ),
                    in: range,
                    onEditingChanged: { editing in
                        if editing {
                            draft = value
                        } else if let final = draft {
                            draft = nil
                            set(final, true)
                        }
                    }
                )
                .controlSize(.regular)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(format(shown))
                // SwiftUI can leave NSSlider tick marks on for some ranges;
                // clear them so the track stays a single clean line.
                .background(SliderTickClear())
                Text(format(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: valueWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            // Fixed width so every Settings section shares one label column,
            // matching toggles/pickers instead of growing with the longest title.
            Text(title)
                .frame(width: labelWidth, alignment: .leading)
        }
    }

    private func snapped(_ raw: Double) -> Double {
        min(max((raw / snap).rounded() * snap, range.lowerBound), range.upperBound)
    }
}

/// Finds the nearest hosting `NSSlider` and removes tick marks.
private struct SliderTickClear: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setFrameSize(NSSize(width: 1, height: 1))
        DispatchQueue.main.async { Self.clear(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.clear(from: nsView) }
    }

    private static func clear(from view: NSView) {
        func findSlider(in root: NSView) -> NSSlider? {
            if let slider = root as? NSSlider { return slider }
            for child in root.subviews {
                if let slider = findSlider(in: child) { return slider }
            }
            return nil
        }
        var node: NSView? = view
        while let current = node {
            if let slider = findSlider(in: current) {
                if slider.numberOfTickMarks != 0 {
                    slider.numberOfTickMarks = 0
                    slider.allowsTickMarkValuesOnly = false
                    slider.needsDisplay = true
                }
                return
            }
            node = current.superview
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    @ObservedObject var badges: DockBadges
    /// Which gradient stop the color editor shows (Solid).
    @State private var editingEndColor = false
    /// The one expanded row, so color editors never stack up.
    @State private var openPanel: Panel?

    private enum Panel { case fill, adjustments, rimColor, solidBorderColor }

    /// Same limit the separator drag clamps to. Kept one point above the
    /// minimum so the slider range is never empty.
    private var maxIconSize: CGFloat {
        max(layout.fitTileSize, DockModel.iconSizeRange.lowerBound + 1)
    }

    var body: some View {
        Form {
            // How big things are. Magnified size only appears once
            // magnification is on, so nothing here is ever greyed out.
            Section("Size") {
                SettingsSlider(
                    title: "Icon size",
                    value: min(Double(dockModel.iconSize), Double(maxIconSize)),
                    range: Double(DockModel.iconSizeRange.lowerBound)...Double(maxIconSize),
                    snap: 1,
                    format: { "\(Int($0)) pt" },
                    set: { dockModel.setIconSize(min(CGFloat($0), maxIconSize), persist: $1) }
                )

                SettingsSlider(
                    title: "Icon gap",
                    value: Double(dockModel.iconGap),
                    range: Double(DockModel.iconGapRange.lowerBound)...Double(DockModel.iconGapRange.upperBound),
                    snap: 1,
                    format: { "\(Int($0)) pt" },
                    set: { dockModel.setIconGap(CGFloat($0), persist: $1) }
                )

                Toggle(isOn: Binding(
                    get: { dockModel.magnificationEnabled },
                    set: { dockModel.setMagnificationEnabled($0) }
                )) {
                    Text("Magnification")
                    Text("Hold Control-Shift over the dock to flip it for a moment.").helperStyle()
                }

                if dockModel.magnificationEnabled {
                    SettingsSlider(
                        title: "Magnified size",
                        value: Double(dockModel.magnifiedSize),
                        range: Double(DockModel.magnifiedSizeRange.lowerBound)...Double(DockModel.magnifiedSizeRange.upperBound),
                        snap: 1,
                        format: { "\(Int($0)) pt" },
                        set: { dockModel.setMagnifiedSize(CGFloat($0), persist: $1) }
                    )
                }
            }

            Section {
                Picker("Icon style", selection: Binding(
                    get: { dockModel.iconStyle },
                    set: { dockModel.setIconStyle($0) }
                )) {
                    ForEach(IconStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Icons")
            } footer: {
                Text(dockModel.iconStyle == .matchSystem
                     ? "Uses the icon style from System Settings > Appearance (Default, Dark, Clear, or Tinted), like the macOS Dock, and updates when you change it."
                     : "Shows each app's own icon artwork and ignores the system icon style.")
                    .footerStyle()
            }

            Section {
                Picker("Background", selection: binding(\.style)) {
                    ForEach(DockBackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch dockModel.background.style {
                case .glass: glassControls
                case .solid: solidControls
                }

                SettingsSlider(
                    title: "Corner radius",
                    value: Double(dockModel.cornerRadius),
                    range: Double(DockModel.cornerRadiusRange.lowerBound)...Double(DockModel.cornerRadiusRange.upperBound),
                    snap: 1,
                    format: { "\(Int($0)) pt" },
                    set: { dockModel.setCornerRadius(CGFloat($0), persist: $1) }
                )
            } header: {
                HStack {
                    Text("Background")
                    Spacer()
                    Button("Reset \(dockModel.background.style.title)") { dockModel.resetBackgroundStyleToDefaults() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .help("Resets this style and the corner radius. Other styles keep their settings.")
                }
            } footer: {
                Text(backgroundHelp).footerStyle()
            }

            if dockModel.background.style == .glass && dockModel.background.glass.variant == .custom {
                customGlassSections
            }

            // Show/hide and color live together so badges are one decision.
            Section {
                Toggle(isOn: Binding(
                    get: { dockModel.showBadges },
                    set: { dockModel.setShowBadges($0) }
                )) {
                    Text("Show notification badges")
                    if badges.isAvailable {
                        Text("The same badges the macOS Dock shows. An app whose badges are off in Notifications settings may still show one here.").helperStyle()
                    } else {
                        Text("Not available on this version of macOS.").helperStyle()
                    }
                }
                .disabled(!badges.isAvailable)

                if badges.isAvailable && dockModel.showBadges {
                    HStack(spacing: 12) {
                        Picker("Badge color", selection: Binding(
                            get: { dockModel.badgeColor },
                            set: { dockModel.setBadgeColor($0) }
                        )) {
                            ForEach(BadgeColor.allCases) { choice in
                                if choice == .custom { Divider() }
                                Text(choice.title).tag(choice)
                            }
                        }
                        DockBadgeLabel(text: "3", iconSize: 48, style: dockModel.badgeStyle)
                        DockBadgeLabel(text: "128", iconSize: 48, style: dockModel.badgeStyle)
                    }
                }
                if dockModel.badgeColor == .custom {
                    // Badges are always opaque, so no Opacity slider.
                    PaletteColorEditor(color: dockModel.badgeCustomColor, showsOpacity: false) { value, persist in
                        dockModel.setBadgeCustomColor(value, persist: persist)
                    }
                }
            } header: {
                Text("Badges")
            } footer: {
                if badges.isAvailable && dockModel.showBadges {
                    Text(dockModel.badgeColor == .macOS
                         ? "The same red as the macOS Dock."
                         : "Text turns black on light colors so counts stay readable.")
                        .footerStyle()
                }
            }

            Section {
                Button("Reset Appearance to Defaults") { dockModel.resetAppearanceToDefaults() }
            } footer: {
                Text("Resets icon style, background and corner radius. Sizes and badges are not changed.").footerStyle()
            }
        }
    }

    private var backgroundHelp: String {
        switch dockModel.background.style {
        case .glass: dockModel.background.glass.variant == .regular
            ? "The macOS Dock's glass. Its blur follows the Liquid Glass slider in System Settings > Appearance."
            : "Starts from the macOS Dock's values. Reset returns to them."
        case .solid: "Your own color or gradient. Each color keeps its own opacity, and Opacity scales the whole fill. Blur softens whatever sits behind the dock (like CSS backdrop-filter)."
        }
    }

    // MARK: Background controls

    private func binding<T>(_ path: WritableKeyPath<DockBackground, T>) -> Binding<T> {
        Binding(
            get: { dockModel.background[keyPath: path] },
            set: { value in dockModel.updateBackground { $0[keyPath: path] = value } }
        )
    }

    private func percentSlider(_ title: String, _ path: WritableKeyPath<DockBackground, Double>) -> SettingsSlider {
        SettingsSlider(
            title: title,
            value: dockModel.background[keyPath: path],
            range: 0...1,
            snap: 0.01,
            format: { "\(Int(($0 * 100).rounded()))%" },
            set: { value, persist in dockModel.updateBackground(persist: persist) { $0[keyPath: path] = value } }
        )
    }

    private func colorEditor(_ path: WritableKeyPath<DockBackground, PaletteColor>, showsOpacity: Bool,
                             opacityTitle: String = "Opacity") -> PaletteColorEditor {
        PaletteColorEditor(color: dockModel.background[keyPath: path], showsOpacity: showsOpacity,
                           opacityTitle: opacityTitle) { value, persist in
            dockModel.updateBackground(persist: persist) { $0[keyPath: path] = value }
        }
    }

    @ViewBuilder private var glassControls: some View {
        Picker("Glass", selection: binding(\.glass.variant)) {
            ForEach(GlassVariant.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var customGlassSections: some View {
        let glass = dockModel.background.glass
        Section("Glass") {
            Toggle("Follow macOS blur", isOn: binding(\.glass.followsSystemBlur))
            if !glass.followsSystemBlur {
                glassSlider("Blur", \.glass.blurRadius, GlassBackground.blurRange, snap: 0.5) { String(format: "%.1f pt", $0) }
            }
            Toggle("Refraction", isOn: binding(\.glass.lens))
            panelRow("Fill", .fill) { ColorChip(color: glass.fill.color, size: 18) }
            if openPanel == .fill {
                colorEditor(\.glass.fill, showsOpacity: true)
            }
            panelRow("Color adjustments", .adjustments) { EmptyView() }
            if openPanel == .adjustments {
                glassSlider("Saturation", \.glass.saturation, GlassBackground.saturationRange, snap: 0.05, format: percent)
                glassSlider("Brightness", \.glass.brightness, GlassBackground.brightnessRange, snap: 0.01) { String(format: "%+.0f%%", $0 * 100) }
                glassSlider("Contrast", \.glass.contrast, GlassBackground.contrastRange, snap: 0.05, format: percent)
            }
        }
        Section {
            percentSlider("Opacity", \.glass.rimOpacity)
            if glass.rimOpacity > 0 {
                glassSlider("Width", \.glass.rimWidth, GlassBackground.rimWidthRange, snap: 0.5) { String(format: "%.1f pt", $0) }
                panelRow("Color", .rimColor) { ColorChip(color: glass.rimColor.opaqueColor, size: 18) }
                if openPanel == .rimColor {
                    colorEditor(\.glass.rimColor, showsOpacity: false)
                }
            }
        } header: {
            Text("Border")
        } footer: {
            Text("The glass's own edge. 35% matches the macOS Dock; 0% removes it.").footerStyle()
        }
    }

    /// A row that expands what sits under it, closing any other open row.
    private func panelRow<Trailing: View>(_ title: String, _ panel: Panel, @ViewBuilder trailing: () -> Trailing) -> some View {
        Button {
            openPanel = openPanel == panel ? nil : panel
        } label: {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(openPanel == panel ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func borderControls(_ path: WritableKeyPath<DockBackground, DockBorder>) -> some View {
        let border = dockModel.background[keyPath: path]
        HStack(spacing: 12) {
            Text("Border")
            Spacer()
            Toggle("Border", isOn: binding(path.appending(path: \.isOn)))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        if border.isOn {
            glassSlider("Border width", path.appending(path: \.width), DockBorder.widthRange, snap: 0.5) { String(format: "%.1f pt", $0) }
            panelRow("Border color", .solidBorderColor) { ColorChip(color: border.color.color, size: 18) }
            if openPanel == .solidBorderColor {
                colorEditor(path.appending(path: \.color), showsOpacity: true)
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func glassSlider(_ title: String, _ path: WritableKeyPath<DockBackground, Double>, _ range: ClosedRange<Double>,
                             snap: Double, format: @escaping (Double) -> String) -> SettingsSlider {
        SettingsSlider(
            title: title,
            value: dockModel.background[keyPath: path],
            range: range,
            snap: snap,
            format: format,
            set: { value, persist in dockModel.updateBackground(persist: persist) { $0[keyPath: path] = value } }
        )
    }

    @ViewBuilder private var solidControls: some View {
        let solid = dockModel.background.solid
        let editingEnd = solid.fill.isGradient && editingEndColor
        Picker("Fill", selection: binding(\.solid.fill)) {
            ForEach(SolidFill.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if solid.fill.isGradient {
            // Two stops: click a chip to edit it.
            HStack(spacing: 10) {
                Text("Colors")
                Spacer()
                ColorChip(color: solid.color.color, isSelected: !editingEnd) { editingEndColor = false }
                    .help(solid.fill == .radial ? "Center color" : "Start color")
                Button {
                    dockModel.updateBackground { bg in
                        swap(&bg.solid.color, &bg.solid.endColor)
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap colors")
                ColorChip(color: solid.endColor.color, isSelected: editingEnd) { editingEndColor = true }
                    .help(solid.fill == .radial ? "Edge color" : "End color")
            }
        } else {
            HStack(spacing: 10) {
                Text("Color")
                Spacer()
                ColorChip(color: solid.color.color)
            }
        }
        // Per-color opacity only matters for gradient stops (a fade); a
        // single color uses the Opacity slider below. Still shown if a
        // single color was left translucent, so it can be undone.
        let stop = editingEnd ? solid.endColor : solid.color
        colorEditor(editingEnd ? \.solid.endColor : \.solid.color,
                    showsOpacity: solid.fill.isGradient || stop.opacity < 1,
                    opacityTitle: solid.fill.isGradient ? "Stop Opacity" : "Color Opacity")
        if solid.fill == .linear {
            SettingsSlider(
                title: "Angle",
                value: solid.angle,
                range: SolidBackground.angleRange,
                snap: 1,
                format: { "\(Int($0))°" },
                set: { value, persist in dockModel.updateBackground(persist: persist) { $0.solid.angle = value } }
            )
        }
        percentSlider("Opacity", \.solid.opacity)
        Toggle("Blur", isOn: binding(\.solid.blur))
        if solid.blur {
            Picker("Blur material", selection: binding(\.solid.blurMaterial)) {
                ForEach(FrostMaterial.allCases) { Text($0.title).tag($0) }
            }
        }
        borderControls(\.solid.border)
    }
}

// MARK: - Widgets

private struct WidgetSettings: View {
    @ObservedObject var dockModel: DockModel
    /// Live widgets, for the row previews.
    @ObservedObject var widgets: WidgetStore

    var body: some View {
        Form {
            // Fixed catalog order, grouped: turning a widget off or on never
            // moves its row. Dock order is set by dragging in the dock.
            ForEach(Array(WidgetCatalog.groups.enumerated()), id: \.offset) { index, group in
                Section {
                    ForEach(group.kinds, id: \.self) { kind in
                        WidgetRow(kind: kind, dockModel: dockModel, host: widgets.hosts.first { $0.id == kind })
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if index == WidgetCatalog.groups.count - 1 {
                        Text("Drag widgets in the dock to reorder them. Sizes apply to the bottom dock; side docks always show Small widgets.").footerStyle()
                    }
                }
            }

            if dockModel.widgetKinds.contains(AgentStatusWidget.kind) || dockModel.showAgentNotch {
                AgentHooksSection()
            }

            if dockModel.widgetKinds.contains(UsageWidget.kind) || dockModel.showAgentNotch {
                Section {
                    ForEach(AgentProvider.all) { provider in
                        Toggle(isOn: Binding(
                            get: { UsageConsent.isShown(provider.id, in: dockModel) },
                            set: { UsageConsent.setShown(provider.id, $0, in: dockModel) }
                        )) {
                            Text("\(provider.name) by \(provider.vendor)")
                            Text(provider.usageDetail).helperStyle()
                        }
                        .toggleStyle(.switch)
                    }
                    Toggle("Allow Copilot CLI quota checks", isOn: Binding(
                        get: { dockModel.usageCopilotCLIEnabled },
                        set: { dockModel.setUsageCopilotCLIEnabled($0) }
                    ))
                    Text("Off by default. Some managed Macs block the Copilot CLI. Leave this off to use GitHub CLI sign-in over HTTPS, and ask IT about proxy or security blocks.").helperStyle()
                } header: {
                    Text("AI Usage Providers")
                } footer: {
                    Text("Refreshes every 5 minutes. Every provider you pick shows on the tile; hover for percentages.").footerStyle()
                }
            }
        }
    }
}

/// One widget: a live preview (the tile itself, at the chosen size) or a
/// dimmed placeholder when off, the name, the size choice, and the switch.
/// Every row is the same height.
private struct WidgetRow: View {
    let kind: String
    @ObservedObject var dockModel: DockModel
    let host: WidgetHost?

    /// Preview tile size: three units fit in `previewWidth`.
    static let previewTile: CGFloat = 26
    static let previewGap: CGFloat = 3
    static var previewWidth: CGFloat { previewTile * 3 + previewGap * 2 }

    var body: some View {
        if let info = WidgetCatalog.info(kind) {
            let enabled = host != nil
            let natural = WidgetCatalog.naturalSize(kind)
            let sizes = WidgetSize.choices(upTo: natural)
            let size = dockModel.widgetSize(for: kind, natural: natural, edge: .bottom)
            HStack(spacing: 12) {
                Group {
                    if let host {
                        host.previewView
                            .environment(\.widgetSize, size)
                    } else {
                        WidgetTile(size: .small) {
                            info.icon
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .opacity(0.6)
                    }
                }
                .environment(\.dockTileSize, Self.previewTile)
                .environment(\.dockIconGap, Self.previewGap)
                .allowsHitTesting(false)
                .frame(width: Self.previewWidth, alignment: .leading)
                .accessibilityHidden(true)

                Text(info.name)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer()
                if sizes.count > 1 {
                    WidgetSizePicker(sizes: sizes, selection: size) { size in
                        withAnimation(.easeOut(duration: 0.15)) { dockModel.setWidgetSize(kind, size) }
                    }
                    .opacity(enabled ? 1 : 0.45)
                }
                Toggle(info.name, isOn: Binding(
                    get: { enabled },
                    set: { on in
                        dockModel.setWidget(kind, enabled: on)
                        if on, kind == UsageWidget.kind {
                            for id in dockModel.usageProviders where !dockModel.usageAllowed(id) {
                                if UsageConsent.request(id) { dockModel.setUsageConsent(id, granted: true) }
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .frame(height: 34)
        }
    }
}

/// Install / remove the hooks the Agents widget reads. Status is re-read
/// when the section appears and after each action.
private struct AgentHooksSection: View {
    @State private var statuses: [String: AgentHooks.Status] = [:]
    @State private var error: String?

    private var found: [AgentHooks.Target] {
        AgentHooks.targets.filter { statuses[$0.id] != .notFound }
    }

    private var installed: Bool {
        !found.isEmpty && found.allSatisfy { statuses[$0.id] == .installed }
    }

    var body: some View {
        Section("Agent Hooks") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.isEmpty ? "No agents found" : installed ? "Installed" : "Not installed")
                    Text(detail).helperStyle()
                }
                Spacer()
                if installed {
                    Button("Remove Hooks") { run(AgentHooks.uninstall) }
                } else {
                    Button("Install Hooks") { run(AgentHooks.install) }
                        .disabled(found.isEmpty)
                }
            }
            if let error {
                Text(error).helperStyle().foregroundStyle(.red)
            }
        }
        .onAppear(perform: reload)
    }

    private var detail: String {
        if found.isEmpty {
            return "Install Claude Code or Codex. The Agents widget reads their hooks."
        }
        let names = found.map(\.name).joined(separator: " and ")
        return installed
            ? "\(names) report to the Agents widget. Restart open sessions to pick up changes."
            : "Lets \(names) report working and done to the Agents widget. Adds tagged entries to their settings (backed up first); other hooks are kept."
    }

    private func reload() {
        statuses = Dictionary(uniqueKeysWithValues: AgentHooks.targets.map { ($0.id, AgentHooks.status($0)) })
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }
}

// MARK: - Groups

private struct GroupSettings: View {
    @ObservedObject var dockModel: DockModel

    var body: some View {
        Form {
            Section {
                Toggle("Open groups on hover", isOn: Binding(
                    get: { dockModel.openGroupsOnHover },
                    set: { dockModel.setOpenGroupsOnHover($0) }
                ))
                if dockModel.openGroupsOnHover {
                    SettingsSlider(
                        title: "Open delay",
                        value: dockModel.groupHoverDelay,
                        range: DockModel.groupHoverDelayRange,
                        snap: 0.01,
                        format: milliseconds,
                        set: { dockModel.setGroupHoverDelay($0, persist: $1) }
                    )
                    SettingsSlider(
                        title: "Close grace",
                        value: dockModel.groupHoverCloseGrace,
                        range: DockModel.groupHoverCloseGraceRange,
                        snap: 0.01,
                        format: milliseconds,
                        set: { dockModel.setGroupHoverCloseGrace($0, persist: $1) }
                    )
                }
            } footer: {
                if dockModel.openGroupsOnHover {
                    Text("Close grace keeps the grid open while you cross the gap from the tile.").footerStyle()
                }
            }

            Section("Groups") {
                if dockModel.groups.isEmpty {
                    Text("No groups yet. Right-click an app in the dock and choose Add to Group.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    ForEach(dockModel.groups) { group in
                        GroupSettingsRow(group: group, dockModel: dockModel)
                    }
                }
            }
        }
    }
}

private struct GroupSettingsRow: View {
    let group: FolderGroup
    @ObservedObject var dockModel: DockModel

    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var choosingIcon = false
    @State private var hovering = false
    @State private var iconHovering = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { choosingIcon = true } label: {
                GroupMiniIcon(group: group)
                    // Hover (or the open picker) shows a pencil, so the
                    // icon reads as editable.
                    .overlay {
                        let shown = iconHovering || choosingIcon
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(shown ? 0.45 : 0))
                            .overlay(
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .opacity(shown ? 1 : 0)
                            )
                            .animation(.easeOut(duration: 0.12), value: shown)
                    }
            }
                .buttonStyle(.plain)
                .onHover { iconHovering = $0 }
                .help("Change the group's dock icon")
                .accessibilityLabel("Change icon")
                .popover(isPresented: $choosingIcon, arrowEdge: .bottom) {
                    GroupIconPicker(icon: group.icon) { dockModel.setGroupIcon(groupID: group.id, to: $0, persist: $1) }
                        .padding(12)
                }

            VStack(alignment: .leading, spacing: 0) {
                nameField
                Text(group.apps.count == 1 ? "1 app" : "\(group.apps.count) apps")
                    .helperStyle()
            }

            Spacer(minLength: 8)

            Button("Change Icon…") { choosingIcon = true }
                .help("Pick a symbol and color for the group's dock tile")
            Button("Ungroup") { dockModel.ungroup(groupID: group.id) }
                .help("Put the apps back in the dock")
            Button("Delete…") { confirmingDelete = true }
                .help("Remove the group and its apps from the dock")
        }
        .padding(.vertical, 2)
        .onAppear { draft = group.name }
        .onChange(of: group.name) { _, name in draft = name }
        .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
        .confirmationDialog(
            "Delete \"\(group.name)\" and remove its \(group.apps.count) apps from the dock?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) { dockModel.removeGroup(groupID: group.id) }
        }
    }

    /// Looks like plain text until hovered or focused, then shows a field
    /// outline. The text stays aligned with the app count below it.
    private var nameField: some View {
        let active = hovering || nameFocused
        return TextField("Name", text: $draft)
            .labelsHidden()
            .textFieldStyle(.plain)
            .focused($nameFocused)
            .onSubmit(commit)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(nameFocused ? Color(nsColor: .textBackgroundColor) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(active ? Color(nsColor: .separatorColor) : .clear)
            )
            .padding(.horizontal, -6)
            .frame(maxWidth: 220, alignment: .leading)
            .onHover { hovering = $0 }
            .accessibilityLabel("Group name")
    }

    /// Blank names revert to the current name.
    private func commit() {
        dockModel.renameGroup(groupID: group.id, to: draft)
        draft = dockModel.groups.first { $0.id == group.id }?.name ?? group.name
    }
}

/// Small 2x2 preview of a group's first four apps, like its dock tile.
private struct GroupMiniIcon: View {
    let group: FolderGroup
    @ObservedObject private var icons = IconCache.shared

    private let size: CGFloat = 36

    var body: some View {
        let cell: CGFloat = 14
        let grid = Array(repeating: GridItem(.fixed(cell), spacing: 2), count: 2)
        if let icon = group.icon {
            GroupIconArtwork(icon: icon, size: size)
        } else {
            appGrid(cell: cell, grid: grid)
        }
    }

    private func appGrid(cell: CGFloat, grid: [GridItem]) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .overlay {
                LazyVGrid(columns: grid, spacing: 2) {
                    ForEach(group.apps.prefix(4)) { app in
                        Image(nsImage: icons.icon(for: app.url))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: cell, height: cell)
                    }
                }
                .frame(width: cell * 2 + 2, height: cell * 2 + 2, alignment: .topLeading)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
