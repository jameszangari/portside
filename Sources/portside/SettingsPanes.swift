import UniformTypeIdentifiers
import SwiftUI

// Settings panes for the tools that used to share General and Integrations:
// Command Center, App Switcher and Menu Bar. Each opens with a preview, then
// its controls. Each pane also holds the switches for its own modules, so
// nothing about a tool is scattered into a separate Integrations pane.

// MARK: - Command Center

struct CommandCenterSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var integrations: IntegrationSettings
    @ObservedObject private var status = CommandCenterStatus.shared
    @ObservedObject private var switcherStatus = SwitcherStatus.shared

    /// Why the shortcut may not fire: a Portside or enabled macOS shortcut on
    /// the same keys, or macOS refusing the registration. Read only; nothing
    /// here changes another shortcut.
    private var warning: String? {
        guard let chord = dockModel.commandCenterHotkey else { return nil }
        let portside: [(name: String, chord: HotkeyChord?)] = [
            ("Open Settings", dockModel.settingsHotkey),
            ("dock hiding", .dockHiding),
            ("App Switcher", switcherStatus.isEnabled ? dockModel.switcherHotkey : nil),
        ]
        return HotkeyConflicts.conflict(for: chord, system: HotkeyConflicts.systemHotkeys(), portside: portside)
            ?? (status.isEnabled ? status.hotkeyFailure : nil)
    }

    var body: some View {
        Form {
            ModuleRowsSection(integrations: integrations, ids: [CommandCenterModule.moduleID])

            Section {
                CommandCenterLauncherPreviewCard(shortcut: dockModel.commandCenterHotkey?.displayString)
                HotkeyRecorderButton(
                    title: "Shortcut",
                    chord: dockModel.commandCenterHotkey,
                    defaultChord: .commandCenterDefault,
                    onChange: { dockModel.setCommandCenterHotkey($0) }
                )
                if !status.isEnabled {
                    Text("Command Center is off. Turn it on above.").helperStyle()
                } else if let warning {
                    Label {
                        Text(warning).helperStyle()
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Launcher").settingsAnchor("Launcher")
            } footer: {
                Text("Searches apps, Portside's commands, Settings panes and quicklinks. Default ⌥Space; while it is on it is also in the menu bar menu.")
                    .footerStyle()
            }

            ModuleRowsSection(
                integrations: integrations,
                ids: [FilesModule.moduleID, ClipboardModule.moduleID, ShortcutsModule.moduleID, MenuBarModule.moduleID, LocalServersModule.moduleID],
                title: "Search sources",
                footer: "Each source is off until you turn it on. All of them need Command Center."
            )

            CommandCenterSettingsSection(dockModel: dockModel, history: CommandCenterHistory.shared, snippets: SnippetStore.shared, files: FileIndexService.shared)

            ClipboardSettingsSection(service: ClipboardService.shared)

            if let router = integrations.intelligence {
                ModuleRowsSection(integrations: integrations, ids: [IntelligenceModule.moduleID], title: "Local Intelligence")
                IntelligenceSettingsSection(router: router)
            }
        }
        .keepsIntegrationsCurrent(integrations)
    }
}

// MARK: - App Switcher

struct AppSwitcherSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var integrations: IntegrationSettings
    @ObservedObject private var status = SwitcherStatus.shared
    @ObservedObject private var commandCenterStatus = CommandCenterStatus.shared

    /// Same read-only checks for the switcher's shortcut.
    private var warning: String? {
        guard let chord = dockModel.switcherHotkey else { return nil }
        let portside: [(name: String, chord: HotkeyChord?)] = [
            ("Open Settings", dockModel.settingsHotkey),
            ("dock hiding", .dockHiding),
            ("Command Center", commandCenterStatus.isEnabled ? dockModel.commandCenterHotkey : nil),
        ]
        return SwitcherShortcut.refusal(for: chord)
            ?? HotkeyConflicts.conflict(for: chord, system: HotkeyConflicts.systemHotkeys(), portside: portside)
            ?? (status.isEnabled ? status.hotkeyFailure : nil)
    }

    var body: some View {
        Form {
            ModuleRowsSection(integrations: integrations, ids: [SwitcherModule.moduleID])

            Section {
                SwitcherPreviewCard(mode: dockModel.switcherMode, previews: dockModel.switcherPreviews)
                Picker("Shows", selection: Binding(
                    get: { dockModel.switcherMode },
                    set: { dockModel.setSwitcherMode($0) }
                )) {
                    Text("Apps").tag(SwitcherMode.apps)
                    Text("Windows").tag(SwitcherMode.windows)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(
                    get: { dockModel.switcherPreviews },
                    set: { dockModel.setSwitcherPreviews($0) }
                )) {
                    Text("Show window previews")
                    Text("Window rows show a picture of the window instead of the app icon. Needs Screen Recording, which you allow in General > Permissions. Portside takes one still picture of each visible row while the switcher is open, never video, and keeps nothing after it closes. Minimized windows, windows on other Spaces and anything macOS withholds keep the icon.").helperStyle()
                }
                Toggle(isOn: Binding(
                    get: { dockModel.switcherTitleSearch },
                    set: { dockModel.setSwitcherTitleSearch($0) }
                )) {
                    Text("Search window titles with /")
                    Text("While the switcher is open, / starts a search that stays open after you let go. Type to filter, Return switches, Esc cancels.").helperStyle()
                }
            } header: {
                Text("Switcher").settingsAnchor("Switcher")
            }

            Section {
                HotkeyRecorderButton(
                    title: "Shortcut",
                    chord: dockModel.switcherHotkey,
                    defaultChord: SwitcherShortcut.defaultChord,
                    refusal: SwitcherShortcut.refusal,
                    onChange: { dockModel.setSwitcherHotkey($0) }
                )
                if !status.isEnabled {
                    Text("App Switcher is off. Turn it on above.").helperStyle()
                } else if let warning {
                    Label {
                        Text(warning).helperStyle()
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Keyboard").settingsAnchor("Keyboard")
            } footer: {
                Text("Default ⌥Tab: tap it for the previous app (or window), or hold ⌥ and press Tab (Shift-Tab or the arrow keys to go back), then let go. With apps, ↓ chooses one of the selected app's windows. Esc cancels. Windows and their titles need Accessibility; without it the switcher shows apps. Windows on other Spaces may not be listed, and choosing a full screen window goes to its Space. ⌘Tab stays macOS's.")
                    .footerStyle()
            }
        }
        .keepsIntegrationsCurrent(integrations)
    }
}

// MARK: - Menu Bar

/// The Menu Bar pane is the layout editor and nothing else. The shortcut and
/// hide-again choices sit behind one collapsed row, so the editor is what
/// the pane opens on. Module switches are not shown: Turn On enables the
/// three modules together, and Turn Off is in the shelf control's menu.
struct MenuBarSettings: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var integrations: IntegrationSettings

    private var layoutRunning: Bool {
        integrations.modules.first { $0.id == MenuBarLayoutModule.moduleID }?.state == .running
    }

    var body: some View {
        Form {
            ModuleRowsSection(integrations: integrations, ids: [MenuBarShelfModule.moduleID])
            if layoutRunning, let layout = integrations.menuLayout {
                if layout.hidesByMembership {
                    Section { MenuBarLivePreviewCard(settings: dockModel.menuBarTriggers, dock: dockModel.look) }
                }
                MenuBarLayoutSection(service: layout)
                if let triggers = integrations.menuTriggers {
                    MenuBarTriggersSection(dockModel: dockModel, service: triggers, hidesByMembership: layout.hidesByMembership)
                    if layout.hidesByMembership { MenuBarLookSection(dockModel: dockModel) }
                    if layout.hidesByMembership { MenuBarLiveActivitiesSection(dockModel: dockModel, appList: integrations.menuFiles?.appList) }
                    MenuBarProfilesSection(service: layout)
                    MenuBarAdvancedSection(dockModel: dockModel, service: triggers, files: integrations.menuFiles)
                }
            } else {
                MenuBarLayoutSetup(integrations: integrations)
            }
        }
        .keepsIntegrationsCurrent(integrations)
    }
}

/// Shown until the layout can run: one button instead of three module switches.
private struct MenuBarLayoutSetup: View {
    @ObservedObject var integrations: IntegrationSettings

    private static let ids = [MenuBarShelfModule.moduleID, MenuBarReorderModule.moduleID, MenuBarLayoutModule.moduleID]

    private var accessibilityAllowed: Bool {
        integrations.permissions.first { $0.scope == .accessibility }?.state == .granted
    }

    private var restricted: Bool {
        integrations.modules.contains { Self.ids.contains($0.id) && $0.isRestricted }
    }

    private var allOn: Bool {
        Self.ids.allSatisfy { id in integrations.modules.first { $0.id == id }?.isEnabled == true }
    }

    var body: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "menubar.rectangle").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Arrange your menu bar").font(.headline)
                Text(restricted
                     ? "Restricted mode keeps this off."
                     : "Hide the items you rarely need and drag the rest into the order you want. Portside adds a small control to the menu bar and moves items with real Command-drags.")
                    .helperStyle()
                    .multilineTextAlignment(.center)
                if !restricted {
                    if !allOn {
                        Button("Turn On") { for id in Self.ids { integrations.setEnabled(true, for: id) } }
                            .buttonStyle(.borderedProminent)
                    }
                    if !accessibilityAllowed {
                        Text("Moving items needs Accessibility.").helperStyle()
                        Button("Open Accessibility Settings") { PermissionScope.accessibility.openPrivacyPane() }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

/// Reveal and hide triggers and automatic rehide for the menu bar shelf.
struct MenuBarTriggersSection: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var service: MenuBarTriggerService
    let hidesByMembership: Bool

    private var settings: MenuBarTriggerSettings { dockModel.menuBarTriggers }
    private let pointerAvailable = true

    private func binding<T>(_ keyPath: WritableKeyPath<MenuBarTriggerSettings, T>) -> Binding<T> {
        Binding(
            get: { dockModel.menuBarTriggers[keyPath: keyPath] },
            set: {
                var next = dockModel.menuBarTriggers
                next[keyPath: keyPath] = $0
                dockModel.setMenuBarTriggers(next)
            }
        )
    }

    /// Read-only conflict checks, like the other shortcuts.
    private func conflict(for chord: HotkeyChord?, sibling: (name: String, chord: HotkeyChord?)) -> String? {
        guard let chord else { return nil }
        let portside: [(name: String, chord: HotkeyChord?)] = [
            ("Open Settings", dockModel.settingsHotkey),
            ("dock hiding", .dockHiding),
            ("Command Center", dockModel.commandCenterHotkey),
            ("App Switcher", dockModel.switcherHotkey),
            sibling,
        ]
        return HotkeyConflicts.conflict(for: chord, system: HotkeyConflicts.systemHotkeys(), portside: portside)
    }

    private var warning: String? {
        conflict(for: settings.hotkey, sibling: ("Show Always Hidden", settings.alwaysHiddenHotkey)) ?? service.hotkeyFailure
    }

    private var alwaysHiddenWarning: String? {
        conflict(for: settings.alwaysHiddenHotkey, sibling: ("menu bar show and hide", settings.hotkey))
    }

    private func gesture(_ kind: MenuBarGestureGlyph.Kind, _ path: WritableKeyPath<MenuBarTriggerSettings, Bool>, title: String, detail: String) -> some View {
        Toggle(isOn: binding(path)) {
            HStack(spacing: 10) {
                MenuBarGestureGlyph(kind: kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).helperStyle()
                }
            }
        }
    }

    var body: some View {
        if hidesByMembership {
            Section {
                SettingsChoiceCards(selection: binding(\.presentation), choices: MenuBarPresentation.allCases.map { ($0, $0.title) }, columns: 3) {
                    MenuBarPresentationPicture(presentation: $0)
                }
                if settings.presentation != .menuBar {
                    SettingsChoiceCards(selection: binding(\.barLocation), choices: MenuBarBarLocation.allCases.map { ($0, $0.title) }, columns: 5) {
                        MenuBarLocationPicture(location: $0)
                    }
                }
            } header: {
                Text("Show hidden items").settingsAnchor("Show hidden items")
            } footer: {
                Text("The Portside Bar is a panel under the menu bar. Hidden items stay out of the menu bar and open from the panel.").footerStyle()
            }
        }
        Section {
            gesture(.click, \.emptyClick, title: "Click anywhere on the menu bar", detail: "Any empty spot, including the notch. Double-click also shows Always Hidden.")
            gesture(.scroll, \.scroll, title: "Scroll on the menu bar", detail: "Scroll up shows, scroll down hides.")
            gesture(.hover, \.hover, title: "Hover over the menu bar", detail: "Shows your items after the pointer rests there.")
            HotkeyRecorderButton(
                title: "Shortcut",
                chord: settings.hotkey,
                defaultChord: nil,
                onChange: { chord in
                    var next = dockModel.menuBarTriggers
                    next.hotkey = chord
                    dockModel.setMenuBarTriggers(next)
                }
            )
            if let warning { Text(warning).helperStyle().foregroundStyle(.orange) }
            if service.isRunning, settings.hotkey != nil, service.secureInputOn {
                Text("Secure input is on right now (often a password field). The shortcut may not fire until it ends.").helperStyle()
            }
            HotkeyRecorderButton(
                title: "Show Always Hidden",
                chord: settings.alwaysHiddenHotkey,
                defaultChord: nil,
                onChange: { chord in
                    var next = dockModel.menuBarTriggers
                    next.alwaysHiddenHotkey = chord
                    dockModel.setMenuBarTriggers(next)
                }
            )
            if let alwaysHiddenWarning { Text(alwaysHiddenWarning).helperStyle().foregroundStyle(.orange) }
            if !service.isRunning { Text("Menu Bar Shelf is off. Turn it on from the Layout setup.").helperStyle() }
        } header: {
            Text("Open with").settingsAnchor("Open with")
        } footer: {
            Text("Clicks on an app's menu or a status icon still go to them, and nothing acts over an open menu. Scroll and hover also skip the notch.").footerStyle()
        }
        Section {
            SettingsChoiceCards(selection: binding(\.strategy), choices: MenuBarRehideStrategy.allCases.map { ($0, $0.title) }, columns: 3) {
                MenuBarRehidePicture(strategy: $0)
            }
            Picker("After", selection: binding(\.rehideSeconds)) {
                ForEach(MenuBarTriggerSettings.rehideChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                }
            }
            MenuBarRehideFlow(settings: settings)
            if let status = service.status { Text(status).helperStyle() }
        } header: {
            Text("Hide again").settingsAnchor("Hide again")
        } footer: {
            Text("An open menu, the pointer on the menu bar or this settings page waits it out.").footerStyle()
        }
    }
}

/// Whether Live Activities from a paired iPhone show.
private struct MenuBarLiveActivitiesSection: View {
    @ObservedObject var dockModel: DockModel
    let appList: MenuBarFileGrant?
    @StateObject private var model = MenuBarLiveActivities()

    private var keepsShowing: Bool { dockModel.menuBarTriggers.hidingMethod == .native }

    private func setKeepsShowing(_ on: Bool) {
        if on, let appList, !appList.isGranted { appList.request() }
        var next = dockModel.menuBarTriggers
        next.hidingMethod = on ? .native : .standard
        dockModel.setMenuBarTriggers(next)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, value: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: set)) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 26)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).helperStyle()
                }
            }
        }
    }

    var body: some View {
        Section {
            if let iPhoneEnabled = model.iPhoneEnabled {
                row("iphone", "Live Activities from iPhone", "Sports scores, deliveries and other activity from your paired iPhone.", value: iPhoneEnabled) { model.setIPhone($0) }
            }
            if model.iPhoneEnabled == nil {
                Text("This version of macOS doesn't expose these settings.").helperStyle()
            }
            row(
                "eye", "Keep Live Activities showing",
                keepsShowing
                    ? "They stay visible while your items are hidden. This uses Native hiding, which can't hide Clock, Control Center or Siri, and some apps may stay in the menu bar."
                    : "They disappear while your items are hidden. Turn on to keep them, using Native hiding.",
                value: keepsShowing
            ) { setKeepsShowing($0) }
        } header: {
            Text("Live Activities").settingsAnchor("Live Activities")
        }
        .onAppear { model.refresh() }
    }
}

