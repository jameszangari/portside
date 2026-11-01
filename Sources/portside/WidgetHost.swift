import Combine
import SwiftUI
import os.log

private let widgetLogger = Logger(subsystem: "com.james.portside", category: "Widgets")

/// Owns one widget's lifecycle and its refresh timer. These timers are off
/// the reveal/hide path: they only update widget state.
final class WidgetHost: Identifiable {
    let widget: any DockWidget
    private var timer: Timer?

    var id: String { widget.id }

    init(widget: any DockWidget) {
        self.widget = widget
    }

    func start() {
        widget.start()
        widget.refresh()
        let interval = widget.refreshInterval
        guard interval > 0 else { return }

        var firstFire = Date().addingTimeInterval(interval)
        if widget.alignsRefreshToInterval {
            let now = Date().timeIntervalSinceReferenceDate
            firstFire = Date(timeIntervalSinceReferenceDate: (now / interval).rounded(.down) * interval + interval + 0.05)
        }
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
            self?.widget.refresh()
        }
        // Lets macOS coalesce wakeups; widgets do not need exact timing.
        timer.tolerance = min(interval * 0.1, 1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        widgetLogger.info("started \(self.id, privacy: .public), refresh every \(interval, format: .fixed(precision: 0))s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        widget.stop()
        widgetLogger.info("stopped \(self.id, privacy: .public)")
    }

    var size: WidgetSize { widget.size }

    /// Opens the existential so SwiftUI gets the concrete view type.
    var view: AnyView { WidgetHost.makeView(widget) }

    private static func makeView<W: DockWidget>(_ widget: W) -> AnyView {
        AnyView(WidgetContainer(widget: widget))
    }
}

/// Observes the widget object so only this subtree re-renders on refresh.
private struct WidgetContainer<W: DockWidget>: View {
    @ObservedObject var widget: W

    var body: some View {
        widget.body
            .dockHoverTarget(id: "widget:" + widget.id, title: widget.hoverTitle)
            .contentShape(Rectangle())
            .onTapGesture { widget.activate() }
    }
}

/// All available widgets, in default display order.
enum WidgetCatalog {
    static let factories: [(kind: String, make: () -> any DockWidget)] = [
        (ClockWidget.kind, { ClockWidget() }),
        (CalendarWidget.kind, { CalendarWidget() }),
        (WeatherWidget.kind, { WeatherWidget() }),
        (SystemStatsWidget.kind, { SystemStatsWidget() }),
        (BatteryWidget.kind, { BatteryWidget() }),
        (CPUWidget.kind, { CPUWidget() }),
        (MemoryWidget.kind, { MemoryWidget() }),
    ]

    static var allKinds: [String] { factories.map(\.kind) }

    static var defaultKinds: [String] {
        allKinds.filter { $0 != CPUWidget.kind && $0 != MemoryWidget.kind }
    }

    static func make(_ kind: String) -> (any DockWidget)? {
        factories.first { $0.kind == kind }?.make()
    }

    /// A widget's own (widest) design.
    static func naturalSize(_ kind: String) -> WidgetSize {
        make(kind)?.size ?? .small
    }

    /// Name and icon for menus, without keeping an instance around.
    static func info(_ kind: String) -> (name: String, icon: Image)? {
        guard let widget = make(kind) else { return nil }
        return (widget.name, widget.icon)
    }
}

/// Keeps running hosts in sync with `DockModel.widgetKinds`: starts hosts
/// for added widgets, stops hosts for removed ones.
final class WidgetStore: ObservableObject {
    @Published private(set) var hosts: [WidgetHost] = []
    private var cancellable: AnyCancellable?

    init(dockModel: DockModel) {
        cancellable = dockModel.$widgetKinds.sink { [weak self] kinds in
            self?.sync(kinds)
        }
    }

    private func sync(_ kinds: [String]) {
        var next: [WidgetHost] = []
        for kind in kinds {
            if let existing = hosts.first(where: { $0.id == kind }) {
                next.append(existing)
            } else if let widget = WidgetCatalog.make(kind) {
                let host = WidgetHost(widget: widget)
                host.start()
                next.append(host)
            }
        }
        for old in hosts where !next.contains(where: { $0.id == old.id }) {
            old.stop()
        }
        hosts = next
    }

    func stopAll() {
        hosts.forEach { $0.stop() }
    }
}
