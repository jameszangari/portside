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
            for name in ["compact", "attached", "expanded", "large-text", "minimal", "shelf-agents", "shelf-widgets"] {
                let state = AgentNotchPresentation()
                state.preferences.animate = false
                state.expanded = name != "compact" && name != "attached"
                if name == "attached" { state.topAttached = true; state.headerHeight = 32 }
                if name.hasPrefix("shelf") {
                    state.preferences.shelfEnabled = true
                    state.showPage(name == "shelf-agents" ? .agents : .widgets)
                    // Not started: no network or player queries, only each widget's empty state.
                    let hosts = state.preferences.shelfWidgets.compactMap { WidgetCatalog.make($0).map(WidgetHost.init(widget:)) }
                    state.widgetHost = { kind in hosts.first { $0.id == kind } }
                }
                state.preferences.showUsage = false
                if name == "large-text" { state.preferences.fontSize = 16; state.preferences.expandedWidth = 340 }
                if name == "minimal" { state.preferences.compactStyle = .minimal; state.preferences.providerColors = false; state.preferences.showTotal = false }
                let width = state.expanded ? state.preferences.expandedWidth : state.preferences.compactWidth
                state.panelWidth = width
                let content = state.preferences.shelfEnabled
                    ? AgentNotchView.shelfHeight(page: state.currentPage, preferences: state.preferences, sessionCount: agents.sessions.count,
                                                 width: width, natural: { state.widgetHost($0)?.size ?? .small })
                    : AgentNotchView.dashboardHeight(preferences: state.preferences, sessionCount: agents.sessions.count)
                let height = state.headerHeight + (state.expanded ? content : 0)
                let view = AgentNotchView(agents: agents, usage: nil, nowPlaying: nil, state: state).frame(width: width, height: height)
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
            print("Rendered notch previews to \(directory)")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }
}
#endif