/// Settings most people never need to change.
private struct MenuBarAdvancedSection: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var service: MenuBarTriggerService
    let files: (layout: MenuBarFileGrant, appList: MenuBarFileGrant)?

    private var settings: MenuBarTriggerSettings { dockModel.menuBarTriggers }

    private func binding<T>(_ keyPath: WritableKeyPath<MenuBarTriggerSettings, T>) -> Binding<T> {
        Binding(
            get: { dockModel.menuBarTriggers[keyPath: keyPath] },
            set: {
                var next = dockModel.menuBarTriggers
                next[keyPath: keyPath] = $0
                dockModel.setMenuBarTriggers(next)
            }
        )
    }

    var body: some View {
        Section {
            Picker("New apps go to", selection: binding(\.newItemsSection)) {
                ForEach(MenuBarSection.allCases) { Label($0.title, systemImage: $0.symbolName).tag($0) }
            }
            Picker("Item arrangement", selection: binding(\.arrangement)) {
                ForEach(MenuBarArrangement.allCases) { Text($0.title).tag($0) }
            }
            Picker("Hiding method", selection: binding(\.hidingMethod)) {
                ForEach(MenuBarHidingMethod.allCases) { Text($0.title).tag($0) }
            }
            if let files {
                MenuBarGrantRow(title: "Restore order without moving the pointer", grant: files.layout)
                if settings.hidingMethod == .native { MenuBarGrantRow(title: "Native hiding needs the app list", grant: files.appList) }
            }
        } header: {
            Text("Advanced").settingsAnchor("Advanced")
        } footer: {
            Text("Automatic puts your saved order back before each reveal; Manual leaves it alone. Standard hides any app and Apple's items while Portside runs. Native uses macOS's own per-app switch.").footerStyle()
        }
    }
}

