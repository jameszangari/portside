import SwiftUI

/// Widget width in dock tiles. Height is always one tile.
enum WidgetSize: Int, Codable {
    case small = 1, medium = 2, large = 3
}

/// A dock widget plugin.
///
/// React analogy: the widget object is a small store (state + a `refresh`
/// action), and `body` is its component. `WidgetHost` is the effect that
/// calls `refresh` on an interval and cleans up on unmount.
protocol DockWidget: ObservableObject, Identifiable {
    associatedtype Body: View

    /// Catalog id, also used for persistence ("clock", "battery", ...).
    static var kind: String { get }
    var id: String { get }
    var name: String { get }
    /// SF Symbol shown in menus that list widgets.
    var icon: Image { get }
    var size: WidgetSize { get }

    /// Seconds between `refresh()` calls. 0 means no timer (event-driven only).
    var refreshInterval: TimeInterval { get }
    /// If true, refreshes land on wall-clock multiples of the interval
    /// (the clock flips exactly on the minute).
    var alignsRefreshToInterval: Bool { get }

    /// Called once on start and then on every timer tick. Must be cheap or
    /// hand work off the main thread.
    func refresh()
    /// Optional event subscriptions (notifications, IOKit callbacks).
    func start()
    func stop()
    /// Click action.
    func activate()

    @ViewBuilder var body: Body { get }
}

extension DockWidget {
    var id: String { Self.kind }
    var alignsRefreshToInterval: Bool { false }
    func start() {}
    func stop() {}
    func activate() {}
}

// MARK: - Shared layout helpers

enum DockMetrics {
    /// Gap between tiles in the strip.
    static let spacing: CGFloat = 6
}

private struct DockTileSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 48
}

extension EnvironmentValues {
    /// Current tile size in points (shrinks when the strip is full).
    var dockTileSize: CGFloat {
        get { self[DockTileSizeKey.self] }
        set { self[DockTileSizeKey.self] = newValue }
    }
}

/// Standard widget chrome: a rounded tile of `size` units wide.
struct WidgetTile<Content: View>: View {
    let size: WidgetSize
    @ViewBuilder var content: Content
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        let units = CGFloat(size.rawValue)
        content
            .frame(width: tile * units + DockMetrics.spacing * (units - 1), height: tile)
            .background(
                RoundedRectangle(cornerRadius: tile * 0.22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: tile * 0.22, style: .continuous))
    }
}
