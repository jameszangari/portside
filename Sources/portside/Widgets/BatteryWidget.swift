import AppKit
import IOKit.ps
import SwiftUI
import os.log

/// Battery percent and charging state. Event-driven via IOKit's
/// power-source notification; the slow timer is only a fallback.
final class BatteryWidget: DockWidget {
    static let kind = "battery"
    let name = "Battery"
    let icon = Image(systemName: "battery.75percent")
    let size = WidgetSize.small
    let refreshInterval: TimeInterval = 300

    @Published private(set) var percent: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var onAC = false

    private var runLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryWidget>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let newPercent = Int((Double(current) / Double(max) * 100).rounded())
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let ac = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if newPercent != percent || charging != isCharging || ac != onAC {
                percent = newPercent
                isCharging = charging
                onAC = ac
                logger.info("battery \(newPercent)% charging=\(charging) ac=\(ac)")
            }
            return
        }
    }

    func activate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        BatteryView(percent: percent, isCharging: isCharging, onAC: onAC)
    }
}

private struct BatteryView: View {
    let percent: Int?
    let isCharging: Bool
    let onAC: Bool
    @Environment(\.dockTileSize) private var tile

    private var color: Color {
        guard let percent else { return .secondary }
        if isCharging || onAC { return .green }
        return percent <= 20 ? .red : .primary
    }

    var body: some View {
        WidgetTile(size: .small) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: tile * 0.08)
                Circle()
                    .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: tile * 0.08, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    if isCharging || onAC {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: tile * 0.16))
                            .foregroundStyle(.green)
                    }
                    Text(percent.map { "\($0)" } ?? "--")
                        .font(.system(size: tile * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .padding(tile * 0.12)
        }
    }
}
