import AppKit
import IOKit.ps
import SwiftUI
import os.log

/// Battery percent and charging state. Event-driven via IOKit's
/// power-source notification; the slow timer is only a fallback.
final class BatteryWidget: DockWidget {
    static let kind = "battery"
    let name = "Battery"
    var hoverTitle: String {
        guard let percent else { return "Battery · Unavailable" }
        return "Battery \(percent)%" + (isCharging ? " · Charging" : onAC ? " · Plugged in" : "")
    }
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

    private var color: Color {
        guard let percent else { return .secondary }
        return Self.scaleColor(Double(min(max(percent, 0), 100)) / 100)
    }

    /// Red at 0, amber at 0.5, green at 1, blended linearly in RGB between stops.
    private static func scaleColor(_ t: Double) -> Color {
        let red = (r: 0.93, g: 0.23, b: 0.20)
        let amber = (r: 1.00, g: 0.72, b: 0.10)
        let green = (r: 0.20, g: 0.78, b: 0.35)
        let (from, to, f) = t < 0.5 ? (red, amber, t / 0.5) : (amber, green, (t - 0.5) / 0.5)
        return Color(
            red: from.r + (to.r - from.r) * f,
            green: from.g + (to.g - from.g) * f,
            blue: from.b + (to.b - from.b) * f
        )
    }

    /// Same compact threshold as CPU / Memory gauges: icon instead of digits.
    private var symbolName: String {
        if isCharging || onAC { return "battery.100percent.bolt" }
        switch percent ?? 0 {
        case 76...: return "battery.100percent"
        case 51..<76: return "battery.75percent"
        case 26..<51: return "battery.50percent"
        case 1..<26: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var body: some View {
        WidgetTile(size: .small) {
            RingGauge(
                value: Double(percent ?? 0) / 100,
                color: color,
                trackColor: Color.primary.opacity(0.15),
                number: percent,
                symbol: symbolName,
                fullSymbol: "battery.100percent",
                // Charging shows as a bolt in the tile's corner, clear of
                // the ring and the number.
                cornerSymbol: isCharging || onAC ? "bolt.fill" : nil
            )
        }
    }
}
