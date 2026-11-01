import AppKit
import EventKit
import SwiftUI
import os.log

/// Today's date plus the next event in the coming 24 hours. Calendar access
/// is only requested when the user clicks the widget, never on launch.
final class CalendarWidget: DockWidget {
    static let kind = "calendar"
    let name = "Calendar"
    var hoverTitle: String {
        let date = today.formatted(.dateTime.weekday(.wide).month().day())
        switch access {
        case .unknown: return "\(date) · Click to connect Calendar"
        case .denied: return "\(date) · Calendar access denied"
        case .granted:
            guard let next else { return "\(date) · No upcoming events" }
            let time = next.isAllDay ? "All day" : next.start.formatted(.dateTime.hour().minute())
            return "\(date) · \(next.title) · \(time)"
        }
    }
    let icon = Image(systemName: "calendar")
    let size = WidgetSize.medium
    let refreshInterval: TimeInterval = 60
    let alignsRefreshToInterval = true

    struct NextEvent: Equatable {
        var title: String
        var start: Date
        var isAllDay: Bool
        var color: Color
    }

    enum Access { case unknown, granted, denied }

    @Published private(set) var today = Date()
    @Published private(set) var next: NextEvent?
    @Published private(set) var access: Access = .unknown

    private var store: EKEventStore?
    private var changeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    func start() {
        updateAccess()
    }

    func stop() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
    }

    func refresh() {
        today = Date()
        guard access == .granted, let store else {
            next = nil
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { lhs, rhs in
                // Timed events first, all-day events only if nothing else.
                if lhs.isAllDay != rhs.isAllDay { return !lhs.isAllDay }
                return lhs.startDate < rhs.startDate
            }
        next = upcoming.first.map {
            NextEvent(title: $0.title ?? "Untitled", start: $0.startDate, isAllDay: $0.isAllDay,
                      color: Color(nsColor: $0.calendar?.color ?? .systemRed))
        }
    }

    func activate() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            logger.info("calendar: requesting access")
            EKEventStore().requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.logger.info("calendar: access granted=\(granted) error=\(error?.localizedDescription ?? "none", privacy: .public)")
                    self?.updateAccess()
                }
            }
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            if store == nil {
                let store = EKEventStore()
                self.store = store
                changeObserver = NotificationCenter.default.addObserver(
                    forName: .EKEventStoreChanged, object: store, queue: .main
                ) { [weak self] _ in self?.refresh() }
            }
        case .notDetermined:
            access = .unknown
        default:
            access = .denied
        }
        refresh()
    }

    var body: some View {
        CalendarView(today: today, next: next, access: access)
    }
}

private struct CalendarView: View {
    let today: Date
    let next: CalendarWidget.NextEvent?
    let access: CalendarWidget.Access
    @Environment(\.dockTileSize) private var tile
    @Environment(\.widgetSize) private var chosen

    var body: some View {
        if WidgetSize.resolved(chosen, natural: .medium) == .small {
            square
        } else {
            wide
        }
    }

    private var dateFace: some View {
        VStack(spacing: 1) {
            if tile >= 44 {
                Text(today, format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: max(10, tile * 0.18), weight: .medium))
                    .foregroundStyle(.red)
            }
            Text(today, format: .dateTime.day())
                .font(.system(size: max(14, tile * 0.46), weight: .medium))
                .monospacedDigit()
                .padding(.top, tile < 44 ? 3 : 0)
                .overlay(alignment: .top) {
                    if tile < 44 {
                        Capsule().fill(.red).frame(height: 2)
                    }
                }
        }
        .overlay(alignment: .bottomTrailing) {
            if let next {
                Circle().fill(next.color).frame(width: 4, height: 4).offset(x: 5)
            }
        }
    }

    private var square: some View {
        WidgetTile(size: .small) { dateFace }
    }

    private var wide: some View {
        WidgetTile(size: .medium) {
            HStack(spacing: tile * 0.1) {
                dateFace.frame(width: tile * 0.65)
                if tile < 44 {
                    Image(systemName: access == .granted ? (next == nil ? "calendar" : "calendar.badge.clock") : "calendar.badge.exclamationmark")
                        .font(.system(size: tile * 0.46, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryLine)
                            .font(.system(size: max(11, tile * 0.20), weight: .medium))
                        Text(secondaryLine)
                            .font(.system(size: max(11, tile * 0.18)))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, tile * 0.10)
        }
    }

    private var primaryLine: String {
        switch access {
        case .unknown: return "Calendar"
        case .denied: return "No access"
        case .granted: return next?.title ?? "No events"
        }
    }

    private var secondaryLine: String {
        switch access {
        case .unknown: return "Connect"
        case .denied: return "Settings"
        case .granted:
            guard let next else { return "Next 24 hours" }
            if next.isAllDay { return "All day" }
            if next.start <= Date() { return "Now" }
            return next.start.formatted(.dateTime.hour().minute())
        }
    }
}
