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

/// One job per tab: arrange the items, choose how the shelf opens and closes,
/// or reach the module switches and per-item order. Layout comes first and
/// the switches last, so arranging the bar is what the pane opens on.
struct MenuBarSettings: View {
    enum Tab: String, CaseIterable, Identifiable {
        case layout = "Layout", showHide = "Show & Hide", advanced = "Advanced"
        var id: String { rawValue }
    }

    @ObservedObject var dockModel: DockModel
    @ObservedObject var integrations: IntegrationSettings
    @State private var tab = Tab.layout

    private var layoutRunning: Bool {
        integrations.modules.first { $0.id == MenuBarLayoutModule.moduleID }?.state == .running
    }

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch tab {
            case .layout:
                if layoutRunning, let layout = integrations.menuLayout {
                    MenuBarLayoutSection(service: layout)
                } else {
                    MenuBarLayoutSetup(integrations: integrations)
                }
            case .showHide:
                if let triggers = integrations.menuTriggers {
                    MenuBarTriggersSection(dockModel: dockModel, service: triggers)
                }
            case .advanced:
                ModuleRowsSection(
                    integrations: integrations,
                    ids: [MenuBarShelfModule.moduleID, MenuBarLayoutModule.moduleID, MenuBarReorderModule.moduleID],
                    title: "Modules",
                    footer: "Layout and Reorder move other apps' items with real Command-drags and need Accessibility."
                )
                if let reorder = integrations.menuReorder { MenuBarReorderSection(service: reorder) }
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

    private var settings: MenuBarTriggerSettings { dockModel.menuBarTriggers }
    private let pointerAvailable = MenuBarTrigger.hover.isAvailableNow

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
    private var warning: String? {
        guard let chord = settings.hotkey else { return nil }
        let portside: [(name: String, chord: HotkeyChord?)] = [
            ("Open Settings", dockModel.settingsHotkey),
            ("dock hiding", .dockHiding),
            ("Command Center", dockModel.commandCenterHotkey),
            ("App Switcher", dockModel.switcherHotkey),
        ]
        return HotkeyConflicts.conflict(for: chord, system: HotkeyConflicts.systemHotkeys(), portside: portside)
            ?? service.hotkeyFailure
    }

    var body: some View {
        Section {
            MenuBarTriggersPreviewCard(settings: settings, pointerAvailable: pointerAvailable)
            Text("Click the shelf control to open or close it. Right-click it for options, including Turn Off.").helperStyle()
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
            if !service.isRunning { Text("Menu Bar Shelf is off. Turn it on in Advanced.").helperStyle() }
        } header: {
            Text("Open")
        }
        Section {
            Toggle(isOn: binding(\.hover)) {
                Text("Hover over the empty menu bar")
                Text(pointerNote("Opens after the pointer rests on empty bar.")).helperStyle()
            }
            .disabled(!pointerAvailable)
            Toggle(isOn: binding(\.scroll)) {
                Text("Scroll on the empty menu bar")
                Text(pointerNote("Scroll up opens, scroll down closes.")).helperStyle()
            }
            .disabled(!pointerAvailable)
            Toggle(isOn: binding(\.emptyClick)) {
                Text("Click the empty menu bar")
                Text(pointerNote("Click on empty bar toggles the shelf.")).helperStyle()
            }
            .disabled(!pointerAvailable)
        } header: {
            Text("Optional triggers")
        } footer: {
            Text("These need Accessibility, never act over an app's menu, a status item, the notch or an open menu, and stop while secure input is on.").footerStyle()
        }
        Section {
            Picker("Hide again after", selection: binding(\.rehideSeconds)) {
                ForEach(MenuBarTriggerSettings.rehideChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                }
            }
            Toggle(isOn: binding(\.rehideOnAppChange)) {
                Text("Hide again when I switch apps")
                Text("Hides when another app becomes frontmost. Portside itself never counts.").helperStyle()
            }
            if let status = service.status { Text(status).helperStyle() }
        } header: {
            Text("Hide again")
        } footer: {
            Text("Only a reveal you made with a trigger above hides again. A menu that is open, a mouse button held down or a layout change running waits it out. Sleep, wake and a display change show everything and cancel the timer.").footerStyle()
        }
    }

    private func pointerNote(_ what: String) -> String {
        pointerAvailable ? what : "Not validated yet, so it stays off. \(what)"
    }
}
