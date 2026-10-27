import AppKit
import EventKit
import SwiftUI
import os.log

/// Today's date plus the next event in the coming 24 hours. Calendar access
/// is only requested when the user clicks the widget, never on launch.
final class CalendarWidget: DockWidget {
    static let kind = "calendar"
    let name = "Calendar"
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

    var body: some View {
        WidgetTile(size: .medium) {
            HStack(spacing: tile * 0.1) {
                VStack(spacing: 0) {
                    Text(today, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: tile * 0.17, weight: .bold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                    Text(today, format: .dateTime.day())
                        .font(.system(size: tile * 0.4, weight: .regular, design: .rounded))
                }
                .frame(width: tile * 0.7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryLine)
                        .font(.system(size: tile * 0.17, weight: .semibold))
                    Text(secondaryLine)
                        .font(.system(size: tile * 0.15))
                        .foregroundStyle(next.map { _ in Color.secondary } ?? Color.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, tile * 0.08)
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
        case .unknown: return "Click to connect"
        case .denied: return "Enable in Settings"
        case .granted:
            guard let next else { return "Next 24 hours" }
            if next.isAllDay { return "All day" }
            if next.start <= Date() { return "Now" }
            return next.start.formatted(.dateTime.hour().minute())
        }
    }
}
