import SwiftUI

struct AgentNotchSettingsView: View {
    @ObservedObject var model: DockModel
    /// Shows the Clipboard History settings, which the Clipboard page needs.
    var openClipboardSettings: () -> Void = {}
    /// Form's DisclosureGroup often fails to collapse; match Appearance's
    /// chevron row that toggles the editor under it.
    @State private var accentOpen = false
    /// The one open section; the preview shows the part it changes.
    @State private var openSection: String?
    private var scene: NotchPreviewScene { openSection.flatMap { Self.scenes[$0] } ?? .strip }
    @State private var confirmReset = false
    @ObservedObject private var accessibility = AccessibilityTrust.shared
    @ObservedObject private var hotkeyStatus = NotchShelfHotkeyStatus.shared

    private var preferences: AgentNotchSettings { model.agentNotchSettings }

    var body: some View {
        // The preview stays in view while the sections scroll under it.
        VStack(spacing: 0) {
            if model.showAgentNotch {
                NotchSettingsPreview(preferences: preferences, scene: scene)
                    .padding(.horizontal, 20).padding(.top, 14)
                Divider()
            }
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.showAgentNotch }, set: { model.setShowAgentNotch($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Top Notch")
                            Text("Your music, agents and alerts around the notch. Hover the notch to open the shelf.").helperStyle()
                        }
                    }
                    .settingsAnchor("Top Notch")
                }
                if model.showAgentNotch { details }
            }
        }
    }

    /// What each section's preview shows: the part of the notch it changes.
    private static let scenes: [String: NotchPreviewScene] = [
        "Strip": .strip,
        "Shelf": .page(.widgets),
        "Alerts": .card(.airPods),
        "Music": .card(.music),
        "Agents": .page(.agents),
        "Files": .page(.files),
        "Hotkeys": .strip,
        "Volume and brightness": .volume,
        "Look and feel": .card(.music),
        "Displays": .strip,
    ]

    /// One section open at a time; opening one closes the other.
    private func folded(_ title: String) -> Binding<Bool> {
        Binding(get: { openSection == title }, set: { open in
            if open { openSection = title } else if openSection == title { openSection = nil }
        })
    }

    /// Everything past the on switch, shown while Top Notch is on (SHELF-12):
    /// one section per part of the notch, nothing hidden by another switch
    /// except a setting's own details.
    @ViewBuilder
    private var details: some View {
        Section {
            SettingsFold("Strip", symbol: "capsule", summary: stripSummary, isOpen: folded("Strip")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Order: the first two that are running share the strip, left and right")
                    ForEach(Array(preferences.stripOrder.enumerated()), id: \.element) { index, activity in
                        HStack(spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                            Text(activity.title)
                            Spacer()
                            Button { model.updateAgentNotch { $0.stripOrder.swapAt(index, index - 1) } } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move \(activity.title) up")
                            Button { model.updateAgentNotch { $0.stripOrder.swapAt(index, index + 1) } } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(index == preferences.stripOrder.count - 1)
                                .accessibilityLabel("Move \(activity.title) down")
                        }
                    }
                }
                slider("Width", \.compactWidth, AgentNotchSettings.compactWidthRange, unit: "pt")
            }
            SettingsFold("Shelf", symbol: "rectangle.topthird.inset.filled", summary: shelfSummary, isOpen: folded("Shelf")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tabs")
                    ForEach(Array(preferences.shelfPages.order.enumerated()), id: \.element) { index, page in
                        shelfPageRow(page, index: index)
                    }
                }
                Picker("Opens on", selection: binding(\.shelfPages.start)) {
                    ForEach(NotchShelfStartPage.allCases) { Text($0.title).tag($0) }
                }
                Picker("Widgets page, left", selection: binding(\.shelfLeadingWidget)) {
                    ForEach(NotchShelfSlot.allCases) { Text($0.title).tag($0) }
                }
                Picker("Widgets page, right", selection: binding(\.shelfTrailingWidget)) {
                    ForEach(NotchShelfSlot.allCases) { Text($0.title).tag($0) }
                }
                Picker("Agent card shows", selection: binding(\.agentCard)) {
                    ForEach(NotchAgentCard.allCases) { Text($0 == .latest ? "Latest" : "All").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            SettingsFold("Alerts", symbol: "bell.badge", summary: alertsSummary, isOpen: folded("Alerts")) {
                Picker("Meeting soon", selection: binding(\.meetingMinutes)) {
                    ForEach(NotchMeetingSoon.choices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : "\(minutes) min before").tag(minutes)
                    }
                }
                .disabled(model.restrictedMode)
                Toggle("Agent finished or needs you", isOn: binding(\.alertAgents))
                Toggle("Battery low or charging", isOn: binding(\.alertBattery))
                if preferences.alertBattery {
                    Picker("Low battery at", selection: binding(\.batteryLowPercent)) {
                        ForEach(AgentNotchSettings.batteryLowChoices, id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
                Toggle("AirPods connected or low", isOn: binding(\.alertAirPods))
                if preferences.alertAirPods {
                    Picker("Low AirPods at", selection: binding(\.airPodsLowPercent)) {
                        ForEach(AgentNotchSettings.batteryLowChoices, id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
                Toggle("Live AirPods levels", isOn: binding(\.airPodsLive))
                    .disabled(model.restrictedMode)
                if model.restrictedMode {
                    Text("Off in restricted mode: meetings read your calendar and live AirPods levels scan Bluetooth.").helperStyle()
                } else if preferences.airPodsLive, AirPodsLiveScanner.denied {
                    Text("Bluetooth access is off for Portside. Turn it on in System Settings > Privacy & Security > Bluetooth.").helperStyle()
                }
                Toggle("Rain or snow soon", isOn: binding(\.alertWeather))
                Text("Alerts take the strip's right side for 4 seconds. Meetings need Calendar access (Widgets > Calendar) and show a timer while they run. AirPods and Beats levels come from System Information, every 5 minutes and when the AirPods tab opens, with no permission; Live AirPods levels also listens for the levels your AirPods broadcast over Bluetooth and updates within seconds, and asks for Bluetooth access the first time.").helperStyle()
            }
            SettingsFold("Music", symbol: "music.note", summary: musicSummary, isOpen: folded("Music")) {
                Toggle("Show music", isOn: binding(\.showMedia))
                if preferences.showMedia {
                    Picker("Style", selection: binding(\.musicStyle)) {
                        ForEach(NotchMusicStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Drag the progress bar to seek", isOn: binding(\.musicSeeking))
                    Toggle("Tint with album colors", isOn: binding(\.musicTint))
                    Toggle("Show the song when it changes", isOn: binding(\.musicBanner))
                    Toggle("Hide when paused", isOn: binding(\.musicHideWhenPaused))
                }
            }
            SettingsFold("Agents", symbol: "sparkles", summary: agentsSummary, isOpen: folded("Agents")) {
                Picker("Working animation", selection: binding(\.thinking)) {
                    ForEach(NotchThinkingStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Claude Code", isOn: binding(\.claude))
                Toggle("Codex", isOn: binding(\.codex))
                Toggle("OpenCode", isOn: binding(\.opencode))
                Toggle("Cursor (in T3)", isOn: binding(\.cursor))
                Toggle("Copilot", isOn: binding(\.copilot))
                Toggle("ChatGPT", isOn: binding(\.chatgpt))
                Picker("Show", selection: binding(\.filter)) {
                    ForEach(AgentNotchFilter.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Include finished sessions", isOn: binding(\.showFinished))
                if preferences.showFinished {
                    Picker("Hide finished after", selection: binding(\.finishedDismissMinutes)) {
                        ForEach(AgentNotchSettings.finishedDismissChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : minutes == 60 ? "1 hour" : "\(minutes) min").tag(minutes)
                        }
                    }
                }
                Stepper("Sessions in the list: \(preferences.maxSessions)", value: binding(\.maxSessions), in: 2...10)
                Toggle("Show project names", isOn: binding(\.showProject))
                Toggle("Show provider names", isOn: binding(\.showProviderNames))
                Toggle("Show terminal or editor", isOn: binding(\.showHost))
                Toggle("Show time since activity", isOn: binding(\.showUpdated))
                Toggle("Show plan usage", isOn: binding(\.showUsage))
                Toggle("Close the shelf after opening a session", isOn: binding(\.collapseAfterFocus))
                Text("Claude Code and Codex need Agent Hooks in Settings > Widgets; T3 Code and OpenCode are read directly.").helperStyle()
            }
            SettingsFold("Files", symbol: "tray", summary: filesSummary, isOpen: folded("Files")) {
                Picker("Keep files for", selection: binding(\.filesKeep)) {
                    ForEach(NotchFilesKeep.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: binding(\.filesRemoveAfterDrag)) {
                    Text("Remove a file after dragging it out")
                    Text("Off keeps it on the shelf to drop again.").helperStyle()
                }
                Text("Drag files onto the notch to hold them. Only a link is kept: the files stay where they are.").helperStyle()
            }
            SettingsFold("Hotkeys", symbol: "command", summary: hotkeysSummary, isOpen: folded("Hotkeys")) {
                shelfHotkey("Open or close the shelf", \.shelfToggleHotkey)
                shelfHotkey("Open on Files", \.shelfFilesHotkey)
                shelfHotkey("Search clipboard", \.shelfClipboardHotkey)
                Picker("Opened by a hotkey, stays for", selection: binding(\.hotkeyOpenSeconds)) {
                    ForEach(AgentNotchSettings.hotkeyOpenChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                    }
                }
                Text("None are set. A shelf a hotkey opens stays when the pointer leaves, until this time runs out or you press Escape or click outside. Search clipboard puts up a search field on the Clipboard page: type, then Return copies the first match.").helperStyle()
            }
            SettingsFold("Volume and brightness", symbol: "speaker.wave.2", summary: levelsSummary, isOpen: folded("Volume and brightness")) {
                Toggle("Show volume changes", isOn: binding(\.hudVolume))
                Toggle(isOn: binding(\.hudBrightness)) {
                    Text("Show brightness changes")
                    Text("Built-in display only. Automatic brightness changes are skipped.").helperStyle()
                }
                Toggle(isOn: binding(\.hudReplaceSystem)) {
                    Text("Replace the macOS indicator")
                    Text(replaceHelp).helperStyle()
                }
                .disabled(model.restrictedMode || !(preferences.hudVolume || preferences.hudBrightness))
                if preferences.hudReplaceSystem, !accessibility.isTrusted, !model.restrictedMode {
                    Button("Allow Accessibility…") {
                        accessibility.requestAccess(forFeature: "replacing the macOS volume and brightness indicator")
                    }
                }
            }
            SettingsFold("Look and feel", symbol: "paintbrush", summary: lookSummary, isOpen: folded("Look and feel")) {
                slider("Height", \.compactHeight, 24...44, unit: "pt")
                slider("Corner radius", \.cornerRadius, 8...32, unit: "pt")
                slider("Background opacity", \.opacity, 0.75...1, percent: true)
                slider("Card width", \.expandedWidth, 340...560, unit: "pt")
                slider("Text size", \.fontSize, 10...16, unit: "pt")
                slider("Card spacing", \.rowSpacing, 4...16, unit: "pt")
                Toggle("Border", isOn: binding(\.showBorder))
                Toggle("Use provider colors", isOn: binding(\.providerColors))
                Button {
                    accentOpen.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Text("Accent color")
                        Spacer()
                        ColorChip(color: preferences.accent.color, size: 18)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(accentOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accentOpen ? "Hide accent color" : "Show accent color")
                if accentOpen {
                    PaletteColorEditor(color: preferences.accent, showsOpacity: false) { color, _ in
                        model.updateAgentNotch { $0.accent = color }
                    }
                }
                slider("Hover delay", \.shelfHoverDelay, 0...1, unit: "ms", milliseconds: true)
                slider("Collapse delay", \.shelfCollapseDelay, 0.1...2, unit: "ms", milliseconds: true)
                Toggle("Haptic feedback on hover", isOn: binding(\.shelfHaptics))
                Toggle("Animate", isOn: binding(\.animate))
                if preferences.animate { slider("Animation duration", \.animationDuration, 0.1...0.5, unit: "ms", milliseconds: true) }
            }
            SettingsFold("Displays", symbol: "display.2", summary: displaysSummary, isOpen: folded("Displays")) {
                Picker("Show on", selection: binding(\.display)) {
                    ForEach(AgentNotchDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: binding(\.showInFullScreen)) {
                    Text("Show in full screen")
                    Text("Off hides the notch while an app is full screen.").helperStyle()
                }
            }
        }
        Section {
            Button("Reset Top Notch Settings…") { confirmReset = true }
        }
        .confirmationDialog("Reset every Top Notch setting?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.updateAgentNotch { $0 = AgentNotchSettings() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hotkeys, alerts, tabs and the look go back to their defaults. Files and clipboard history stay.")
        }
    }

    private var stripSummary: String {
        let order = preferences.stripOrder.map { $0 == .meeting ? "meeting" : $0.title.lowercased() }.joined(separator: ", ")
        return "\(order.prefix(1).uppercased() + order.dropFirst()), \(Int(preferences.compactWidth)) pt"
    }

    private var lookSummary: String {
        "\(Int(preferences.compactHeight)) pt high, hover \(Int((preferences.shelfHoverDelay * 1000).rounded())) ms, collapse \(Int((preferences.shelfCollapseDelay * 1000).rounded())) ms"
    }

    private var displaysSummary: String {
        preferences.display.title + (preferences.showInFullScreen ? ", also in full screen" : "")
    }

    private var shelfSummary: String {
        "\(preferences.shelfLeadingWidget.title) and \(preferences.shelfTrailingWidget.title), opens on \(preferences.shelfPages.start.title.lowercased())"
    }

    private var filesSummary: String {
        let kept = "Kept for \(preferences.filesKeep.title.replacingOccurrences(of: "1 ", with: "a "))"
        return preferences.filesRemoveAfterDrag ? kept + ", removed after dragging out" : kept
    }

    private var levelsSummary: String {
        let shown = settingsList([("Volume", preferences.hudVolume), ("brightness", preferences.hudBrightness)])
        return preferences.hudReplaceSystem && !model.restrictedMode && shown != "Off" ? shown + ", replaces macOS" : shown
    }

    private var replaceHelp: String {
        if model.restrictedMode { return "Off in restricted mode: it reads the volume and brightness keys." }
        if preferences.hudReplaceSystem && !accessibility.isTrusted { return "Needs Accessibility to take the volume and brightness keys. Until then macOS shows its own." }
        return "Portside takes the volume and brightness keys and sets the level itself, so only the notch shows it. Off, macOS shows its own indicator too."
    }

    /// One shelf hotkey row, with why it may not work under it.
    @ViewBuilder
    private func shelfHotkey(_ title: String, _ key: WritableKeyPath<AgentNotchSettings, HotkeyChord?>) -> some View {
        HotkeyRecorderButton(title: title, chord: preferences[keyPath: key], defaultChord: nil) { chord in
            model.updateAgentNotch { $0[keyPath: key] = chord }
        }
        if let chord = preferences[keyPath: key], let warning = hotkeyWarning(title, chord) {
            Label { Text(warning).helperStyle() } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private func hotkeyWarning(_ title: String, _ chord: HotkeyChord) -> String? {
        let shelf: [(name: String, chord: HotkeyChord?)] = [
            ("Open or close the shelf", preferences.shelfToggleHotkey), ("Open on Files", preferences.shelfFilesHotkey),
            ("Search clipboard", preferences.shelfClipboardHotkey),
        ].filter { $0.name != title }
        let portside = [("Open Settings", model.settingsHotkey), ("Command Center", model.commandCenterHotkey),
                        ("App Switcher", model.switcherHotkey)] + shelf
        return HotkeyConflicts.conflict(for: chord, system: HotkeyConflicts.systemHotkeys(), portside: portside)
            ?? hotkeyStatus.failures[title]
    }

    private var hotkeysSummary: String {
        let set = [preferences.shelfToggleHotkey, preferences.shelfFilesHotkey, preferences.shelfClipboardHotkey].compactMap { $0 }
        return set.isEmpty ? "None set" : set.map(\.displayString).joined(separator: ", ")
    }

    private var alertsSummary: String {
        let alerts = settingsList([("Agents", preferences.alertAgents), ("battery", preferences.alertBattery),
                                   ("AirPods", preferences.alertAirPods), ("weather", preferences.alertWeather)], none: "No alerts")
        return preferences.meetingsOn(restricted: model.restrictedMode) ? "\(alerts), meetings" : alerts
    }

    private var musicSummary: String {
        guard preferences.showMedia else { return "Off" }
        var parts = [preferences.musicStyle == .vinyl ? "Vinyl" : "Album art"]
        if preferences.musicSeeking { parts.append("seeking") }
        if preferences.musicTint { parts.append("album tint") }
        if preferences.musicBanner { parts.append("song banner") }
        return parts.joined(separator: ", ")
    }

    private var agentsSummary: String {
        let names: [(String, Bool)] = [("Claude", preferences.claude), ("Codex", preferences.codex), ("OpenCode", preferences.opencode),
                                       ("Cursor", preferences.cursor), ("Copilot", preferences.copilot),
                                       ("ChatGPT", preferences.chatgpt)]
        let on = names.filter(\.1).map(\.0)
        let who = on.count == names.count ? "All agents" : on.isEmpty ? "No agents" : on.joined(separator: ", ")
        return "\(who), \(preferences.filter.title.lowercased())"
    }

    private func shelfPageRow(_ page: NotchShelfPage, index: Int) -> some View {
        let pages = preferences.shelfPages
        let needsClipboard = page == .clipboard && !model.clipboardHistoryOn
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: page.symbol).frame(width: 18).foregroundStyle(.secondary)
                Toggle(page.title, isOn: Binding(get: { pages.isOn(page) }, set: { on in model.updateAgentNotch { $0.shelfPages.setOn(page, on) } }))
                Button { model.updateAgentNotch { $0.shelfPages.move(page, by: -1) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move \(page.title) earlier")
                Button { model.updateAgentNotch { $0.shelfPages.move(page, by: 1) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == pages.order.count - 1).accessibilityLabel("Move \(page.title) later")
            }
            if page == .airPods {
                Text("Shows while AirPods or Beats are connected.").helperStyle()
            }
            if needsClipboard {
                HStack {
                    Text("Shows Clipboard History, which is off. The tab stays hidden until it is on.").helperStyle()
                    Spacer()
                    Button("Clipboard History…", action: openClipboardSettings)
                }
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<AgentNotchSettings, Value>) -> Binding<Value> {
        Binding(get: { model.agentNotchSettings[keyPath: key] }, set: { value in model.updateAgentNotch { $0[keyPath: key] = value } })
    }

    /// Same continuous `SettingsSlider` as Dock and Appearance: no tick marks,
    /// fixed label and value columns, live update while dragging.
    private func slider(_ title: String, _ key: WritableKeyPath<AgentNotchSettings, Double>,
                        _ range: ClosedRange<Double>, unit: String = "",
                        percent: Bool = false, milliseconds: Bool = false) -> some View {
        SettingsSlider(
            title: title,
            value: preferences[keyPath: key],
            range: range,
            snap: percent ? 0.01 : milliseconds ? 0.05 : 1,
            format: { value in
                if percent { return "\(Int((value * 100).rounded()))%" }
                if milliseconds { return "\(Int((value * 1000).rounded())) ms" }
                return "\(Int(value.rounded())) \(unit)"
            },
            set: { value, persist in model.updateAgentNotch({ $0[keyPath: key] = value }, persist: persist) }
        )
    }
}
