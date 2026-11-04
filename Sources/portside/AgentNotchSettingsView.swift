import SwiftUI

struct AgentNotchSettingsView: View {
    @ObservedObject var model: DockModel
    /// Form's DisclosureGroup often fails to collapse; match Appearance's
    /// chevron row that toggles the editor under it.
    @State private var accentOpen = false

    private var preferences: AgentNotchSettings { model.agentNotchSettings }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Agent Notch", isOn: Binding(get: { model.showAgentNotch }, set: { model.setShowAgentNotch($0) }))
                AgentNotchSettingsPreview(preferences: preferences)
                Text("Preview uses sample activity. Real sessions come from agent hooks in Widgets.").helperStyle()
                HStack {
                    Text("Quick styles")
                    Spacer()
                    Button("Minimal") { preset("minimal") }
                    Button("Balanced") { preset("balanced") }
                    Button("Detailed") { preset("detailed") }
                }
            }
            Section("Placement") {
                Picker("Position", selection: binding(\.position)) {
                    ForEach(AgentNotchPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker("Displays", selection: binding(\.display)) {
                    ForEach(AgentNotchDisplay.allCases) { Text($0.title).tag($0) }
                }
                if preferences.position != .attached {
                    slider("Horizontal offset", \.horizontalOffset, -300...300, unit: "pt")
                    slider("Distance from top", \.verticalOffset, 0...80, unit: "pt")
                }
                Text("Attached mode wraps the camera housing and keeps its center clear. Other displays use a floating island below the menu bar. Left and right positions can overlap menu items.").helperStyle()
            }
            Section("Compact appearance") {
                Picker("Style", selection: binding(\.compactStyle)) {
                    ForEach(AgentNotchCompactStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show total session count", isOn: binding(\.showTotal))
                Toggle("Show border", isOn: binding(\.showBorder))
                slider("Content width", \.compactWidth, 140...280, unit: "pt")
                slider("Height", \.compactHeight, 24...44, unit: "pt")
                slider("Corner radius", \.cornerRadius, 8...32, unit: "pt")
                slider("Background opacity", \.opacity, 0.75...1, percent: true)
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
            Section("Dashboard") {
                slider("Expanded width", \.expandedWidth, 340...560, unit: "pt")
                slider("Text size", \.fontSize, 10...16, unit: "pt")
                slider("Card spacing", \.rowSpacing, 4...16, unit: "pt")
                Stepper("Visible sessions: \(preferences.maxSessions)", value: binding(\.maxSessions), in: 2...10)
                Text("More sessions and usage rows scroll inside the dashboard.").helperStyle()
                Toggle("Show project names", isOn: binding(\.showProject))
                Toggle("Show provider names", isOn: binding(\.showProviderNames))
                Toggle("Show terminal or editor", isOn: binding(\.showHost))
                Toggle("Show time since activity", isOn: binding(\.showUpdated))
                Toggle("Show plan usage", isOn: binding(\.showUsage))
                Text("Usage shares your Widgets provider selections and consent. Gauges show plan usage, not session context. Context and inline approvals are not supplied by the current hooks.").helperStyle()
            }
            Section("Behavior") {
                Toggle("Expand on hover", isOn: binding(\.expandOnHover))
                if preferences.expandOnHover { slider("Hover delay", \.hoverDelay, 0...1, unit: "ms", milliseconds: true) }
                slider("Collapse delay", \.collapseDelay, 0.1...2, unit: "ms", milliseconds: true)
                Picker("Click action", selection: binding(\.clickAction)) {
                    ForEach(AgentNotchClickAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Collapse after opening a session", isOn: binding(\.collapseAfterFocus))
                Toggle("Animate status and expansion", isOn: binding(\.animate))
                if preferences.animate { slider("Animation duration", \.animationDuration, 0.1...0.5, unit: "ms", milliseconds: true) }
                Toggle("Hide when no sessions match", isOn: binding(\.hideWhenEmpty))
                Text("Pin the dashboard to keep it open. The close button always collapses it; clicking outside closes it when unpinned. Escape works while Portside receives keyboard events. Reduce Motion disables animation.").helperStyle()
            }
            Section("Sessions") {
                Toggle("Claude Code", isOn: binding(\.claude))
                Toggle("Codex", isOn: binding(\.codex))
                Toggle("Copilot", isOn: binding(\.copilot))
                Picker("Show", selection: binding(\.filter)) {
                    ForEach(AgentNotchFilter.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Include finished sessions", isOn: binding(\.showFinished))
                Text("Claude Code and Codex sessions come from the agent hooks. Copilot has no hook source yet, so its toggle only applies if a Copilot session file appears. Needs attention includes finished turns and explicit Claude permission or input notifications. Click a session card to focus its terminal or editor; Accessibility access may be needed.").helperStyle()
            }
            Section {
                Button("Reset Notch Customization") { model.updateAgentNotch { $0 = AgentNotchSettings() } }
                Text("Resets this pane's appearance, behavior and filters. The enable switch and Widgets settings are preserved.").helperStyle()
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
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(preferences.accent.color)
                if preferences.compactStyle == .counts { Text("2").monospacedDigit() }
                if preferences.compactStyle == .providers {
                    Circle().fill(preferences.providerColors ? AgentProvider.named("claude").color : preferences.accent.color).frame(width: 6, height: 6)
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
            .padding(12).background(.black.opacity(preferences.opacity), in: RoundedRectangle(cornerRadius: preferences.cornerRadius))
        }
        .font(.system(size: preferences.fontSize)).foregroundStyle(.white)
        .padding(16).frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore).accessibilityLabel("Sample notch preview")
    }
}
