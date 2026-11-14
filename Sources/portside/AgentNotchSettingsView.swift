import SwiftUI

struct AgentNotchSettingsView: View {
    @ObservedObject var model: DockModel
    /// Shows the Clipboard History settings, which the Clipboard page needs.
    var openClipboardSettings: () -> Void = {}
    /// Form's DisclosureGroup often fails to collapse; match Appearance's
    /// chevron row that toggles the editor under it.
    @State private var accentOpen = false

    private var preferences: AgentNotchSettings { model.agentNotchSettings }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.showAgentNotch }, set: { model.setShowAgentNotch($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top Notch")
                        Text("A black island around the notch that shows your agents and music.").helperStyle()
                    }
                }
                .settingsAnchor("Top Notch")
                if model.showAgentNotch { AgentNotchSettingsPreview(preferences: preferences) }
            }
            if model.showAgentNotch { details }
        }
    }

    /// Everything past the on switch, shown while Top Notch is on.
    @ViewBuilder
    private var details: some View {
            Section {
                cards("Position", \.position, AgentNotchPosition.allCases.map { ($0, $0.title) }, columns: 4) { NotchPositionPicture(position: $0) }
                Toggle(isOn: binding(\.shelfEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notch Shelf")
                        Text("Hover music or agents to see a card. Hover the notch itself to open the shelf.").helperStyle()
                    }
                }
                .settingsAnchor("Notch Shelf")
                Toggle(isOn: binding(\.showMedia)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show music")
                        Text(preferences.shelfEnabled ? "Album art and the playing animation while something plays."
                             : "A playing animation while something plays.").helperStyle()
                    }
                }
            }
            Section {
                SettingsFold("Appearance", symbol: "paintbrush", summary: appearanceSummary) {
                    HStack {
                        Text("Quick styles")
                        Spacer()
                        Button("Minimal") { preset("minimal") }
                        Button("Balanced") { preset("balanced") }
                        Button("Detailed") { preset("detailed") }
                    }
                    if !preferences.shelfEnabled {
                        cards("Style", \.compactStyle, AgentNotchCompactStyle.allCases.map { ($0, $0.title) }, columns: 3) { NotchCompactStylePicture(style: $0) }
                    }
                    slider("Width", \.compactWidth, 140...280, unit: "pt")
                    slider("Height", \.compactHeight, 24...44, unit: "pt")
                    slider("Corner radius", \.cornerRadius, 8...32, unit: "pt")
                    slider("Background opacity", \.opacity, 0.75...1, percent: true)
                    Toggle("Show border", isOn: binding(\.showBorder))
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
                }
                if preferences.shelfEnabled {
                    SettingsFold("Shelf", symbol: "rectangle.topthird.inset.filled", summary: shelfSummary) {
                        cards("Widgets page, left", \.shelfLeadingWidget, NotchShelfSlot.allCases.map { ($0, $0.title) }, columns: 4) { NotchSlotPicture(slot: $0) }
                        cards("Widgets page, right", \.shelfTrailingWidget, NotchShelfSlot.allCases.map { ($0, $0.title) }, columns: 4) { NotchSlotPicture(slot: $0) }
                        cards("Opens on", \.shelfPages.start, NotchShelfStartPage.allCases.map { ($0, $0.title) }, columns: 5) { NotchStartPagePicture(start: $0) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tabs")
                            ForEach(Array(preferences.shelfPages.order.enumerated()), id: \.element) { index, page in
                                shelfPageRow(page, index: index)
                            }
                        }
                        cards("Agent card", \.agentCard, NotchAgentCard.allCases.map { ($0, $0.title) }, columns: 2) { NotchAgentCardPicture(card: $0) }
                        Toggle("Haptic feedback on hover", isOn: binding(\.shelfHaptics))
                    }
                }
                if preferences.showMedia, preferences.shelfEnabled {
                    SettingsFold("Music", symbol: "music.note", summary: musicSummary) {
                        cards("Style", \.musicStyle, NotchMusicStyle.allCases.map { ($0, $0.title) }, columns: 2) { NotchMusicStylePicture(style: $0) }
                        Toggle("Drag the progress bar to seek", isOn: binding(\.musicSeeking))
                        Toggle("Tint with album colors", isOn: binding(\.musicTint))
                        Toggle("Show the song when it changes", isOn: binding(\.musicBanner))
                        Toggle("Hide when paused", isOn: binding(\.musicHideWhenPaused))
                    }
                }
                SettingsFold("Agents", symbol: "sparkles", summary: agentsSummary) {
                    Toggle("Claude Code", isOn: binding(\.claude))
                    Toggle("Codex", isOn: binding(\.codex))
                    Toggle("OpenCode", isOn: binding(\.opencode))
                    Toggle("Cursor (in T3)", isOn: binding(\.cursor))
                    Toggle("Copilot", isOn: binding(\.copilot))
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
                    slider("List width", \.expandedWidth, 340...560, unit: "pt")
                    slider("Text size", \.fontSize, 10...16, unit: "pt")
                    slider("Card spacing", \.rowSpacing, 4...16, unit: "pt")
                    Text("Claude Code and Codex need Agent Hooks in Settings > Widgets; T3 Code and OpenCode are read directly.").helperStyle()
                }
                SettingsFold("Behavior", symbol: "hand.point.up.left", summary: behaviorSummary) {
                    if preferences.shelfEnabled {
                        slider("Hover delay", \.shelfHoverDelay, 0...1, unit: "ms", milliseconds: true)
                        slider("Collapse delay", \.shelfCollapseDelay, 0.1...2, unit: "ms", milliseconds: true)
                    } else {
                        Toggle("Expand on hover", isOn: binding(\.expandOnHover))
                        if preferences.expandOnHover { slider("Hover delay", \.hoverDelay, 0...1, unit: "ms", milliseconds: true) }
                        slider("Collapse delay", \.collapseDelay, 0.1...2, unit: "ms", milliseconds: true)
                        cards("Click action", \.clickAction, AgentNotchClickAction.allCases.map { ($0, $0.title) }, columns: 2) { NotchClickActionPicture(action: $0) }
                    }
                    Toggle("Collapse after opening a session", isOn: binding(\.collapseAfterFocus))
                    Toggle("Hide when nothing is running", isOn: binding(\.hideWhenEmpty))
                    Toggle("Animate", isOn: binding(\.animate))
                    if preferences.animate { slider("Animation duration", \.animationDuration, 0.1...0.5, unit: "ms", milliseconds: true) }
                }
                SettingsFold("Displays", symbol: "display.2", summary: preferences.display.title) {
                    cards("Show on", \.display, AgentNotchDisplay.allCases.map { ($0, $0.title) }, columns: 3) { NotchDisplayPicture(display: $0) }
                    if preferences.position != .attached {
                        slider("Horizontal offset", \.horizontalOffset, -300...300, unit: "pt")
                        slider("Distance from top", \.verticalOffset, 0...80, unit: "pt")
                    }
                }
            }
            Section {
                Button("Reset Top Notch Settings") { model.updateAgentNotch { $0 = AgentNotchSettings() } }
            }
    }

    private var appearanceSummary: String {
        let size = "\(Int(preferences.compactWidth)) × \(Int(preferences.compactHeight)) pt"
        return preferences.shelfEnabled ? size : "\(preferences.compactStyle.title), \(size)"
    }

    private var shelfSummary: String {
        "\(preferences.shelfLeadingWidget.title) and \(preferences.shelfTrailingWidget.title), opens on \(preferences.shelfPages.start.title.lowercased())"
    }

    private var musicSummary: String {
        var parts = [preferences.musicStyle == .vinyl ? "Vinyl" : "Album art"]
        if preferences.musicSeeking { parts.append("seeking") }
        if preferences.musicTint { parts.append("album tint") }
        if preferences.musicBanner { parts.append("song banner") }
        return parts.joined(separator: ", ")
    }

    private var agentsSummary: String {
        let names: [(String, Bool)] = [("Claude", preferences.claude), ("Codex", preferences.codex), ("OpenCode", preferences.opencode),
                                       ("Cursor", preferences.cursor), ("Copilot", preferences.copilot)]
        let on = names.filter(\.1).map(\.0)
        let who = on.count == names.count ? "All agents" : on.isEmpty ? "No agents" : on.joined(separator: ", ")
        return "\(who), \(preferences.filter.title.lowercased())"
    }

    private var behaviorSummary: String {
        let hover = preferences.shelfEnabled ? preferences.shelfHoverDelay : preferences.hoverDelay
        let collapse = preferences.shelfEnabled ? preferences.shelfCollapseDelay : preferences.collapseDelay
        return "Hover \(Int((hover * 1000).rounded())) ms, collapse \(Int((collapse * 1000).rounded())) ms"
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
            if needsClipboard {
                HStack {
                    Text("Shows Clipboard History, which is off. The tab stays hidden until it is on.").helperStyle()
                    Spacer()
                    Button("Clipboard History…", action: openClipboardSettings)
                }
            }
        }
    }

    /// A titled row of picture cards, as in Settings > Menu Bar.
    private func cards<Value: Hashable, Picture: View>(_ title: String, _ key: WritableKeyPath<AgentNotchSettings, Value>,
                                                      _ choices: [(Value, String)], columns: Int,
                                                      @ViewBuilder picture: @escaping (Value) -> Picture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            SettingsChoiceCards(selection: binding(key), choices: choices, columns: columns, picture: picture)
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

    private func preset(_ name: String) {
        model.updateAgentNotch { settings in
            let position = settings.position
            let display = settings.display
            settings = AgentNotchSettings()
            settings.position = position
            settings.display = display
            if name == "minimal" {
                settings.compactStyle = .minimal
                settings.compactWidth = 140
                settings.showTotal = false
                settings.showUsage = false
                settings.showHost = false
                settings.showUpdated = false
            } else if name == "detailed" {
                settings.compactStyle = .providers
                settings.expandedWidth = 500
                settings.maxSessions = 8
                settings.fontSize = 13
            }
        }
    }
}

