import AppKit
import SwiftUI
import os.log

private let magnifyLogger = Logger(subsystem: "com.james.portside", category: "Magnifier")

/// Native-style Dock magnification, computed in one place.
///
/// Input: the cursor's position in the strip's content space (the same
/// `DockHover.space` the hover targets use) and the tiles' unmagnified
/// frames. Output: one `MagnifyLayout` with every tile's scale and shift,
/// published so a few small SwiftUI modifiers can apply it as render
/// transforms. The strip's layout never changes, so hover target frames,
/// drop hit-testing and the panel's measured size stay the unmagnified ones.
///
/// The math works on the unmagnified layout only. The point under the cursor
/// stays fixed: tiles left of it shift left by their growth, tiles right of
/// it shift right, so the tile under a stationary cursor never slides out
/// from under it and hover cannot flicker. The shelf widens by the same
/// amounts on each end.
///
/// Event-driven: it changes only on mouse moves over the dock and on exit.
/// The spring is SwiftUI's, which stops rendering once it settles.
///
/// React analogy: a store whose derived state (`layout`) is recomputed from
/// one input (the cursor) and read by memoized leaf components.
final class Magnifier: ObservableObject {
    /// Tiles within this many slots of the cursor grow (raised cosine).
    static let radius: CGFloat = 3

    @Published private(set) var layout = MagnifyLayout()

    /// The panel needs extra room (above and on both sides) while tiles are
    /// magnified or settling, and none otherwise. Zero means none.
    var onRoomChanged: ((MagnifyRoom) -> Void)?

    private(set) var edge: DockEdge = .bottom
    private var settingEnabled = false
    private var magnifiedSize: CGFloat = DockModel.Defaults.magnifiedSize
    private var suspended = false
    /// Unmagnified tile frames along the strip, sorted.
    private var tiles: [TileSlot] = []
    /// Unmagnified strip content size (the shelf), from the panel.
    var contentSizeProvider: (() -> CGSize)?
    private var contentSize: CGSize { contentSizeProvider?() ?? .zero }
    private var room = MagnifyRoom.zero
    /// Bumped on every engage and settle, so a stale settle completion
    /// does not remove the room from a newer engagement.
    private var generation = 0
    private let stats = MagnifyStats()

    private struct TileSlot: Equatable {
        var id: String
        var start: CGFloat
        var length: CGFloat
        var crossStart: CGFloat
    }

    /// Bottom edge only for now. Side edges come next.
    var isActive: Bool { settingEnabled && edge == .bottom && magnifiedSize > minTileLength }

    var isMagnified: Bool { layout.focus != nil }

    private var minTileLength: CGFloat { tiles.map(\.length).min() ?? DockModel.iconSizeRange.upperBound }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Inputs

    func configure(enabled: Bool, size: CGFloat, edge: DockEdge) {
        let changed = enabled != settingEnabled || size != magnifiedSize || edge != self.edge
        guard changed else { return }
        // The size slider calls this on every step; only on/off and edge
        // changes go to the info log.
        let toggled = enabled != settingEnabled || edge != self.edge
        settingEnabled = enabled
        magnifiedSize = size
        self.edge = edge
        if toggled {
            magnifyLogger.info("magnification \(enabled ? "on" : "off", privacy: .public), size \(size, format: .fixed(precision: 0))pt, edge \(edge.rawValue, privacy: .public)")
        } else {
            magnifyLogger.debug("magnified size \(size, format: .fixed(precision: 0))pt")
        }
        if isActive, let focus = layout.focus {
            updateRoom()
            apply(focus: focus, animation: Self.followAnimation)
        } else {
            settle(animated: true)
        }
    }

    /// Drag sessions, an open group grid or menu, a bounce: tiles settle
    /// back and stay unmagnified until the next mouse move after this ends.
    func setSuspended(_ value: Bool, reason: String) {
        guard value != suspended else { return }
        suspended = value
        magnifyLogger.info("magnification \(value ? "suspended" : "resumed", privacy: .public): \(reason, privacy: .public)")
        if value { settle(animated: true) }
    }

    /// Hover target frames from the strip (unmagnified, content space).
    func updateTiles(_ targets: [HoverTarget]) {
        let vertical = edge.isVertical
        let slots = targets.map { t in
            TileSlot(id: t.id,
                     start: vertical ? t.frame.minY : t.frame.minX,
                     length: vertical ? t.frame.height : t.frame.width,
                     crossStart: vertical ? t.frame.minX : t.frame.minY)
        }.sorted { $0.start < $1.start }
        guard slots != tiles else { return }
        tiles = slots
        if let focus = layout.focus {
            updateRoom()
            apply(focus: focus, animation: nil)
        }
    }

