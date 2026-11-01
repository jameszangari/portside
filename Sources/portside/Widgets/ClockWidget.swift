import AppKit
import SwiftUI

/// Time and date. Refreshes on each wall-clock minute.
final class ClockWidget: DockWidget {
    static let kind = "clock"
    let name = "Clock"
    var hoverTitle: String { now.formatted(.dateTime.weekday(.wide).month().day().hour().minute()) }
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
    @Environment(\.widgetSize) private var chosen

    var body: some View {
        let size = WidgetSize.resolved(chosen, natural: .medium)
        WidgetTile(size: size) {
            if size == .small {
                AnalogClockFace(now: now)
                    .padding(tile * 0.12)
            } else {
                VStack(spacing: tile * 0.02) {
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(size: WidgetTypography.fontSize(11, tile: tile), weight: .medium))
                        .monospacedDigit()
                    if tile >= 48 {
                        Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(.system(size: WidgetTypography.fontSize(6.5, tile: tile)))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }
}

/// Square design: an analog face (hour ticks, hour and minute hands), like
/// the small iOS clock widget. Redrawn each minute with the widget.
private struct AnalogClockFace: View {
    let now: Date

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func point(_ fraction: Double, _ length: CGFloat) -> CGPoint {
                let angle = fraction * 2 * .pi
                return CGPoint(x: center.x + sin(angle) * length, y: center.y - cos(angle) * length)
            }
            for hour in 0..<12 {
                let major = hour % 3 == 0
                var tick = Path()
                tick.move(to: point(Double(hour) / 12, radius * (major ? 0.74 : 0.84)))
                tick.addLine(to: point(Double(hour) / 12, radius * 0.96))
                context.stroke(tick, with: .color(.primary.opacity(major ? 0.7 : 0.35)),
                               style: StrokeStyle(lineWidth: radius * (major ? 0.08 : 0.05), lineCap: .round))
            }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
            let minute = Double(parts.minute ?? 0)
            let hour = Double((parts.hour ?? 0) % 12) + minute / 60
            var hourHand = Path()
            hourHand.move(to: center)
            hourHand.addLine(to: point(hour / 12, radius * 0.48))
            context.stroke(hourHand, with: .color(.primary), style: StrokeStyle(lineWidth: radius * 0.12, lineCap: .round))
            var minuteHand = Path()
            minuteHand.move(to: center)
            minuteHand.addLine(to: point(minute / 60, radius * 0.74))
            context.stroke(minuteHand, with: .color(.primary), style: StrokeStyle(lineWidth: radius * 0.08, lineCap: .round))
            let dot = radius * 0.1
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)),
                         with: .color(.orange))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(now.formatted(.dateTime.hour().minute()))
    }
}