private struct MenuBarIconPreview: View {
    let look: MenuBarLook

    var body: some View {
        if let image = look.controlArtwork(hidden: true, description: "Menu bar icon") {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(.secondary)
        } else {
            Text("None").foregroundStyle(.secondary)
        }
    }
}

/// Pick the menu bar icon from every SF Symbol, or use your own image.
private struct MenuBarIconPicker: View {
    @ObservedObject var dockModel: DockModel
    @State private var query = ""
    @State private var results = SymbolCatalog.suggested
    @State private var failed = false

    private var look: MenuBarLook { dockModel.menuBarTriggers.look }

    private func change(_ edit: (inout MenuBarLook) -> Void) {
        var next = dockModel.menuBarTriggers
        edit(&next.look)
        dockModel.setMenuBarTriggers(next)
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .svg, .pdf]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let stored = MenuBarControlImage.store(from: url, replacing: look.customImage) else {
            failed = true
            return
        }
        failed = false
        change {
            $0.controlIcon = .image
            $0.customImage = stored.name
            $0.customImageIsTemplate = stored.isTemplate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsTextField("Search symbols", text: $query, kind: .search)
            ScrollView {
                if results.isEmpty {
                    Text("No symbols match").foregroundStyle(.secondary).padding(.top, 24)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                    ForEach(results, id: \.self) { name in
                        let selected = look.controlIcon == .symbol && look.customSymbol == name
                        Image(systemName: name)
                            .font(.system(size: 16))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.0001))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                change {
                                    $0.controlIcon = .symbol
                                    $0.customSymbol = name
                                }
                            }
                            .help(name)
                            .accessibilityLabel(name)
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            .frame(height: 260)
            if look.controlIcon == .image {
                Toggle("Match the menu bar's color", isOn: Binding(
                    get: { look.customImageIsTemplate },
                    set: { value in change { $0.customImageIsTemplate = value } }
                ))
            }
            if failed {
                Text("That file could not be used as an image.").helperStyle().foregroundStyle(.orange)
            }
            HStack {
                Button("Upload Image…", action: upload)
                Spacer()
                Button("Eye") { change { $0.controlIcon = .eye } }
                Button("No Icon") { change { $0.controlIcon = .off } }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onChange(of: query) { _, text in results = SymbolCatalog.shared.search(text) }
    }
}

/// The Portside Bar's and the real menu bar's look.
private struct MenuBarLookSection: View {
    @ObservedObject var dockModel: DockModel