    /// Cursor over the dock's active region, in content coordinates.
    func cursorMoved(to point: CGPoint) {
        guard isActive, !suspended, !tiles.isEmpty else {
            if isMagnified { settle(animated: true) }
            return
        }
        let started = CACurrentMediaTime()
        let length = edge.isVertical ? contentSize.height : contentSize.width
        let focus = min(max(edge.isVertical ? point.y : point.x, 0), max(length, 0))
        let engaging = layout.focus == nil
        if engaging {
            generation += 1
            updateRoom()
            stats.begin()
        }
        apply(focus: focus, animation: engaging ? Self.engageAnimation : Self.followAnimation)
        stats.recordMove(handlerSeconds: CACurrentMediaTime() - started)
    }

    /// Cursor left the dock (or the dock is hiding): ease back to normal.
    func cursorExited() {
        settle(animated: true)
    }

    /// Drop everything at once (dock hidden, engine stopped).
    func reset() {
        settle(animated: false)
    }

    // MARK: - Queries (panel and hover)

    /// Whether a content-space point is over the magnified dock: the widened
    /// shelf plus the band the grown icons rise into. Empty when unmagnified.
    func bandContains(_ point: CGPoint) -> Bool {
        guard layout.focus != nil else { return false }
        let vertical = edge.isVertical
        let along = vertical ? point.y : point.x
        let cross = vertical ? point.x : point.y
        let length = vertical ? contentSize.height : contentSize.width
        let crossLength = vertical ? contentSize.width : contentSize.height
        guard along >= -layout.leading, along <= length + layout.trailing else { return false }
        let top = (tiles.map(\.crossStart).min() ?? 0) - layout.maxLift
        return cross >= top && cross <= crossLength
    }

    /// Where a tile is drawn right now (target values, not mid-spring), in
    /// content space. Unmagnified frames pass through unchanged.
    func displayFrame(id: String, base: CGRect) -> CGRect {
        guard layout.focus != nil else { return base }
        let scale = layout.scales[id] ?? 1
        let shift = layout.shifts[id] ?? 0
        // Bottom dock: the icon is as wide as the tile and grows upward.
        let lift = (scale - 1) * base.width
        var frame = base
        frame.size.width = base.width * scale
        frame.origin.x = base.midX + shift - frame.width / 2
        frame.origin.y = base.minY - lift
        frame.size.height = base.height + lift
        return frame
    }

    // MARK: - Layout math

    private func apply(focus: CGFloat, animation: Animation?) {
        let next = computeLayout(focus: focus)
        guard next != layout else { return }
        withAnimation(animation) { layout = next }
    }

    private func computeLayout(focus: CGFloat) -> MagnifyLayout {
        let slot = (tiles.map(\.length).max() ?? 0) + DockMetrics.spacing
        guard slot > 0 else { return MagnifyLayout() }

        // Growth of each tile along the strip (it also rises by this much).
        var growth: [CGFloat] = []
        growth.reserveCapacity(tiles.count)
        for tile in tiles {
            let distance = abs(tile.start + tile.length / 2 - focus) / slot
            let weight = distance >= Self.radius ? 0 : (1 + cos(.pi * distance / Self.radius)) / 2
            growth.append(max(0, magnifiedSize - tile.length) * weight)
        }

        // Growth left of the focus, with the tile under it counted pro rata.
        var atFocus: CGFloat = 0
        for (tile, grow) in zip(tiles, growth) {
            if tile.start + tile.length <= focus {
                atFocus += grow
            } else if tile.start < focus {
                atFocus += grow * (focus - tile.start) / tile.length
            }
        }

        var result = MagnifyLayout()
        result.focus = focus
        var before: CGFloat = 0
        for (tile, grow) in zip(tiles, growth) {
            result.scales[tile.id] = 1 + grow / tile.length
            result.shifts[tile.id] = before + grow / 2 - atFocus
            result.growths[tile.id] = grow
            result.steps.append(.init(center: tile.start + tile.length / 2, growthThrough: before + grow))
            before += grow
            result.maxLift = max(result.maxLift, grow)
        }
        result.growthAtFocus = atFocus
        result.leading = atFocus
        result.trailing = before - atFocus
        return result
    }

    // MARK: - Room and settling

    private func updateRoom() {
        let extra = max(0, magnifiedSize - minTileLength).rounded(.up)
        // The bell covers about `radius` tiles' worth of growth in total;
        // one more slot of margin keeps the widened shelf inside the window.
        let side = extra * min(CGFloat(tiles.count), Self.radius + 1)
        let next = MagnifyRoom(far: extra, side: side)
        guard next != room else { return }
        room = next
        onRoomChanged?(next)
    }

