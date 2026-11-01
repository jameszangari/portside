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

    private let dockModel: DockModel
    private let layout: DockLayout
    private let trash: TrashController
    private let badges: DockBadges
    private let nativeDock: NativeDockController
    /// Read from the system each time the window opens.
    private let launchAtLogin = LaunchAtLogin()
    private var window: NSWindow?
    /// The other app that was frontmost most recently while Settings was
    /// open. Focus goes back to it on close; NSApp.deactivate() alone does
    /// not reliably do that.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(dockModel: DockModel, layout: DockLayout, nativeDock: NativeDockController, trash: TrashController, badges: DockBadges) {
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // activate() is cooperative and the system can decline it. The
        // window must still come up on top, where one click makes it key.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(
            dockModel: dockModel, layout: layout, nativeDock: nativeDock,
            launchAtLogin: launchAtLogin, trash: trash, badges: badges
        ))
        // Fixed size, like System Settings: panes scroll instead of growing
        // the window. The toolbar carries the pane title.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = SettingsNSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsLayout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(SettingsLayout.windowSize)
        window.title = "Portside Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Do not restore a saved frame: position is always the primary
        // screen center (see placeCentered).
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame PortsideSettings")
        return window
    }

    /// Dead center of the primary display's visible area (menu bar
    /// excluded). Uses the fixed Settings size, not the live frame, so a
    /// stray resize cannot shift the next open. NSWindow.center() sits
    /// higher than center on purpose, so it is not used.
    private func placeCentered(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first else { return }
        window.setContentSize(SettingsLayout.windowSize)
        let size = window.frame.size
        let area = screen.visibleFrame
        let frame = NSRect(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
        window.setFrame(frame, display: false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onKeyFocusChanged?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
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
    static let windowSize = NSSize(width: 760, height: 560)
    static let sidebarWidth: CGFloat = 200
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
    case general, appearance, widgets, groups, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .widgets: "Widgets"
        case .groups: "Groups"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .general: "dock.rectangle"
        case .appearance: "paintbrush"
        case .widgets: "square.grid.2x2"
        case .groups: "folder"
        case .system: "gearshape"
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

    @State private var tab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $tab)
                .navigationSplitViewColumnWidth(min: SettingsLayout.sidebarWidth, ideal: SettingsLayout.sidebarWidth, max: SettingsLayout.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch tab {
                case .general: GeneralSettings(dockModel: dockModel, layout: layout, trash: trash, badges: badges)
                case .appearance: AppearanceSettings(dockModel: dockModel)
                case .widgets: WidgetSettings(dockModel: dockModel)
                case .groups: GroupSettings(dockModel: dockModel)
                case .system: SystemSettings(dockModel: dockModel, layout: layout, nativeDock: nativeDock, launchAtLogin: launchAtLogin)
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
    @State private var clearStatus: Task<Void, Never>?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let tab = $0 { selection = tab } })) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { identity }
        .safeAreaInset(edge: .bottom, spacing: 0) { updates }
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
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Check for Updates", action: checkForUpdates)
                .controlSize(.small)
            // Fixed height so the message never moves the button.
            Text(status ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 28, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func checkForUpdates() {
        clearStatus?.cancel()
        clearStatus = Task { @MainActor in
            let result = await UpdateChecker.check()
            withAnimation { status = result.message }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { status = nil }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    @ObservedObject var trash: TrashController
    @ObservedObject var badges: DockBadges

    /// Same limit the separator drag clamps to. Kept one point above the
    /// minimum so the slider range is never empty.
    private var maxIconSize: CGFloat {
        max(layout.fitTileSize, DockModel.iconSizeRange.lowerBound + 1)
    }

    var body: some View {
        Form {
            Section("Dock") {
                Picker("Position", selection: Binding(
                    get: { dockModel.edge },
                    set: { dockModel.setEdge($0) }
                )) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

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

                SettingsSlider(
                    title: "Magnified size",
                    value: Double(dockModel.magnifiedSize),
                    range: Double(DockModel.magnifiedSizeRange.lowerBound)...Double(DockModel.magnifiedSizeRange.upperBound),
                    snap: 1,
                    format: { "\(Int($0)) pt" },
                    set: { dockModel.setMagnifiedSize(CGFloat($0), persist: $1) }
                )
                .disabled(!dockModel.magnificationEnabled)

                Toggle(isOn: Binding(
                    get: { dockModel.autoHide },
                    set: { dockModel.setAutoHide($0) }
                )) {
                    Text("Hide dock automatically")
                    if !dockModel.autoHide {
                        Text("Windows can extend under the dock while it stays visible.").helperStyle()
                    }
                }

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

                Toggle("Animate opening applications", isOn: Binding(
                    get: { dockModel.animateOpeningApplications },
                    set: { dockModel.setAnimateOpeningApplications($0) }
                ))

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
                HotkeyRecorderButton(
                    title: "Open Settings",
                    chord: dockModel.settingsHotkey,
                    defaultChord: .settingsDefault,
                    onChange: { dockModel.setSettingsHotkey($0) }
                )
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Works from any app. Default ⌘⇧D; distinct from ⌥⌘D (Dock hiding). Clear removes it; the menu bar Settings… item still uses ⌘,.")
                    .footerStyle()
            }

            Section {
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
                SettingsSlider(
                    title: "Animation duration",
                    value: dockModel.animationDuration,
                    range: DockModel.animationDurationRange,
                    snap: 0.01,
                    format: { $0 == 0 ? "Instant" : milliseconds($0) },
                    set: { dockModel.setAnimationDuration($0, persist: $1) }
                )
            } header: {
                HStack {
                    Text("Timing")
                    Spacer()
                    Button("Reset to Defaults") { dockModel.resetTimingToDefaults() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
    }
}

/// macOS Dock hiding, launch at login, and importing from the macOS Dock.
private struct SystemSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    let nativeDock: NativeDockController
    @ObservedObject var launchAtLogin: LaunchAtLogin

    @State private var importRequest: ImportRequest?
    @State private var canUndoImport = DockModel.hasBeforeImport
    @State private var importStatus: String?

    /// Import clamps the native icon size to what fits, like the slider.
    private var maxIconSize: CGFloat {
        max(layout.fitTileSize, DockModel.iconSizeRange.lowerBound + 1)
    }

    var body: some View {
        Form {
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

            Section("Startup") {
                LaunchAtLoginRow(launchAtLogin: launchAtLogin)
                Toggle("Open Settings when Portside launches", isOn: Binding(
                    get: { dockModel.openSettingsOnLaunch },
                    set: { dockModel.setOpenSettingsOnLaunch($0) }
                ))
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
        .onAppear { canUndoImport = DockModel.hasBeforeImport }
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

/// Continuous slider (no tick marks) with a fixed label column on the left
/// and the current value right-aligned. The value snaps in the binding.
/// Updates the model live while dragging and saves once when the drag ends;
/// keyboard and accessibility changes have no drag, so they save at once.
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
        HStack(spacing: 12) {
            Text(title)
                .frame(width: labelWidth, alignment: .leading)
            Slider(
                value: Binding(
                    get: { draft ?? value },
                    set: { raw in
                        let next = snapped(raw)
                        if draft != nil { draft = next }
                        set(next, draft == nil)
                    }
                ),
                in: range
            ) {
                Text(title)
            } onEditingChanged: { editing in
                if editing {
                    draft = value
                } else if let final = draft {
                    draft = nil
                    set(final, true)
                }
            }
            .labelsHidden()
            .accessibilityValue(format(shown))
            Text(format(shown))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private func snapped(_ raw: Double) -> Double {
        min(max((raw / snap).rounded() * snap, range.lowerBound), range.upperBound)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var dockModel: DockModel
    /// Which gradient stop the color editor shows (Solid).
    @State private var editingEndColor = false

    private var styles: [DockBackgroundStyle] {
        DockBackgroundStyle.allCases.filter { $0 != .glass || DockBackgroundStyle.isGlassAvailable }
    }

    var body: some View {
        Form {
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
                    ForEach(styles) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch dockModel.background.style.effective {
                case .glass: glassControls
                case .frosted: frostedControls
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
                    Text("Dock")
                    Spacer()
                    Button("Reset \(dockModel.background.style.effective.title)") { dockModel.resetBackgroundStyleToDefaults() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .help("Resets this style and the corner radius. Other styles keep their settings.")
                }
            } footer: {
                Text(backgroundHelp).footerStyle()
            }

            Section {
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
                if dockModel.badgeColor == .custom {
                    // Badges are always opaque, so no Opacity slider.
                    PaletteColorEditor(color: dockModel.badgeCustomColor, showsOpacity: false) { value, persist in
                        dockModel.setBadgeCustomColor(value, persist: persist)
                    }
                }
            } header: {
                Text("Badges")
            } footer: {
                Text(dockModel.badgeColor == .macOS
                     ? "The same red as the macOS Dock."
                     : "Text turns black on light colors so counts stay readable.")
                    .footerStyle()
            }
        }
    }

    private var backgroundHelp: String {
        switch dockModel.background.style.effective {
        case .glass: SeeThroughGlass.isAvailable
            ? "The system Liquid Glass, same as the macOS Dock. Regular is frosted; Clear is see-through with refraction at the edges. Strength fills the glass with a neutral shade, or with the tint color when Tint is on."
            : "The system Liquid Glass, same as the macOS Dock. Clear is lighter than Regular. Strength fills the glass with a neutral shade, or with the tint color when Tint is on."
        case .frosted: "A blur material you tune yourself. Material sets the blur, Strength how opaque it is; the tint's own opacity sets how strong the color is."
        case .solid: "Your own color or gradient. Each color keeps its own opacity, and Opacity scales the whole fill."
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

    /// Tint switch with the palette editor under it when on. The switch
    /// stays at the trailing edge; a chip of the result sits to its left,
    /// so the switch never moves under the cursor.
    @ViewBuilder
    /// Turning it off keeps the color in `saved`; turning it on restores it.
    private func tintRow(_ path: WritableKeyPath<DockBackground, PaletteColor?>,
                         saved: WritableKeyPath<DockBackground, PaletteColor?>, showsOpacity: Bool,
                         starting: PaletteColor, onEnable: @escaping (inout DockBackground) -> Void = { _ in }) -> some View {
        let tint = dockModel.background[keyPath: path]
        HStack(spacing: 12) {
            Text("Tint")
            Spacer()
            if let tint {
                ColorChip(color: tint.color)
            }
            Toggle("Tint", isOn: Binding(
                get: { dockModel.background[keyPath: path] != nil },
                set: { on in
                    dockModel.updateBackground { bg in
                        if on {
                            bg[keyPath: path] = bg[keyPath: saved] ?? starting
                            bg[keyPath: saved] = nil
                            onEnable(&bg)
                        } else {
                            bg[keyPath: saved] = bg[keyPath: path]
                            bg[keyPath: path] = nil
                        }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        if let tint {
            PaletteColorEditor(color: tint, showsOpacity: showsOpacity) { value, persist in
                dockModel.updateBackground(persist: persist) { $0[keyPath: path] = value }
            }
        }
    }

    @ViewBuilder private var glassControls: some View {
        Picker("Glass", selection: binding(\.glass.variant)) {
            ForEach(GlassVariant.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        percentSlider("Strength", \.glass.strength)
        // Glass tints are opaque (Strength sets how much shows). A tint at
        // 0% strength would be invisible, so turning it on brings the
        // strength up to where the color shows.
        tintRow(\.glass.tint, saved: \.glass.savedTint, showsOpacity: false, starting: .brandNavy) { bg in
            bg.glass.strength = max(bg.glass.strength, 0.35)
        }
    }

    @ViewBuilder private var frostedControls: some View {
        Picker("Material", selection: binding(\.frosted.material)) {
            ForEach(FrostMaterial.allCases) { Text($0.title).tag($0) }
        }
        percentSlider("Strength", \.frosted.strength)
        tintRow(\.frosted.tint, saved: \.frosted.savedTint, showsOpacity: true, starting: {
            var navy = PaletteColor.brandNavy
            navy.opacity = 0.35
            return navy
        }())
        Toggle("Border", isOn: binding(\.frosted.border))
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
        Toggle("Border", isOn: binding(\.solid.border))
    }
}

// MARK: - Widgets

private struct WidgetSettings: View {
    @ObservedObject var dockModel: DockModel
    /// Widget being dragged in the list, nil when no drag is in progress.
    @State private var dragging: String?

    private var available: [String] {
        WidgetCatalog.allKinds.filter { !dockModel.widgetKinds.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                // A grouped Form ignores .onMove, so enabled rows reorder
                // live under the drag with onDrag/onDrop instead.
                ForEach(dockModel.widgetKinds, id: \.self) { kind in
                    row(kind, enabled: true)
                        .contentShape(Rectangle())
                        .onDrag {
                            dragging = kind
                            return NSItemProvider(object: kind as NSString)
                        }
                        .onDrop(of: [.text], delegate: WidgetReorderDelegate(
                            target: kind, dragging: $dragging, dockModel: dockModel
                        ))
                        .accessibilityAction(named: "Move Up") { dockModel.moveWidget(kind, by: -1) }
                        .accessibilityAction(named: "Move Down") { dockModel.moveWidget(kind, by: 1) }
                }

                ForEach(available, id: \.self) { kind in
                    row(kind, enabled: false)
                }
            } footer: {
                Text("Drag to reorder. Order runs left to right, or top to bottom on a side dock. Size applies to the bottom dock; side docks always show Small (square) widgets.").footerStyle()
            }
        }
    }

    @ViewBuilder
    private func row(_ kind: String, enabled: Bool) -> some View {
        if let info = WidgetCatalog.info(kind) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { dockModel.setWidget(kind, enabled: $0) }
            )) {
                HStack(spacing: 8) {
                    info.icon
                        .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 20)
                    Text(info.name)
                    let natural = WidgetCatalog.naturalSize(kind)
                    let sizes = WidgetSize.choices(upTo: natural)
                    if enabled, sizes.count > 1 {
                        Spacer()
                        WidgetSizePicker(
                            sizes: sizes,
                            selection: dockModel.widgetSize(for: kind, natural: natural, edge: .bottom)
                        ) { size in
                            withAnimation(.easeOut(duration: 0.15)) { dockModel.setWidgetSize(kind, size) }
                        }
                    }
                }
            }
            .toggleStyle(.switch)
        }
    }
}

/// Moves the dragged widget into the hovered row's slot as the drag
/// passes over it, so the list shows the new order before the drop.
private struct WidgetReorderDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let dockModel: DockModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = dockModel.widgetKinds.firstIndex(of: dragging),
              let to = dockModel.widgetKinds.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dockModel.moveWidgets(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragging == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
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
