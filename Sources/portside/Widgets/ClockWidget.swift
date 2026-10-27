import AppKit
import SwiftUI

/// Time and date. Refreshes on each wall-clock minute.
final class ClockWidget: DockWidget {
    static let kind = "clock"
    let name = "Clock"
    let icon = Image(systemName: "clock")
    let size = WidgetSize.medium
    let refreshInterval: TimeInterval = 60
    let alignsRefreshToInterval = true

    @Published private(set) var now = Date()

    func refresh() {
        now = Date()
    }

    func activate() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    var body: some View {
        ClockView(now: now)
    }
}

private struct ClockView: View {
    let now: Date
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        WidgetTile(size: .medium) {
            VStack(spacing: 0) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: tile * 0.34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: tile * 0.2, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }
}