    private func settle(animated: Bool) {
        guard layout.focus != nil || room != .zero else { return }
        generation += 1
        let myGeneration = generation
        stats.end()
        let finish = { [weak self] in
            guard let self, self.generation == myGeneration, self.layout.focus == nil else { return }
            self.room = .zero
            self.onRoomChanged?(.zero)
        }
        guard animated, !Self.reduceMotion, layout.focus != nil else {
            withAnimation(nil) { layout = MagnifyLayout() }
            finish()
            return
        }
        withAnimation(Self.settleAnimation, completionCriteria: .logicallyComplete) {
            layout = MagnifyLayout()
        } completion: {
            finish()
        }
    }

    // MARK: - Motion (Reduce Motion: follow the cursor with no spring)

    private static var engageAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.86)
    }

    private static var followAnimation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.86)
    }

    private static var settleAnimation: Animation {
        .spring(response: 0.2, dampingFraction: 0.92)
    }
}

/// Extra window room the magnified tiles draw into: `far` past the shelf's
/// far side (above it on the bottom dock), `side` past each end.
struct MagnifyRoom: Equatable {
    var far: CGFloat
    var side: CGFloat
    static let zero = MagnifyRoom(far: 0, side: 0)
}

/// One snapshot of the magnified strip. Empty (`focus == nil`) means
/// everything is at its normal size and place.
struct MagnifyLayout: Equatable {
    struct Step: Equatable {
        var center: CGFloat
        var growthThrough: CGFloat
    }

    /// Cursor position along the strip, content space.
    var focus: CGFloat?
    /// Per tile id: size multiplier and shift along the strip.
    var scales: [String: CGFloat] = [:]
    var shifts: [String: CGFloat] = [:]
    /// Per tile id: how much it grows (along the strip and away from the edge).
    var growths: [String: CGFloat] = [:]
    /// Tile centers with the growth up to and including each, for shifting
    /// items that do not magnify (widgets, separators).
    var steps: [Step] = []
    var growthAtFocus: CGFloat = 0
    /// How far the shelf extends past each unmagnified end.
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// Height the tallest tile rises above its normal top.
    var maxLift: CGFloat = 0

    /// Shift for a non-magnifying item centered at `center`.
    func shift(atCenter center: CGFloat) -> CGFloat {
        guard focus != nil else { return 0 }
        let through = steps.last { $0.center < center }?.growthThrough ?? 0
        return through - growthAtFocus
    }
}

// MARK: - SwiftUI side

private struct MagnifierKey: EnvironmentKey {
    static let defaultValue: Magnifier? = nil
}

extension EnvironmentValues {
    /// Set only inside the dock strip. Tiles drawn elsewhere (drag previews,
    /// group grids) have none and never magnify.
    var magnifier: Magnifier? {
        get { self[MagnifierKey.self] }
        set { self[MagnifierKey.self] = newValue }
    }
}

extension View {
    /// A tile's icon: grows away from the screen edge and shifts along the
    /// strip. Render transforms only, so the tile's layout slot, its hover
    /// frame and its neighbors' layout never change.
    func magnifiedIcon(id: String) -> some View {
        modifier(MagnifyEffect(target: .icon(id)))
    }

    /// A tile's running dot: shifts with its icon, never grows.
    func magnifiedIndicator(id: String) -> some View {
        modifier(MagnifyEffect(target: .indicator(id)))
    }

    /// A whole tile's hit area (its right-click overlay): grows to cover the
    /// magnified icon, so right-clicks there land and the menu opens above it.
    @ViewBuilder func magnifiedHitArea(id: String?) -> some View {
        if let id { modifier(MagnifyEffect(target: .hitArea(id))) } else { self }
    }

    /// Widgets and separators: shift so magnified tiles never overlap them.
    func magnifiedShift() -> some View {
        modifier(MagnifyEffect(target: .fixed))
    }

    /// The shelf background, behind the tiles and widened by the magnified
    /// tiles' growth. The layout size stays the unmagnified one.
    func magnifiedShelf(_ look: DockLook) -> some View {
        modifier(MagnifiedShelf(look: look))
    }
}

private enum MagnifyTarget {
    case icon(String)
    case indicator(String)
    case hitArea(String)
    case fixed
}

private struct MagnifyEffect: ViewModifier {
    let target: MagnifyTarget
    @Environment(\.magnifier) private var magnifier

    func body(content: Content) -> some View {
        if let magnifier {
            content.modifier(ObservedMagnifyEffect(magnifier: magnifier, target: target))
        } else {
            content
        }
    }
}

/// Only this modifier observes the magnifier, so a mouse move re-evaluates
/// these small bodies and not the strip or the tiles.
private struct ObservedMagnifyEffect: ViewModifier {
    @ObservedObject var magnifier: Magnifier
    let target: MagnifyTarget
    /// Unmagnified center along the strip, for `.fixed` items.
    @State private var center: CGFloat = 0

