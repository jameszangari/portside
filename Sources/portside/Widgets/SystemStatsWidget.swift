import AppKit
import Darwin
import SwiftUI

/// CPU and memory usage from Mach host statistics (public APIs).
final class SystemStatsWidget: DockWidget {
    static let kind = "systemStats"
    let name = "System Stats"
    let icon = Image(systemName: "cpu")
    let size = WidgetSize.medium
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
        StatsView(cpu: cpu, memory: memory)
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

private struct StatsView: View {
    let cpu: Double
    let memory: Double
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        WidgetTile(size: .medium) {
            VStack(alignment: .leading, spacing: tile * 0.08) {
                row("CPU", cpu, .blue)
                row("MEM", memory, .purple)
            }
            .padding(.horizontal, tile * 0.16)
        }
    }

    private func row(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: tile * 0.08) {
            Text(label)
                .font(.system(size: tile * 0.17, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: tile * 0.42, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color).frame(width: geo.size.width * value)
                }
            }
            .frame(height: tile * 0.1)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: tile * 0.17, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: tile * 0.5, alignment: .trailing)
        }
        .lineLimit(1)
    }
}
