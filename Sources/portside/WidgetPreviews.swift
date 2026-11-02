#if DEBUG
import AppKit
import SwiftUI

/// `portside --render-widget-previews <dir>` (debug builds only): renders
/// the Now Playing, Agents and AI Usage tiles with sample data to PNGs, so
/// layout changes can be checked without hovering the dock.
enum WidgetPreviews {
    @MainActor
    static func render(to directory: String) -> Int32 {
        // DockLabel's background reads NSApp for the appearance.
        _ = NSApplication.shared
        let art = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(starting: .systemRed, ending: .systemPurple)?.draw(in: rect, angle: 45)
            return true
        }
        let player = NowPlayingWidget.players[0]
        let track = NowPlayingWidget.Track(id: "1", title: "Ya Dig", artist: "Young Nudy", artwork: art,
                                           artworkURL: nil, isPlaying: true, player: player)
        let claude = AgentProvider.named("claude"), codex = AgentProvider.named("codex"), copilot = AgentProvider.named("copilot")
        let usage = [
            ProviderUsage(provider: claude, windows: [UsageWindow(label: "5h", percent: 79, resetsAt: nil),
                                                      UsageWindow(label: "7d", percent: 71, resetsAt: nil)], note: nil),
            ProviderUsage(provider: codex, windows: [UsageWindow(label: "5h", percent: 12, resetsAt: nil),
                                                     UsageWindow(label: "7d", percent: 30, resetsAt: nil)], note: nil),
            ProviderUsage(provider: copilot, windows: [UsageWindow(label: "Prem", percent: 45, resetsAt: nil)], note: nil),
        ]
        let clock = ClockWidget(), stats = SystemStatsWidget()
        clock.refresh(); stats.refresh()
        let agentsDone = AgentSummary(provider: claude, running: 0, done: 1, projects: ["my-project"], hosts: ["T3 Code"])
        let agentsWorking = AgentSummary(provider: claude, running: 2, done: 1, projects: ["my-project", "t3code"], hosts: ["T3 Code", "Terminal"])
        let rows: [(String, [WidgetSize], (WidgetSize) -> AnyView)] = [
            ("Clock", [.small, .medium], { _ in AnyView(clock.body) }),
            ("System Stats", [.small, .medium], { _ in AnyView(stats.body) }),
            ("Now Playing", [.small, .medium, .large], { _ in AnyView(NowPlayingView(track: track) { _ in }) }),
            ("Agents done", [.small, .medium], { _ in AnyView(AgentStatusView(summary: agentsDone)) }),
            ("Agents working", [.small, .medium], { _ in AnyView(AgentStatusView(summary: agentsWorking)) }),
            ("AI Usage x3", [.small, .medium, .large], { _ in AnyView(UsageView(usage: usage)) }),
            ("AI Usage x2", [.small, .medium, .large], { _ in AnyView(UsageView(usage: Array(usage.prefix(2)))) }),
            ("Copilot x1", [.small, .medium, .large], { _ in AnyView(UsageView(usage: [usage[2]])) }),
            ("AI Usage x1", [.small, .medium, .large], { _ in AnyView(UsageView(usage: [usage[0]])) }),
            ("Label short", [.small], { _ in AnyView(DockLabel(title: "Safari", pointing: .bottom)) }),
            ("Label usage", [.small], { _ in AnyView(DockLabel(title: "Claude 26% · 87%   Codex 12% · 38%   Copilot 0% · 0%", pointing: .bottom)) }),
            ("Label notes", [.small], { _ in AnyView(DockLabel(title: "Claude: Open Claude Code to refresh its sign-in   Codex: No recent Codex usage   Copilot: Sign in to Copilot CLI or GitHub CLI", pointing: .bottom)) }),
            ("Label long", [.small], { _ in AnyView(DockLabel(title: "quarterly-financial-report-final-revised-version-2026-with-all-appendices-and-speaker-notes.pdf", pointing: .bottom)) }),
            ("Label endless", [.small], { _ in AnyView(DockLabel(title: String(repeating: "very-long-file-name-", count: 30) + "end.pdf", pointing: .bottom)) }),
        ]
        for tile: CGFloat in [32, 48, 64] {
            let sheet = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        ForEach(row.1) { size in
                            row.2(size)
                                .environment(\.dockTileSize, tile)
                                .environment(\.widgetSize, size)
                        }
                    }
                }
            }
            .padding(8)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("widgets-\(Int(tile)).png"))
        }
        print("rendered to \(directory)")
        return 0
    }
}
#endif
