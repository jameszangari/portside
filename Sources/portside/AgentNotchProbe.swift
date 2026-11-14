#if DEBUG
import AppKit
import SwiftUI

enum AgentNotchProbe {
    @MainActor static func run() -> Int32 {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        do {
            let decoder = JSONDecoder()
            let defaults = try decoder.decode(AgentNotchSettings.self, from: Data("{}".utf8))
            try require(defaults == AgentNotchSettings(), "Missing keys must use defaults")
            let legacy = try decoder.decode(AgentNotchSettings.self, from: Data(#"{"position":"left","animate":false,"showTotal":false,"showUsage":false,"hideWhenEmpty":false}"#.utf8))
            try require(legacy.position == .left && !legacy.animate && !legacy.showUsage && !legacy.showTotal && !legacy.hideWhenEmpty,
                        "Legacy preferences must survive")
            let invalid = try decoder.decode(AgentNotchSettings.self, from: Data(#"{"position":"bad","display":"bad","compactWidth":9999,"opacity":-1,"fontSize":100,"maxSessions":0,"collapseDelay":-2}"#.utf8))
            try require(invalid.position == .attached && invalid.display == .automatic && invalid.compactWidth == 280
                        && invalid.opacity == 0.75 && invalid.fontSize == 16 && invalid.maxSessions == 2 && invalid.collapseDelay == 0.1,
                        "Invalid values must be bounded")
            var custom = AgentNotchSettings()
            custom.position = .right; custom.display = .all; custom.compactStyle = .providers; custom.clickAction = .focus
            custom.filter = .attention; custom.expandedWidth = 550; custom.fontSize = 15; custom.maxSessions = 9
            custom.showProject = false; custom.showHost = false; custom.showUpdated = false; custom.providerColors = false
            custom.expandOnHover = false; custom.claude = false; custom.codex = false; custom.copilot = false
            custom.opencode = false; custom.cursor = false
            custom.showBorder = false; custom.collapseAfterFocus = false
            custom.horizontalOffset = 55; custom.verticalOffset = 12; custom.accent.hue = 0.25
            let restored = try decoder.decode(AgentNotchSettings.self, from: JSONEncoder().encode(custom))
            try require(custom == restored, "Custom values must round-trip")
            custom.compactWidth = .nan; custom.animationDuration = .infinity; custom.normalize()
            try require(custom.compactWidth == 184 && custom.animationDuration == 0.22, "Non-finite values must normalize")
            let agents = try fixture()
            try require(agents.sessions.count == 3 && agents.sessions.filter(\.needsAttention).count == 1, "Hook attention classification")
            var filter = AgentNotchSettings()
            filter.filter = .working
            try require(filter.sessions(from: agents.sessions).count == 1, "Working filter excludes permission waits")
            filter.filter = .attention
            try require(filter.sessions(from: agents.sessions).count == 2, "Attention filter includes finished and waiting")
            filter.showFinished = false
            try require(filter.sessions(from: agents.sessions).count == 1, "Finished visibility filter")
            filter.claude = false
            try require(filter.sessions(from: agents.sessions).isEmpty, "Provider filter")
            filter.claude = true; filter.copilot = false
            try require(filter.sessions(from: agents.sessions).count == 1, "Copilot filter leaves Claude/Codex")
            let state = AgentNotchPresentation()
            state.preferences.hoverDelay = 0
            state.hover(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            try require(state.expanded, "Hover expands")
            state.preferences.collapseDelay = 0.01
            state.hover(false); state.pinned = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            try require(state.expanded, "Pin cancels pending collapse")
            state.pinned = false; state.hover(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            try require(!state.expanded, "Unpinned hover exit collapses")
            state.stop()
            print("PASS notch: defaults, legacy/custom Codable, invalid ranges, hook attention, filters, hover and pin lifecycle")
            return 0
        } catch { print("FAIL notch: \(error.localizedDescription)"); return 1 }
    }

    @MainActor static func fixture() throws -> AgentStatusWidget {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasPrefix("/tmp/") else {
            throw NSError(domain: "Notch fixtures require CFFIXED_USER_HOME under /tmp/", code: 1)
        }
        let directory = AgentStatusWidget.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, provider, event, project) in [(0, "claude", "Notification", "storefront-web"),
                                                (1, "codex", "UserPromptSubmit", "portside"),
                                                (2, "codex", "Stop", "checkout-api")] {
            let payload: [String: Any] = ["hook_event_name": event, "notification_type": "permission_prompt", "cwd": "/tmp/\(project)"]
            let json: [String: Any] = ["provider": provider, "pid": getpid(), "time": Date().timeIntervalSince1970 - Double(index * 15), "payload": payload]
            try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("notch-preview-\(index).json"))
        }
        let agents = AgentStatusWidget()
        agents.refresh()
        return agents
    }

    @MainActor static func render(to directory: String) -> Int32 {
        _ = NSApplication.shared
        do {
            let agents = try fixture()
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A fake track with generated art: no player is asked.
            let music = NowPlayingWidget()
            let art = NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
                NSGradient(starting: .systemPink, ending: .systemIndigo)?.draw(in: rect, angle: 45)
                return true
            }
            music.preview(NowPlayingWidget.Track(
                id: "probe", title: "I'm On", artist: "Anderson .Paak, Cordae", artwork: art, artworkURL: nil, isPlaying: true,
                player: NowPlayingWidget.Player(bundleID: "com.apple.Music", name: "Music", notification: ""),
                duration: 233, elapsed: 72, elapsedAt: Date()))
            let shelfVariants = ["shelf-agents", "shelf-widgets", "strip-music", "card-music", "card-vinyl", "card-agents"]
            for name in ["compact", "attached", "expanded", "large-text", "minimal"] + shelfVariants {
                let state = AgentNotchPresentation()
                state.preferences.animate = false
                state.expanded = name != "compact" && name != "attached" && !name.hasPrefix("strip") && !name.hasPrefix("card")
                if name == "attached" || shelfVariants.contains(name) { state.topAttached = true; state.headerHeight = 32; state.notchWidth = 180 }
                if shelfVariants.contains(name) {
                    state.preferences.shelfEnabled = true
                    state.preferences.shelfHoverDelay = 0
                    state.preferences.musicStyle = name == "card-vinyl" ? .vinyl : .music
                    state.preferences.musicTint = name == "card-vinyl"
                    state.compactWidth = 184 + 180 + 2 * NotchShape.flare
                    state.strip = name == "card-agents" ? NotchShelfStrip.layout(music: false, agents: true, agentAlert: false)
                        : NotchShelfStrip.layout(music: true, agents: true, agentAlert: false)
                    if name.hasPrefix("shelf") { state.showPage(name == "shelf-agents" ? .agents : .widgets) }
                    // Not started: no network or calendar queries, only each card's empty state.
                    let hosts = [WeatherWidget.kind, CalendarWidget.kind].compactMap { WidgetCatalog.make($0).map(WidgetHost.init(widget:)) }
                    state.widgetHost = { kind in hosts.first { $0.id == kind } }
                    if name.hasPrefix("card") {
                        state.panelWidth = state.preferences.expandedWidth + 2 * NotchShape.flare
                        state.shelfPointer(.side(.leading))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                }
                state.preferences.showUsage = false
                if name == "large-text" { state.preferences.fontSize = 16; state.preferences.expandedWidth = 340 }
                if name == "minimal" { state.preferences.compactStyle = .minimal; state.preferences.providerColors = false; state.preferences.showTotal = false }
                let shelfWide = state.preferences.shelfEnabled && (state.expanded || state.card != nil)
                let width = state.preferences.shelfEnabled && state.expanded ? AgentNotch.shelfOpenWidth
                    : shelfWide ? state.preferences.expandedWidth + 2 * NotchShape.flare
                    : state.expanded ? state.preferences.expandedWidth
                    : state.preferences.shelfEnabled ? state.compactWidth : state.preferences.compactWidth
                state.panelWidth = width
                let content = state.preferences.shelfEnabled
                    ? AgentNotchView.shelfHeight(page: state.currentPage, preferences: state.preferences, sessionCount: agents.sessions.count)
                    : AgentNotchView.dashboardHeight(preferences: state.preferences, sessionCount: agents.sessions.count)
                let card = state.card.map { AgentNotchView.cardHeight($0, preferences: state.preferences, sessionCount: agents.sessions.count) } ?? 0
                let height = state.headerHeight + (state.expanded ? content : card)
                let view = AgentNotchView(agents: agents, usage: nil, nowPlaying: music, state: state).frame(width: width, height: height)
                // Hosting view bitmaps are more reliable than ImageRenderer for ScrollView.
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
                hosting.appearance = NSAppearance(named: .darkAqua)
                hosting.layoutSubtreeIfNeeded()
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    throw NSError(domain: "Could not render notch preview", code: 1)
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "Could not encode notch preview", code: 1)
                }
                try data.write(to: folder.appendingPathComponent("notch-\(name).png"))
            }
            // Settings picture cards, light and dark.
            for (name, appearance) in [("settings-cards-light", NSAppearance.Name.aqua), ("settings-cards-dark", .darkAqua)] {
                let defaults = AgentNotchSettings()
                func row<Value: Hashable, Picture: View>(_ title: String, _ value: Value, _ choices: [(Value, String)], _ columns: Int,
                                                         @ViewBuilder _ picture: @escaping (Value) -> Picture) -> some View {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        SettingsChoiceCards(selection: .constant(value), choices: choices, columns: columns, picture: picture)
                    }
                }
                let view = VStack(alignment: .leading, spacing: 10) {
                    row("Position", defaults.position, AgentNotchPosition.allCases.map { ($0, $0.title) }, 4) { NotchPositionPicture(position: $0) }
                    row("Displays", defaults.display, AgentNotchDisplay.allCases.map { ($0, $0.title) }, 3) { NotchDisplayPicture(display: $0) }
                    row("Style", defaults.compactStyle, AgentNotchCompactStyle.allCases.map { ($0, $0.title) }, 3) { NotchCompactStylePicture(style: $0) }
                    row("Click action", defaults.clickAction, AgentNotchClickAction.allCases.map { ($0, $0.title) }, 2) { NotchClickActionPicture(action: $0) }
                    row("Agent card shows", defaults.agentCard, NotchAgentCard.allCases.map { ($0, $0.title) }, 2) { NotchAgentCardPicture(card: $0) }
                    row("Start on", defaults.shelfPages.start, NotchShelfStartPage.allCases.map { ($0, $0.title) }, 5) { NotchStartPagePicture(start: $0) }
                    row("Left", defaults.shelfLeadingWidget, NotchShelfSlot.allCases.map { ($0, $0.title) }, 4) { NotchSlotPicture(slot: $0) }
                    row("Music style", defaults.musicStyle, NotchMusicStyle.allCases.map { ($0, $0.title) }, 2) { NotchMusicStylePicture(style: $0) }
                }
                .padding(16).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("notch-\(name).png"))
            }
            // The Settings pane as a first visit sees it: every group folded.
            for shelf in [false, true] {
                let model = DockModel()
                // Saves under CFFIXED_USER_HOME, which the fixture requires to be in /tmp.
                model.setShowAgentNotch(true)
                model.updateAgentNotch { $0.shelfEnabled = shelf }
                let pane = AgentNotchSettingsView(model: model).formStyle(.grouped).frame(width: 560, height: 820)
                let hosting = NSHostingView(rootView: pane)
                hosting.appearance = NSAppearance(named: .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 820)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("notch-settings-pane\(shelf ? "-shelf" : "").png"))
            }
            print("Rendered notch previews to \(directory)")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }
}
#endif