struct AgentNotchSettingsPreview: View {
    let preferences: AgentNotchSettings

    var body: some View {
        Group {
            if preferences.shelfEnabled { shelf } else { classic }
        }
        .font(.system(size: preferences.fontSize)).foregroundStyle(.white)
        .padding(16).frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore).accessibilityLabel("Sample notch preview")
    }

    /// The shelf with music playing: the strip (art and animation) and the
    /// music card that hovering it shows.
    private var shelf: some View {
        let art = LinearGradient(colors: [.pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        return VStack(spacing: 10) {
            HStack {
                RoundedRectangle(cornerRadius: 4).fill(art).frame(width: 18, height: 18)
                Spacer()
                NotchAudioBars(paused: !preferences.animate, color: preferences.accent.color, height: 12)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 12) {
                Group {
                    if preferences.musicStyle == .vinyl {
                        ZStack {
                            Circle().fill(Color(white: 0.08))
                            Circle().fill(art).padding(3)
                            Circle().fill(Color.black).frame(width: 7, height: 7)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(art)
                    }
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Song title").fontWeight(.semibold)
                    Text("Artist").foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 6) {
                        Capsule().fill(Color.white.opacity(0.8)).frame(width: 60, height: 3)
                        Capsule().fill(Color.white.opacity(0.15)).frame(height: 3)
                    }
                    HStack(spacing: 24) {
                        Image(systemName: "backward.fill"); Image(systemName: "pause.fill"); Image(systemName: "forward.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .background {
                if preferences.musicTint {
                    LinearGradient(colors: [Color.indigo.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                }
            }
        }
        .frame(width: min(420, preferences.expandedWidth))
        .background(UnevenRoundedRectangle(bottomLeadingRadius: preferences.cornerRadius, bottomTrailingRadius: preferences.cornerRadius)
            .fill(.black.opacity(preferences.opacity)))
    }

    private var classic: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if preferences.compactStyle == .providers {
                    Circle().fill(preferences.providerColors ? AgentProvider.named("claude").color : preferences.accent.color).frame(width: 6, height: 6)
                } else {
                    let loaderSize = min(16, max(10, preferences.compactHeight * 0.48))
                    ThinkingLoader(
                        style: ThinkingLoader.preferredStyle(for: loaderSize),
                        paused: !preferences.animate,
                        size: loaderSize,
                        color: preferences.accent.color
                    )
                    if preferences.compactStyle == .counts { Text("2").monospacedDigit() }
                }
                Spacer(minLength: 12)
                if preferences.showTotal { Text("3 agents").foregroundStyle(.white.opacity(0.6)) }
                else { Image(systemName: "chevron.down").font(.system(size: 9)) }
            }
            .padding(.horizontal, 18)
            .frame(width: preferences.compactWidth, height: preferences.compactHeight)
            .background(.black.opacity(preferences.opacity), in: RoundedRectangle(cornerRadius: preferences.cornerRadius))
            .overlay {
                if preferences.showBorder {
                    RoundedRectangle(cornerRadius: preferences.cornerRadius)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(preferences.accent.color)
                    .frame(width: 30, height: 30).background(preferences.accent.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(preferences.showProject ? "portside" : "Claude").fontWeight(.medium)
                    HStack(spacing: 6) {
                        if preferences.showProviderNames { Text("Claude") }
                        if preferences.showHost { Text("Terminal") }
                        if preferences.showUpdated { Text("2s ago") }
                    }.font(.system(size: max(9, preferences.fontSize - 2))).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("Working").font(.system(size: 10)).foregroundStyle(preferences.accent.color)
                    .padding(7).background(.white.opacity(0.06), in: Capsule())
            }
            .padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
            .background(.black.opacity(preferences.opacity), in: RoundedRectangle(cornerRadius: preferences.cornerRadius))
        }
    }
}