    @ViewBuilder func body(content: Content) -> some View {
        let edge = magnifier.edge
        let (scale, shift) = transform(magnifier.layout)
        let moved = content
            .scaleEffect(scale, anchor: edge.growthAnchor)
            .offset(x: edge.isVertical ? 0 : shift, y: edge.isVertical ? shift : 0)
        if case .hitArea(let id) = target {
            // Real frame changes (not a render transform): AppKit hit-tests
            // and anchors the menu with the view's frame. Bottom dock only.
            let grow = magnifier.layout.growths[id] ?? 0
            content
                .padding(.top, -grow)
                .padding(.horizontal, -grow / 2)
                .offset(x: magnifier.layout.shifts[id] ?? 0)
        } else if case .fixed = target {
            // Measured outside the transforms, so this is the unmagnified slot.
            moved.onGeometryChange(for: CGFloat.self) { proxy in
                let frame = proxy.frame(in: .named(DockHover.space))
                return edge.isVertical ? frame.midY : frame.midX
            } action: { center = $0 }
        } else {
            moved
        }
    }

    private func transform(_ layout: MagnifyLayout) -> (scale: CGFloat, shift: CGFloat) {
        switch target {
        case .icon(let id): (layout.scales[id] ?? 1, layout.shifts[id] ?? 0)
        case .indicator(let id): (1, layout.shifts[id] ?? 0)
        case .hitArea: (1, 0)
        case .fixed: (1, layout.shift(atCenter: center))
        }
    }
}

private struct MagnifiedShelf: ViewModifier {
    let look: DockLook
    @Environment(\.magnifier) private var magnifier
    @Environment(\.dockEdge) private var edge

    func body(content: Content) -> some View {
        if let magnifier {
            content.modifier(ObservedShelf(magnifier: magnifier, look: look, edge: edge))
        } else {
            content.background { Color.clear.dockBackground(look) }
        }
    }
}

private struct ObservedShelf: ViewModifier {
    @ObservedObject var magnifier: Magnifier
    let look: DockLook
    let edge: DockEdge

    func body(content: Content) -> some View {
        let lead = magnifier.layout.leading
        let trail = magnifier.layout.trailing
        let leadEdge: Edge.Set = edge.isVertical ? .top : .leading
        let trailEdge: Edge.Set = edge.isVertical ? .bottom : .trailing
        // The shelf (fill, border, glass) is its own layer behind the tiles,
        // never wrapped around them: magnified icons rise past its edge and
        // must stay fully opaque, with no border or glass rim drawn over
        // them. Negative padding widens the shelf without changing the
        // strip's layout size.
        content.background {
            Color.clear
                .dockBackground(look)
                .padding(leadEdge, -lead)
                .padding(trailEdge, -trail)
        }
    }
}

// MARK: - Cost of a mouse move

/// Main-thread cost of magnification per mouse move, logged once per hover
/// (on exit): the handler itself, and the whole turn including SwiftUI's
/// update and the Core Animation commit (a run loop observer that only
/// exists while magnified, so it costs nothing otherwise).
private final class MagnifyStats {
    private var moves = 0
    private var handlerTotal: Double = 0
    private var handlerMax: Double = 0
    private var turnTotal: Double = 0
    private var turnMax: Double = 0
    private var turns = 0
    private var pendingStart: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?

    func begin() {
        moves = 0; handlerTotal = 0; handlerMax = 0
        turns = 0; turnTotal = 0; turnMax = 0
        pendingStart = 0
        guard observer == nil else { return }
        // Order last, so it runs after SwiftUI's update and the CA commit.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            guard let self, self.pendingStart > 0 else { return }
            let turn = CACurrentMediaTime() - self.pendingStart
            self.pendingStart = 0
            self.turns += 1
            self.turnTotal += turn
            self.turnMax = max(self.turnMax, turn)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func recordMove(handlerSeconds: Double) {
        moves += 1
        handlerTotal += handlerSeconds
        handlerMax = max(handlerMax, handlerSeconds)
        if pendingStart == 0 { pendingStart = CACurrentMediaTime() - handlerSeconds }
    }

    func end() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        guard moves > 0 else { return }
        let handlerAvg = handlerTotal / Double(moves) * 1_000_000
        let turnAvg = turns > 0 ? turnTotal / Double(turns) * 1000 : 0
        magnifyLogger.info("mouse-moved cost over \(self.moves) moves: handler avg \(handlerAvg, format: .fixed(precision: 1))us max \(self.handlerMax * 1_000_000, format: .fixed(precision: 1))us; full turn (SwiftUI update + commit) avg \(turnAvg, format: .fixed(precision: 2))ms max \(self.turnMax * 1000, format: .fixed(precision: 2))ms")
        moves = 0
    }
}
