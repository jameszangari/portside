import AppKit
import Darwin
import SwiftUI

/// CPU and memory usage from Mach host statistics (public APIs).
class SystemStatsWidget: DockWidget {
    class var kind: String { "systemStats" }
    var name: String { "System Stats" }
    var hoverTitle: String {
        let cpuText = "CPU \(Int((cpu * 100).rounded()))%"
        let memoryText = "Memory \(Int((memory * 100).rounded()))%"
        if metric == .cpu { return cpuText }
        if metric == .memory { return memoryText }
        return "\(cpuText) · \(memoryText)"
    }
    let icon = Image(systemName: "cpu")
    var size: WidgetSize { .medium }
    fileprivate var metric: StatsMetric? { nil }
    let refreshInterval: TimeInterval = 3

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0

    private var previousTicks: (busy: UInt64, total: UInt64)?

    func refresh() {
        if let ticks = SystemStatsWidget.cpuTicks() {
            if let previous = previousTicks, ticks.total > previous.total {
                cpu = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
            }
            previousTicks = ticks
        }
        if let mem = SystemStatsWidget.memoryUsage() {
            memory = mem
        }
    }

    func activate() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    var body: some View {
        StatsView(cpu: cpu, memory: memory, metric: metric)
    }

    // MARK: - Mach

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Roughly what Activity Monitor calls "Memory Used": app + wired + compressed.
    private static func memoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = Double(vm_kernel_page_size)
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
        return min(max(used / Double(ProcessInfo.processInfo.physicalMemory), 0), 1)
    }
}

/// Optional single-metric tiles use the same public sampling and click action.
final class CPUWidget: SystemStatsWidget {
    override class var kind: String { "cpu" }
    override var name: String { "CPU" }
    override var size: WidgetSize { .small }
    fileprivate override var metric: StatsMetric? { .cpu }
}

final class MemoryWidget: SystemStatsWidget {
    override class var kind: String { "memory" }
    override var name: String { "Memory" }
    override var size: WidgetSize { .small }
    fileprivate override var metric: StatsMetric? { .memory }
}

fileprivate enum StatsMetric {
    case cpu, memory

    var label: String { self == .cpu ? "CPU" : "RAM" }
    var color: Color {
        self == .cpu
            ? Color(red: 0.2, green: 0.72, blue: 1)
            : Color(red: 0.86, green: 0.45, blue: 1)
    }
}

private struct StatsView: View {
    let cpu: Double
    let memory: Double
    let metric: StatsMetric?
    @Environment(\.dockTileSize) private var tile
    @Environment(\.widgetSize) private var chosen

    var body: some View {
        let size = metric == nil ? WidgetSize.resolved(chosen, natural: .medium) : .small
        WidgetTile(size: size) {
            if let metric {
                RingGauge(
                    value: value(metric),
                    color: metric.color,
                    number: Int((value(metric) * 100).rounded()),
                    symbol: metric == .cpu ? "cpu" : "memorychip",
                    fullSymbol: metric == .cpu ? "cpu.fill" : "memorychip.fill"
                )
            } else if size == .small {
                rings.padding(tile * 0.08)
            } else {
                HStack(spacing: tile * 0.1) {
                    rings.frame(width: tile * 0.62, height: tile * 0.62)
                    // Legend rows keep air above and below, like the rings.
                    GeometryReader { geo in
                        legend(in: CGSize(width: geo.size.width, height: geo.size.height * 0.8))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .padding(.horizontal, tile * 0.09)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.map { $0 == .cpu ? "CPU usage" : "Memory used" } ?? "System Stats")
        .accessibilityValue(metric.map { percent(value($0)) } ?? "CPU \(percent(cpu)), memory \(percent(memory))")
    }

    private func value(_ metric: StatsMetric) -> Double { metric == .cpu ? cpu : memory }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private var rings: some View {
        let line = tile * 0.075
        return ZStack {
            ring(cpu, StatsMetric.cpu.color, line: line)
            ring(memory, StatsMetric.memory.color, line: line)
                .padding(line + tile * 0.035)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ring(_ value: Double, _ color: Color, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(line / 2)
    }

    /// Two-column legend so CPU / RAM values share one vertical number
    /// column. Font sizes come from measured text widths so the legend fits
    /// its space at every tile size: never truncated, never squeezed. The
    /// value column is sized for "100" so it does not jump at full load.
    private func legend(in space: CGSize) -> some View {
        let metrics = LegendMetrics(space: space, tile: tile)
        return Grid(alignment: .leading, horizontalSpacing: metrics.columnSpacing, verticalSpacing: metrics.rowSpacing) {
            ForEach([StatsMetric.cpu, .memory], id: \.label) { metric in
                GridRow {
                    Text(metric.label)
                        .font(.system(size: metrics.labelSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text("\(Int((value(metric) * 100).rounded()))")
                        .font(.system(size: metrics.valueSize, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(metric.color)
                        .fixedSize()
                        .frame(width: metrics.valueWidth, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .frame(width: space.width, height: space.height, alignment: .trailing)
    }
}

/// Font sizes for the System Stats legend, scaled down from the 32pt-tile
/// design sizes only as far as needed to fit `space`.
private struct LegendMetrics {
    let labelSize: CGFloat
    let valueSize: CGFloat
    let valueWidth: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat

    init(space: CGSize, tile: CGFloat) {
        let label = WidgetTypography.fontSize(8, tile: tile)
        let value = WidgetTypography.fontSize(10, tile: tile)
        let column = tile * 0.06
        let row = tile * 0.06
        let width = Self.width(of: [StatsMetric.cpu.label, StatsMetric.memory.label], size: label, weight: .medium, digits: false)
            + column
            + Self.width(of: ["100"], size: value, weight: .semibold, digits: true)
        let height = 2 * NSFont.systemFont(ofSize: value).boundingRectForFont.height * 0.82 + row
        let scale = min(1, space.width / max(width, 1), space.height / max(height, 1))
        labelSize = label * scale
        valueSize = value * scale
        columnSpacing = column * scale
        rowSpacing = row * scale
        valueWidth = Self.width(of: ["100"], size: valueSize, weight: .semibold, digits: true)
    }

    /// Widest of `strings` in the system font (monospaced digits for
    /// numbers), rounded up so SwiftUI's own measure never comes out wider.
    static func width(of strings: [String], size: CGFloat, weight: NSFont.Weight, digits: Bool) -> CGFloat {
        let font = digits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let widest = strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return widest.rounded(.up) + 1
    }
}
