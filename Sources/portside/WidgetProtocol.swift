import SwiftUI

/// Widget width in dock tiles. Height is always one tile.
enum WidgetSize: Int, Codable, Comparable, Identifiable {
    case small = 1, medium = 2, large = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Wide"
        case .large: "Extra Wide"
        }
    }

    static func < (a: WidgetSize, b: WidgetSize) -> Bool { a.rawValue < b.rawValue }

    /// Sizes a widget can be shown at: square, plus its own design if wider.
    static func choices(upTo natural: WidgetSize) -> [WidgetSize] {
        natural == .small ? [.small] : [.small, natural]
    }

    /// The size a widget draws at: the dock's choice, never wider than the
    /// widget's own design.
    static func resolved(_ chosen: WidgetSize?, natural: WidgetSize) -> WidgetSize {
        min(chosen ?? natural, natural)
    }
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
    /// Hover label: what a click opens ("Activity Monitor"). Defaults to `name`.
    var hoverTitle: String { get }
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
    var hoverTitle: String { name }
    var alignsRefreshToInterval: Bool { false }
    func start() {}
    func stop() {}
    func activate() {}
}

// MARK: - Shared layout helpers

enum DockMetrics {
    /// Default gap between tiles in the strip. Live value is `DockModel.iconGap`.
    static let spacing: CGFloat = DockModel.Defaults.iconGap
}

/// Widget type sizes are authored against a 32pt tile. Scale with the live
/// tile so the same visual ratio holds from 16pt to 128pt. Fixed `max(...)`
/// floors break that ratio (too big when small, too small when large).
enum WidgetTypography {
    static let referenceTile: CGFloat = 32

    static func fontSize(_ pointsAt32: CGFloat, tile: CGFloat) -> CGFloat {
        tile * (pointsAt32 / referenceTile)
    }
}

private struct DockTileSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 48
}

private struct WidgetSizeKey: EnvironmentKey {
    static let defaultValue: WidgetSize? = nil
}

private struct DockIconGapKey: EnvironmentKey {
    static let defaultValue: CGFloat = DockMetrics.spacing
}

extension EnvironmentValues {
    /// Current tile size in points (shrinks when the strip is full).
    var dockTileSize: CGFloat {
        get { self[DockTileSizeKey.self] }
        set { self[DockTileSizeKey.self] = newValue }
    }

    /// The size the dock shows this widget at (nil: the widget's own size).
    /// Side docks always pass `.small`; on the bottom it is the user's pick.
    var widgetSize: WidgetSize? {
        get { self[WidgetSizeKey.self] }
        set { self[WidgetSizeKey.self] = newValue }
    }

    /// Gap between strip tiles (and inside multi-unit widgets).
    var dockIconGap: CGFloat {
        get { self[DockIconGapKey.self] }
        set { self[DockIconGapKey.self] = newValue }
    }
}

/// Standard widget chrome: a rounded tile of `size` units wide.
/// Inset by one app-icon margin on each side (same as groups), centered in a
/// full-tile slot. Wide widgets only inset the outer ends so the gap to
/// neighbors matches small widgets and app tiles.
struct WidgetTile<Content: View>: View {
    let size: WidgetSize
    @ViewBuilder var content: Content
    @Environment(\.dockTileSize) private var tile
    @Environment(\.dockIconGap) private var iconGap

    var body: some View {
        let units = CGFloat(size.rawValue)
        let inset = tile * IconMetrics.margin
        let drawn = tile - 2 * inset
        let slotWidth = tile * units + iconGap * (units - 1)
        let chromeWidth = slotWidth - 2 * inset
        let radius = drawn * 0.22
        content
            .frame(width: chromeWidth, height: drawn)
            // Own frosted backing, so the dock's Frost and style settings
            // never make a widget see-through.
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(Color.white.opacity(0.08)))
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .frame(width: slotWidth, height: tile)
    }
}

/// The size choice, drawn like the iOS widget size row: one outline per
/// size in its own aspect ratio, the current one highlighted. Used in a
/// widget's right-click menu and in Settings > Widgets.
struct WidgetSizePicker: View {
    let sizes: [WidgetSize]
    let selection: WidgetSize
    let onSelect: (WidgetSize) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sizes) { size in
                Button { onSelect(size) } label: {
                    WidgetSizeIcon(size: size)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(size == selection ? 0.16 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(size.title)
                .accessibilityLabel(size.title)
                .accessibilityAddTraits(size == selection ? .isSelected : [])
            }
        }
    }
}

/// A rounded outline in the size's aspect ratio with a small mark in the
/// corner, like the iOS size icons.
private struct WidgetSizeIcon: View {
    let size: WidgetSize

    var body: some View {
        let height: CGFloat = 16
        let width = height * CGFloat(size.rawValue) + 4 * CGFloat(size.rawValue - 1)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 4, height: 4)
                    .padding(3.5)
            }
    }
}
