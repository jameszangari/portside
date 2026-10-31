import SwiftUI

/// Owns the Settings window. Unlike the dock panel this is a normal window.
/// While it is open Portside is a regular app (in the native Dock, Cmd+Tab
/// and its own dock); closing it hands focus back to the app that was
/// frontmost before and returns Portside to an accessory app.
///
/// Every control writes straight to `DockModel`, which persists and
/// publishes, so the dock updates live (like a controlled input in React).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// The activation policy changed (regular while open, accessory after).
    var onActivationPolicyChanged: (() -> Void)?

    private let dockModel: DockModel
    private let layout: DockLayout
    private let nativeDock: NativeDockController
    /// Read from the system each time the window opens.
    private let launchAtLogin = LaunchAtLogin()
    private var window: NSWindow?
    /// The other app that was frontmost most recently while Settings was
    /// open. Focus goes back to it on close; NSApp.deactivate() alone does
    /// not reliably do that.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    /// Fits that land before this time (the first layout passes after
    /// opening) keep the window centered instead of pinning its top edge.
    private var centerUntil = Date.distantPast

    init(dockModel: DockModel, layout: DockLayout, nativeDock: NativeDockController) {
        self.dockModel = dockModel
        self.layout = layout
        self.nativeDock = nativeDock
    }

    var isOpen: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            centerUntil = Date().addingTimeInterval(0.5)
            center(window)
        }
        launchAtLogin.refresh()
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
            launchAtLogin: launchAtLogin,
            onContentHeight: { [weak self] in self?.fitContent(height: $0) }
        ))
        // The window's height follows the selected tab (fitContent), so the
        // hosting controller must not size the window itself.
        hosting.sizingOptions = []
        let window = SettingsNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.windowWidth, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Portside Settings"
        // The header sits right under the title bar; one divider (under the
        // tabs) is enough.
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Older builds saved the window position; it now always opens centered.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame PortsideSettings")
        return window
    }

    /// Dead center of the visible area (menu bar excluded) of the screen
    /// with the cursor, or the primary screen. NSWindow.center() sits
    /// higher than center on purpose, so it is not used.
    private func center(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.screens.first else { return }
        window.setFrame(centered(window.frame.size, on: screen), display: false)
    }

    private func centered(_ size: NSSize, on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        return NSRect(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
    }

    /// Resizes the window to the selected tab's content, keeping its top
    /// edge in place (like native Settings windows). Animated when visible.
    private func fitContent(height: CGFloat) {
        guard let window else { return }
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maxContent = window.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: 100, height: available)).height
        let size = NSSize(width: SettingsLayout.windowWidth, height: min(height.rounded(.up), maxContent))
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(frame.height - old.height) > 0.5 || abs(frame.width - old.width) > 0.5 else { return }
        if Date() < centerUntil, let screen = window.screen ?? NSScreen.screens.first {
            frame = centered(frame.size, on: screen)
        } else {
            frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        }
        let animate = window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animate)
    }

    func windowWillClose(_ notification: Notification) {
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

/// Shared sizes so every tab lines up.
enum SettingsLayout {
    static let windowWidth: CGFloat = 520
    /// Label column for slider rows.
    static let labelWidth: CGFloat = 136
    /// Value column for slider rows ("150 ms", "Instant").
    static let valueWidth: CGFloat = 56
    /// Fallback content height per tab before macOS 15 (no scroll geometry).
    static let fallbackFormHeight: CGFloat = 470
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
    case general, appearance, widgets, groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .widgets: "Widgets"
        case .groups: "Groups"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .widgets: "square.grid.2x2"
        case .groups: "folder"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    let nativeDock: NativeDockController
    let launchAtLogin: LaunchAtLogin
    /// Total content height the window should have for the selected tab.
    let onContentHeight: (CGFloat) -> Void

    @State private var tab: SettingsTab = .general
    @State private var chromeHeight: CGFloat = 0
    @State private var formHeight: CGFloat = SettingsLayout.fallbackFormHeight

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SettingsHeader()
                SettingsTabBar(selection: $tab)
                Divider()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                chromeHeight = $0
                report()
            }

            Group {
                switch tab {
                case .general: GeneralSettings(dockModel: dockModel, layout: layout, nativeDock: nativeDock, launchAtLogin: launchAtLogin)
                case .appearance: AppearanceSettings(dockModel: dockModel)
                case .widgets: WidgetSettings(dockModel: dockModel)
                case .groups: GroupSettings(dockModel: dockModel)
                }
            }
            .formStyle(.grouped)
            .modifier(FormHeightReader { height in
                formHeight = height
                report()
            })
            .frame(maxHeight: .infinity)
        }
        .frame(width: SettingsLayout.windowWidth)
    }

    private func report() {
        guard chromeHeight > 0 else { return }
        onContentHeight(chromeHeight + formHeight)
    }
}

