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

/// The menu bar modules, then the reorder and layout controls for other
/// apps' items. Their sections appear once their module is on.
struct MenuBarSettings: View {
    @ObservedObject var integrations: IntegrationSettings

    var body: some View {
        Form {
            ModuleRowsSection(
                integrations: integrations,
                ids: [MenuBarShelfModule.moduleID, MenuBarLayoutModule.moduleID, MenuBarReorderModule.moduleID],
                title: "Modules",
                footer: "Layout and Reorder move other apps' items with real Command-drags and need Accessibility."
            )
            if let layout = integrations.menuLayout {
                MenuBarLayoutSection(service: layout)
            }
            if let reorder = integrations.menuReorder {
                MenuBarReorderSection(service: reorder)
            }
        }
        .keepsIntegrationsCurrent(integrations)
    }
}
