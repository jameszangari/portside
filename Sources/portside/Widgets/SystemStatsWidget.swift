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
                ZStack {
                    ring(value(metric), metric.color, line: tile * 0.085)
                    if tile >= 28 {
                        Text("\(Int((value(metric) * 100).rounded()))")
                            .font(.system(size: WidgetTypography.fontSize(11, tile: tile), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.7)
                    } else {
                        Image(systemName: metric == .cpu ? "cpu" : "memorychip")
                            .font(.system(size: WidgetTypography.fontSize(11, tile: tile)))
                    }
                }
                .padding(tile * 0.08)
            } else if size == .small {
                rings.padding(tile * 0.08)
            } else {
                HStack(spacing: tile * 0.12) {
                    rings.frame(width: tile * 0.65, height: tile * 0.65)
                    legend
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

    /// Two-column legend so CPU / RAM values share one vertical number column.
    private var legend: some View {
        let labelSize = WidgetTypography.fontSize(8, tile: tile)
        let valueSize = WidgetTypography.fontSize(10, tile: tile)
        return Grid(alignment: .leading, horizontalSpacing: tile * 0.05, verticalSpacing: tile * 0.06) {
            GridRow {
                Text(StatsMetric.cpu.label)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(Int((cpu * 100).rounded()))")
                    .font(.system(size: valueSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StatsMetric.cpu.color)
                    .gridColumnAlignment(.trailing)
            }
            GridRow {
                Text(StatsMetric.memory.label)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(Int((memory * 100).rounded()))")
                    .font(.system(size: valueSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StatsMetric.memory.color)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
