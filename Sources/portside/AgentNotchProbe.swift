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
            let legacy = try decoder.decode(AgentNotchSettings.self, from: Data(#"{"position":"left","shelfEnabled":false,"animate":false,"showTotal":false,"showUsage":false}"#.utf8))
            try require(!legacy.animate && !legacy.showUsage, "Preferences must survive retired keys beside them")
            let invalid = try decoder.decode(AgentNotchSettings.self, from: Data(#"{"display":"bad","compactWidth":9999,"opacity":-1,"fontSize":100,"maxSessions":0,"shelfCollapseDelay":-2}"#.utf8))
            try require(invalid.display == .automatic && invalid.compactWidth == 280
                        && invalid.opacity == 0.75 && invalid.fontSize == 16 && invalid.maxSessions == 2 && invalid.shelfCollapseDelay == 0.1,
                        "Invalid values must be bounded")
            var custom = AgentNotchSettings()
            custom.display = .all
            custom.filter = .attention; custom.expandedWidth = 550; custom.fontSize = 15; custom.maxSessions = 9
            custom.showProject = false; custom.showHost = false; custom.showUpdated = false; custom.providerColors = false
            custom.claude = false; custom.codex = false; custom.copilot = false
            custom.opencode = false; custom.cursor = false
            custom.showBorder = true; custom.collapseAfterFocus = false
            custom.accent.hue = 0.25
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
            state.preferences.shelfHoverDelay = 0
            state.shelfPointer(.notch)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            try require(state.expanded, "Hover on the notch opens the shelf")
            state.preferences.shelfCollapseDelay = 0.01
            state.setPinned(true); state.shelfPointer(.outside)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            try require(state.expanded, "Pin keeps the shelf open")
            state.setPinned(false); state.shelfPointer(.outside)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            try require(!state.expanded, "Unpinned, leaving closes")
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
            let shelfVariants = ["shelf-agents", "shelf-widgets", "shelf-clipboard", "shelf-clipboard-search", "shelf-files-empty", "shelf-files", "shelf-airpods", "strip-music", "strip-narrow", "strip-solo", "strip-hud", "card-banner", "card-music", "card-vinyl", "card-agents", "card-meeting", "card-meeting-live", "card-battery", "card-airpods"]
            for name in shelfVariants {
                let state = AgentNotchPresentation()
                state.preferences.animate = false
                state.expanded = name.hasPrefix("shelf")
                state.topAttached = true; state.headerHeight = 32; state.notchWidth = 180
                do {
                    state.preferences.shelfHoverDelay = 0
                    state.preferences.musicStyle = name == "card-vinyl" ? .vinyl : .music
                    state.preferences.musicTint = name == "card-vinyl"
                    state.compactWidth = (name == "strip-narrow" ? 100 : 184) + 180 + 2 * NotchShape.flare
                    state.strip = name == "card-agents" ? NotchShelfStrip.layout(music: false, agents: true, agentAlert: false)
                        : NotchShelfStrip.layout(music: true, agents: true, agentAlert: false)
                    if name.hasPrefix("card-meeting") {
                        // Live: 12 minutes into a 30-minute meeting, its timer running.
                        let start = Date().addingTimeInterval(name == "card-meeting-live" ? -725 : 240)
                        state.meeting = CalendarWidget.NextEvent(title: "Design review", start: start, isAllDay: false, color: .orange,
                                                                 end: start.addingTimeInterval(1800), meeting: URL(string: "https://meet.google.com/abc-defg-hij"))
                        state.strip = NotchShelfStrip.layout(active: [.meeting, .music], alert: nil)
                    }
                    if name == "strip-solo" { state.strip = NotchShelfStrip.layout(active: [.music], alert: nil) }
                    if name == "card-banner" { state.showBanner() }
                    if name == "strip-hud" {
                        // A 140 pt strip, as layoutPanels widens it for the HUD.
                        state.hud = NotchHUD(kind: .volume, level: 0.4)
                        state.compactWidth = max(140 + 180 + 2 * NotchShape.flare, NotchHUD.stripWidth(notch: 180, flare: 2 * NotchShape.flare))
                    }
                    if name == "card-battery" {
                        state.alert = NotchShelfAlert(activity: .battery, symbol: "battery.25percent", short: "18%",
                                                      title: "Low battery", detail: "18% left. Plug in soon.", isWarning: true)
                        state.strip = NotchShelfStrip.layout(active: [.music], alert: .battery)
                    }
                    if name == "card-airpods" {
                        let pair = AirPodsReading(address: "probe", name: "James's AirPods Pro", productID: 0x2014, left: 80, right: 15, case: 62)
                        state.alert = NotchShelfAlert(activity: .airPods, symbol: pair.symbol, short: "15%", title: pair.name,
                                                      detail: pair.detail, parts: pair.parts)
                        state.strip = NotchShelfStrip.layout(active: [.music], alert: .airPods)
                    }
                    if name.hasPrefix("shelf") {
                        state.pageAvailable = { _ in true }
                        state.showPage(name == "shelf-agents" ? .agents : name.hasPrefix("shelf-clipboard") ? .clipboard
                                       : name.hasPrefix("shelf-files") ? .files : name == "shelf-airpods" ? .airPods : .widgets)
                        if name.hasPrefix("shelf-files") {
                            // Files that exist on every Mac, so the icons are real. Never saved.
                            NotchFileShelf.shared.preview(name == "shelf-files-empty" ? [] : [
                                "/System/Applications/TextEdit.app", "/System/Library/CoreServices/Finder.app",
                                "/etc/hosts", "/System/Library/Desktop Pictures", "/usr/share/dict/words",
                            ].map { URL(fileURLWithPath: $0) })
                        }
                        if name == "shelf-airpods" {
                            state.airPods = [AirPodsReading(address: "probe", name: "James's AirPods Pro", productID: 0x2014, left: 80, right: 15, case: 62),
                                             AirPodsReading(address: "probe-max", name: "AirPods Max", productID: 0x201F, single: 90)]
                        }
                        if name == "shelf-clipboard-search" {
                            state.hotkey(page: .clipboard, search: true)
                            state.query = "swift"
                        }
                        if name.hasPrefix("shelf-clipboard") {
                            ClipboardService.shared.preview(["https://github.com/jameszangari/portside/pull/74", "swift build && swift test",
                                                             "Meeting moved to 3 pm, same room", "let width = min(screen.frame.width - 24, 600)",
                                                             "me@example.com"].enumerated().map {
                                ClipboardEntry(text: $1, date: Date().addingTimeInterval(-Double($0) * 300))
                            })
                        }
                    }
                    // Not started: no network or calendar queries, only each card's empty state.
                    let hosts = [WeatherWidget.kind, CalendarWidget.kind].compactMap { WidgetCatalog.make($0).map(WidgetHost.init(widget:)) }
                    state.widgetHost = { kind in hosts.first { $0.id == kind } }
                    if name.hasPrefix("card"), name != "card-banner" {
                        state.panelWidth = state.preferences.expandedWidth + 2 * NotchShape.flare
                        state.shelfPointer(.side(name == "card-battery" || name == "card-airpods" ? .trailing : .leading))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                }
                state.preferences.showUsage = false
                let width = state.expanded ? AgentNotch.shelfOpenWidth
                    : state.card != nil && !state.banner ? state.preferences.expandedWidth + 2 * NotchShape.flare
                    : state.compactWidth
                state.panelWidth = width
                let content = AgentNotchView.shelfHeight(page: state.currentPage, preferences: state.preferences, sessionCount: agents.sessions.count,
                                                         chips: AgentNotchView.providerChips(agents.sessions).count > 1,
                                                         clipboard: (ClipboardService.shared.entries.count, false), searching: state.searching,
                                                         files: NotchFileShelf.shared.items.count, airPods: state.airPods.count)
                let card = state.banner ? AgentNotchView.bannerHeight
                    : state.card.map { AgentNotchView.cardHeight($0, preferences: state.preferences, sessionCount: agents.sessions.count) } ?? 0
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
            // The Settings pane as a first visit sees it: every group folded.
            do {
                let model = DockModel()
                // Saves under CFFIXED_USER_HOME, which the fixture requires to be in /tmp.
                model.setShowAgentNotch(true)
                let pane = AgentNotchSettingsView(model: model).formStyle(.grouped).frame(width: 560, height: 820)
                let hosting = NSHostingView(rootView: pane)
                hosting.appearance = NSAppearance(named: .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 820)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("notch-settings-pane.png"))
                }
            }
            // The Settings preview in each scene a section points it at.
            let scenes: [(String, NotchPreviewScene)] = [("strip", .strip), ("volume", .volume), ("music", .card(.music)),
                                                         ("alert", .card(.airPods)), ("widgets", .page(.widgets)),
                                                         ("agents", .page(.agents)), ("files", .page(.files))]
            for (name, scene) in scenes {
                let preview = NotchSettingsPreview(preferences: AgentNotchSettings(), scene: scene).frame(width: 520).padding(10)
                let hosting = NSHostingView(rootView: preview)
                hosting.appearance = NSAppearance(named: .aqua)
                hosting.frame = NSRect(origin: .zero, size: NSSize(width: 540, height: 400))
                // In a window, so onAppear runs and the sample is applied.
                let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = hosting
                window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                window.orderFrontRegardless()
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                defer { window.orderOut(nil) }
                hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("notch-settings-preview-\(name).png"))
                }
            }
            print("Rendered notch previews to \(directory)")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }
}
#endif