/// Reads the grouped Form's content height so the window can fit it.
private struct FormHeightReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                if height > 0 { onChange(height) }
            }
        } else {
            content
        }
    }
}

// MARK: - Header and tabs

/// App icon, name, version, and the update check. No container: it sits
/// on the window background above the tabs.
private struct SettingsHeader: View {
    @State private var status: String?
    @State private var clearStatus: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIcon.image(points: 48))
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name)
                    .font(.title2.weight(.bold))
                Text(AppInfo.versionLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 12)
            Button("Check for Updates", action: checkForUpdates)
        }
        // Tall enough for the status line, so it never resizes the window.
        .frame(height: 60)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
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

/// Toolbar-style tabs: an SF Symbol above a label, like native Settings.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 72, height: 48)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var layout: DockLayout
    let nativeDock: NativeDockController
    @ObservedObject var launchAtLogin: LaunchAtLogin

    @State private var importRequest: ImportRequest?
    @State private var canUndoImport = DockModel.hasBeforeImport
    @State private var importStatus: String?

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

                Toggle("Animate opening applications", isOn: Binding(
                    get: { dockModel.animateOpeningApplications },
                    set: { dockModel.setAnimateOpeningApplications($0) }
                ))
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
            if snapshot.others > 0 { parts.append("skipped \(snapshot.others) folder or file \(snapshot.others == 1 ? "tile" : "tiles")") }
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
private struct SettingsSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// Values round to a multiple of this (0.01 s = 10 ms, 1 pt).
    let snap: Double
    let format: (Double) -> String
    /// (new value, persist)
    let set: (Double, Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: { set(snapped($0), !isDragging) }),
                in: range
            ) {
                Text(title)
            } onEditingChanged: { editing in
                isDragging = editing
                if !editing { set(value, true) }
            }
            .labelsHidden()
            .accessibilityValue(format(value))
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: SettingsLayout.valueWidth, alignment: .trailing)
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

    /// Brand navy (design/brand tokens) at low strength, the starting
    /// color when the tint is turned on.
    private static let defaultTint = RGBAColor(red: 0x10 / 255, green: 0x28 / 255, blue: 0x3F / 255, alpha: 0.35)

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
                Picker("Background", selection: Binding(
                    get: { dockModel.backgroundStyle.effective },
                    set: { dockModel.setBackgroundStyle($0) }
                )) {
                    ForEach(styles) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                SettingsSlider(
                    title: dockModel.backgroundStyle.effective == .solid ? "Opacity" : "Frost",
                    value: dockModel.backgroundFrost,
                    range: 0...1,
                    snap: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    set: { dockModel.setBackgroundFrost($0, persist: $1) }
                )

                HStack(spacing: 12) {
                    Toggle("Tint", isOn: Binding(
                        get: { dockModel.backgroundTint != nil },
                        set: { dockModel.setBackgroundTint($0 ? Self.defaultTint : nil) }
                    ))
                    if let tint = dockModel.backgroundTint {
                        Spacer()
                        ColorPicker("Tint color", selection: Binding(
                            get: { tint.color },
                            set: { dockModel.setBackgroundTint(RGBAColor($0)) }
                        ), supportsOpacity: true)
                        .labelsHidden()
                    }
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
                    Button("Reset to Defaults") { dockModel.resetAppearanceToDefaults() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            } footer: {
                Text(backgroundHelp).footerStyle()
            }
        }
    }

    private var backgroundHelp: String {
        switch dockModel.backgroundStyle.effective {
        case .glass: "Liquid Glass like the macOS Dock. Frost 0% is clear glass; higher values blur and soften what is behind it."
        case .frosted: "The translucent material from earlier macOS versions. Frost sets how strong it is."
        case .solid: "A dark fill. Opacity sets how much shows through."
        }
    }
}

// MARK: - Widgets

private struct WidgetSettings: View {
    @ObservedObject var dockModel: DockModel
    /// Widget being dragged in the list, nil when no drag is in progress.
    @State private var dragging: String?

    private var available: [String] {
        WidgetCatalog.defaultKinds.filter { !dockModel.widgetKinds.contains($0) }
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
                Text("Drag to reorder. Order runs left to right, or top to bottom on a side dock.").footerStyle()
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
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            GroupMiniIcon(group: group)

            VStack(alignment: .leading, spacing: 0) {
                nameField
                Text(group.apps.count == 1 ? "1 app" : "\(group.apps.count) apps")
                    .helperStyle()
            }

            Spacer(minLength: 8)

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