    @AppStorage(PortsideMenuIcon.defaultsKey) private var showsAppIcon = true
    @State private var showIconPicker = false

    private var look: MenuBarLook { dockModel.menuBarTriggers.look }

    private func binding<Value>(_ path: WritableKeyPath<MenuBarLook, Value>) -> Binding<Value> {
        Binding(
            get: { dockModel.menuBarTriggers.look[keyPath: path] },
            set: { set(path, $0) }
        )
    }

    private func set<Value>(_ path: WritableKeyPath<MenuBarLook, Value>, _ value: Value, persist: Bool = true) {
        var next = dockModel.menuBarTriggers
        next.look[keyPath: path] = value
        dockModel.setMenuBarTriggers(next, persist: persist)
    }

    private func update(_ path: WritableKeyPath<MenuBarLook, DockBackground>) -> (Bool, (inout DockBackground) -> Void) -> Void {
        { persist, change in
            var next = dockModel.menuBarTriggers
            change(&next.look[keyPath: path])
            dockModel.setMenuBarTriggers(next, persist: persist)
        }
    }

    private func cornerSlider(_ path: WritableKeyPath<MenuBarLook, Double>) -> SettingsSlider {
        SettingsSlider(title: "Corner radius", value: look[keyPath: path], range: MenuBarLook.cornerRange, snap: 1, format: { "\(Int($0)) pt" }, set: { set(path, $0, persist: $1) })
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                MenuBarIconPreview(look: look)
                    .frame(width: 34, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Text("Menu bar icon")
                Spacer()
                Button("Change…") { showIconPicker = true }
                    .popover(isPresented: $showIconPicker, arrowEdge: .trailing) { MenuBarIconPicker(dockModel: dockModel) }
            }
            Toggle(isOn: $showsAppIcon) {
                Text("Show the Portside menu")
                Text("The Portside logo in the menu bar. Without it, open Portside from Spotlight or Finder to reach Settings.").helperStyle()
            }
            if look.controlIcon == .off, !dockModel.menuBarTriggers.emptyClick, dockModel.menuBarTriggers.hotkey == nil {
                Text("Without the icon, turn on Click anywhere or set a shortcut, or nothing will open your items.").helperStyle().foregroundStyle(.orange)
            }
        } header: {
            Text("Icons").settingsAnchor("Icons")
        }
        Section {
            SettingsChoiceCards(selection: binding(\.barStyle), choices: MenuBarBarStyle.allCases.map { ($0, $0.title) }, columns: 3) {
                MenuBarBarStylePicture(style: $0, look: look, dock: dockModel.look)
            }
            if look.barStyle == .system { cornerSlider(\.barCornerRadius) }
            SettingsSlider(title: "Icon size", value: look.barIconSize, range: MenuBarLook.iconSizeRange, snap: 1, format: { "\(Int($0)) pt" }, set: { set(\.barIconSize, $0, persist: $1) })
        } header: {
            Text("Portside Bar style").settingsAnchor("Portside Bar style")
        }
        if look.barStyle == .custom {
            DockBackgroundEditor(background: look.barBackground, update: update(\.barBackground), surface: "bar", extra: { cornerSlider(\.barCornerRadius) }, header: { Text("Portside Bar background").settingsAnchor("Portside Bar background") })
        }
        Section {
            SettingsChoiceCards(selection: binding(\.shape), choices: MenuBarShape.allCases.map { ($0, $0.title) }, columns: 4) {
                MenuBarShapePicture(shape: $0, look: look)
            }
        } header: {
            Text("Menu bar shape").settingsAnchor("Menu bar shape")
        } footer: {
            Text("Drawn behind your menu bar. macOS still picks the color of its text and icons.").footerStyle()
        }
        if look.shape != .none {
            DockBackgroundEditor(
                background: look.background,
                update: update(\.background),
                surface: "menu bar",
                extra: {
                    cornerSlider(\.cornerRadius)
                    Toggle("Shadow", isOn: binding(\.shadow))
                },
                header: { Text("Menu bar background").settingsAnchor("Menu bar background") }
            )
        }
    }
}

