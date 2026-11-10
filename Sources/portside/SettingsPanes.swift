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
                Text("Launcher")
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
                Text("Switcher")
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
                Text("Keyboard")
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
    @AppStorage(PortsideMenuIcon.defaultsKey) private var showsAppIcon = true
    @State private var showOptions = false
    @State private var showLook = false
    @State private var showArrange = false

    private var layoutRunning: Bool {
        integrations.modules.first { $0.id == MenuBarLayoutModule.moduleID }?.state == .running
    }

    private func triggerBinding<Value>(_ path: WritableKeyPath<MenuBarTriggerSettings, Value>) -> Binding<Value> {
        Binding(
            get: { dockModel.menuBarTriggers[keyPath: path] },
            set: { value in
                var next = dockModel.menuBarTriggers
                next[keyPath: path] = value
                dockModel.setMenuBarTriggers(next)
            }
        )
    }

    var body: some View {
        Form {
            if layoutRunning, let layout = integrations.menuLayout {
                if let triggers = integrations.menuTriggers {
                    if layout.hidesByMembership {
                        Section {
                            Picker("Show hidden items", selection: triggerBinding(\.presentation)) {
                                ForEach(MenuBarPresentation.allCases) { Text($0.title).tag($0) }
                            }
                            if dockModel.menuBarTriggers.presentation != .menuBar {
                                Picker("Portside Bar position", selection: triggerBinding(\.barLocation)) {
                                    ForEach(MenuBarBarLocation.allCases) { Text($0.title).tag($0) }
                                }
                            }
                            Toggle(isOn: triggerBinding(\.emptyClick)) {
                                Text("Click anywhere on the menu bar to open")
                                Text("Any empty spot, including the notch. Clicks on an app's menu or a status icon still go to them.").helperStyle()
                            }
                            Picker("Menu bar icon", selection: triggerBinding(\.look.controlIcon)) {
                                ForEach(MenuBarControlIcon.allCases) { Text($0.title).tag($0) }
                            }
                            Toggle(isOn: $showsAppIcon) {
                                Text("Show the Portside menu")
                                Text("The Portside logo in the menu bar. Without it, open Portside from Spotlight or Finder to reach Settings.").helperStyle()
                            }
                            if dockModel.menuBarTriggers.look.controlIcon == .off, !dockModel.menuBarTriggers.emptyClick, dockModel.menuBarTriggers.hotkey == nil {
                                Text("Without the icon, turn on Click anywhere or set a shortcut, or nothing will open your items.").helperStyle().foregroundStyle(.orange)
                            }
                        } footer: {
                            Text("The Portside Bar is a separate panel under the menu bar. Your hidden items stay out of the menu bar and open from the panel.").helperStyle()
                        }
                    }
                    if layout.hidesByMembership {
                        Section {
                            Button {
                                showLook.toggle()
                            } label: {
                                HStack {
                                    Text("Appearance")
                                    Spacer()
                                    Image(systemName: showLook ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if showLook { MenuBarLookSection(dockModel: dockModel) }
                    }
                    Section {
                        Button {
                            showOptions.toggle()
                        } label: {
                            HStack {
                                Text("Shortcut and hide-again options")
                                Spacer()
                                Image(systemName: showOptions ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if showOptions { MenuBarTriggersSection(dockModel: dockModel, service: triggers, files: integrations.menuFiles) }
                    Section {
                        Button {
                            showArrange.toggle()
                        } label: {
                            HStack {
                                Text("Profiles and groups")
                                Spacer()
                                Image(systemName: showArrange ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if showArrange { MenuBarProfilesSection(service: layout) }
                }
                MenuBarLayoutSection(service: layout)
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
    let files: (layout: MenuBarFileGrant, appList: MenuBarFileGrant)?

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

    var body: some View {
        Section {
            MenuBarTriggersPreviewCard(settings: settings, pointerAvailable: pointerAvailable)
            Label {
                Text("In the menu bar, an open eye means your items are showing and a crossed eye means they are hidden. A thin bar marks where the hidden items sit. Click the eye to flip it. Right-click it for options, including Turn Off.").helperStyle()
            } icon: {
                Image(systemName: "eye").foregroundStyle(.secondary)
            }
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
            if !service.isRunning { Text("Menu Bar Shelf is off. Turn it on from the Layout setup.").helperStyle() }
        } header: {
            Text("Open")
        }
        Section {
            Toggle(isOn: binding(\.scroll)) {
                Text("Scroll on the empty menu bar")
                Text("Scroll up shows, scroll down hides.").helperStyle()
            }
            Toggle(isOn: binding(\.hover)) {
                Text("Hover over the empty menu bar")
                Text("Shows your items after the pointer rests there.").helperStyle()
            }
        } header: {
            Text("Also open with")
        } footer: {
            Text("These need Accessibility and never act over an app's menu, a status item or an open menu. Scroll and hover also skip the notch.").footerStyle()
        }
        Section {
            Picker("Hide again", selection: binding(\.strategy)) {
                ForEach(MenuBarRehideStrategy.allCases) { Text($0.title).tag($0) }
            }
            Picker("After", selection: binding(\.rehideSeconds)) {
                ForEach(MenuBarTriggerSettings.rehideChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                }
            }
            if let status = service.status { Text(status).helperStyle() }
        } header: {
            Text("Hide again")
        } footer: {
            Text("Smart also hides shortly after you click elsewhere or switch apps. An open menu, the pointer on the menu bar or an open layout editor waits it out.").footerStyle()
        }
        Section {
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
            Picker("New apps go to", selection: binding(\.newItemsSection)) {
                ForEach(MenuBarSection.allCases) { Text($0.title).tag($0) }
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
            Text("Layout")
        } footer: {
            Text("Automatic puts your saved order back before each reveal; Manual leaves it alone. Standard hides any app and Apple's items while Portside runs. Native uses macOS's per-app switch, which keeps Focus and Now Playing but restarts Control Center each time.").footerStyle()
        }
    }
}

/// The Portside Bar's and the real menu bar's look.
private struct MenuBarLookSection: View {
    @ObservedObject var dockModel: DockModel

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
            Picker("Style", selection: binding(\.barStyle)) {
                ForEach(MenuBarBarStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if look.barStyle == .system { cornerSlider(\.barCornerRadius) }
            SettingsSlider(title: "Icon size", value: look.barIconSize, range: MenuBarLook.iconSizeRange, snap: 1, format: { "\(Int($0)) pt" }, set: { set(\.barIconSize, $0, persist: $1) })
        } header: {
            Text("Portside Bar")
        }
        if look.barStyle == .custom {
            DockBackgroundEditor(background: look.barBackground, update: update(\.barBackground), surface: "bar", extra: { cornerSlider(\.barCornerRadius) }, header: { Text("Portside Bar background") })
        }
        Section {
            Picker("Shape", selection: binding(\.shape)) {
                ForEach(MenuBarShape.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Menu bar")
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
                header: { Text("Menu bar background") }
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
            HStack {
                TextField("New profile", text: $newProfile)
                Button("Save") {
                    service.saveNewProfile(named: newProfile)
                    newProfile = ""
                }
                .disabled(newProfile.trimmingCharacters(in: .whitespaces).isEmpty)
                if service.activeProfileID != nil { Button("Update Current") { service.updateActiveProfile() } }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("A profile saves sections, order and groups. Switch from the eye's right-click menu or a shortcut.").footerStyle()
        }
        Section {
            ForEach(service.groups) { group in
                HStack {
                    TextField("Name", text: Binding(get: { group.name }, set: { service.renameGroup(group.id, to: $0) }))
                    Text("\(group.bundles.count) apps").helperStyle()
                    Toggle("Menu bar icon", isOn: Binding(get: { group.showsIcon }, set: { service.setGroupIcon(group.id, shown: $0) }))
                        .toggleStyle(.checkbox)
                    Button { service.removeGroup(group.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(group.name)")
                }
            }
            HStack {
                TextField("New group", text: $newGroup)
                Button("Add") {
                    service.addGroup(named: newGroup)
                    newGroup = ""
                }
                .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Groups")
        } footer: {
            Text("Right-click an icon below to add its app to a group. Groups appear as rows in the Portside Bar.").footerStyle()
        }
    }
}