private struct MenuBarGrantRow: View {
    let title: String
    @ObservedObject var grant: MenuBarFileGrant

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if grant.isGranted {
                Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Button("Grant Access") { grant.request() }
            }
        }
    }
}

/// Saved arrangements and named groups.
struct MenuBarProfilesSection: View {
    @ObservedObject var service: MenuBarLayoutService
    @State private var newProfile = ""
    @State private var newGroup = ""

    private func saveProfile() {
        guard !newProfile.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        service.saveNewProfile(named: newProfile)
        newProfile = ""
    }

    private func addGroup() {
        guard !newGroup.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        service.addGroup(named: newGroup)
        newGroup = ""
    }

    var body: some View {
        Section {
            ForEach(service.profiles) { profile in
                HStack {
                    Button(profile.name) { service.applyProfile(profile.id) }
                        .buttonStyle(.borderless)
                        .fontWeight(profile.id == service.activeProfileID ? .semibold : .regular)
                    Spacer()
                    Toggle("Use with these displays", isOn: Binding(
                        get: { profile.displayKey == MenuBarDisplaySet.current },
                        set: { service.setProfileMatchesDisplays(profile.id, matches: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    Button { service.deleteProfile(profile.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(profile.name)")
                }
                HotkeyRecorderButton(title: "Shortcut", chord: profile.hotkey, defaultChord: nil, onChange: { service.setProfileHotkey(profile.id, chord: $0) })
            }
            HStack(spacing: 10) {
                Text("New profile")
                SettingsTextField("New profile name", text: $newProfile, onSubmit: saveProfile)
                Button("Save", action: saveProfile)
                    .disabled(newProfile.trimmingCharacters(in: .whitespaces).isEmpty)
                if service.activeProfileID != nil { Button("Update Current") { service.updateActiveProfile() } }
            }
        } header: {
            Text("Profiles").settingsAnchor("Profiles")
        } footer: {
            Text("A profile saves sections, order and groups. Switch from the menu bar icon's right-click menu or a shortcut.").footerStyle()
        }
        Section {
            ForEach(service.groups) { group in
                HStack {
                    SettingsTextField("Group name", text: Binding(get: { group.name }, set: { service.renameGroup(group.id, to: $0) }))
                    Text("\(group.bundles.count) apps").helperStyle()
                    Toggle("Menu bar icon", isOn: Binding(get: { group.showsIcon }, set: { service.setGroupIcon(group.id, shown: $0) }))
                        .toggleStyle(.checkbox)
                    Button { service.removeGroup(group.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(group.name)")
                }
            }
            HStack(spacing: 10) {
                Text("New group")
                SettingsTextField("New group name", text: $newGroup, onSubmit: addGroup)
                Button("Add", action: addGroup)
                    .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Groups").settingsAnchor("Groups")
        } footer: {
            Text("Right-click an icon in Visible, Hidden or Always Hidden to add its app to a group. Groups appear as rows in the Portside Bar.").footerStyle()
        }
    }
}
