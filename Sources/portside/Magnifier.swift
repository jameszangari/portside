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
    /// Runs right after every change to `layout` (things drawn outside the
    /// strip, like the launch bounce, follow the tiles with `lastMotion`).
    var onLayoutChanged: (() -> Void)?
    /// How far the shelf may widen past each end (content leading, trailing)
    /// before it leaves the visible screen. Nil: no limit.
    var alongLimitsProvider: (() -> (lead: CGFloat, trail: CGFloat))?

    private(set) var edge: DockEdge = .bottom
    private var settingEnabled = false
    /// Control-Shift held over the dock: magnification flips (on becomes
    /// off, off becomes on) until it is released.
    private var flipped = false
    private var magnifiedSize: CGFloat = DockModel.Defaults.magnifiedSize
    private var iconGap: CGFloat = DockModel.Defaults.iconGap
    private var suspended = false
    /// Unmagnified tile frames along the strip, sorted.
    private var tiles: [TileSlot] = []
    /// The hover targets `tiles` came from, to rebuild them for a new edge.
    private var targets: [HoverTarget] = []
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
        var crossEnd: CGFloat
    }

    var isActive: Bool { settingEnabled != flipped && magnifiedSize > minTileLength }

    /// Spring of the latest layout change, nil if it was instant (Reduce
    /// Motion, a reset). The launch bounce and labels move with it.
    private(set) var lastMotion: MagnifyMotion?
    /// The latest layout change grew the tiles from their normal size.
    private(set) var lastChangeEngaged = false

    /// Largest size a tile can be drawn at right now (its own size if
    /// magnification is off).
    var maxDrawnSize: CGFloat { isActive ? max(magnifiedSize, minTileLength) : 0 }

    /// Upper bound on how far a magnified tile can move from its slot along
    /// the strip, or grow away from the edge.
    var maxDisplacement: CGFloat {
        guard isActive else { return 0 }
        return max(0, magnifiedSize - minTileLength) * (Self.radius + 1)
    }

    var isMagnified: Bool { layout.focus != nil }

    private var minTileLength: CGFloat { tiles.map(\.length).min() ?? DockModel.iconSizeRange.upperBound }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Inputs

    func configure(enabled: Bool, size: CGFloat, edge: DockEdge, iconGap: CGFloat = DockModel.Defaults.iconGap) {
        let changed = enabled != settingEnabled || size != magnifiedSize || edge != self.edge || iconGap != self.iconGap
        guard changed else { return }
        // The size slider calls this on every step; only on/off and edge
        // changes go to the info log.
        let toggled = enabled != settingEnabled || edge != self.edge
        settingEnabled = enabled
        magnifiedSize = size
        self.iconGap = iconGap
        if edge != self.edge {
            self.edge = edge
            // The strip may have reported its tiles before the edge was set
            // (at launch): re-read them along the new axis.
            tiles = Self.slots(from: targets, vertical: edge.isVertical)
        }
        if toggled {
            magnifyLogger.info("magnification \(enabled ? "on" : "off", privacy: .public), size \(size, format: .fixed(precision: 0))pt, edge \(edge.rawValue, privacy: .public)")
        } else {
            magnifyLogger.debug("magnified size \(size, format: .fixed(precision: 0))pt")
        }
        if isActive, let focus = layout.focus {
            updateRoom()
            apply(focus: focus, motion: Self.followMotion)
        } else {
            settle(animated: true)
        }
    }

    /// Control-Shift pressed or released while the dock is up. True if that
    /// changed anything. Turning off settles; turning on waits for the
    /// caller to report the cursor.
    @discardableResult
    func setFlipped(_ value: Bool) -> Bool {
        guard value != flipped else { return false }
        let wasActive = isActive
        flipped = value
        magnifyLogger.info("Control-Shift \(value ? "held" : "released", privacy: .public): magnification \(self.isActive ? "on" : "off", privacy: .public)")
        if wasActive && !isActive { settle(animated: true) }
        return wasActive != isActive
    }

    /// Drag sessions, an open group grid or menu: tiles settle
    /// back and stay unmagnified until the next mouse move after this ends.
    func setSuspended(_ value: Bool, reason: String) {
        guard value != suspended else { return }
        suspended = value
        magnifyLogger.info("magnification \(value ? "suspended" : "resumed", privacy: .public): \(reason, privacy: .public)")
        if value { settle(animated: true) }
    }

    /// Hover target frames from the strip (unmagnified, content space).
    func updateTiles(_ targets: [HoverTarget]) {
        self.targets = targets
        let slots = Self.slots(from: targets, vertical: edge.isVertical)
        guard slots != tiles else { return }
        tiles = slots
        if let focus = layout.focus {
            updateRoom()
            apply(focus: focus, motion: nil)
        }
    }

    private static func slots(from targets: [HoverTarget], vertical: Bool) -> [TileSlot] {
        targets.map { t in
            TileSlot(id: t.id,
                     start: vertical ? t.frame.minY : t.frame.minX,
                     length: vertical ? t.frame.height : t.frame.width,
                     crossStart: vertical ? t.frame.minX : t.frame.minY,
                     crossEnd: vertical ? t.frame.maxX : t.frame.maxY)
        }.sorted { $0.start < $1.start }
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
        apply(focus: focus, motion: engaging ? Self.engageMotion : Self.followMotion)
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

    /// Only the hovered icon reports its rendered spring position. This is
    /// driven by SwiftUI animation frames, never a timer or mouse poll.
    @Published var labelTargetID: String?
    var onIconPresented: ((String, CGFloat, CGFloat) -> Void)?

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
        // The shelf, plus the band past the tiles' far side.
        switch edge {
        case .bottom, .right:
            let far = (tiles.map(\.crossStart).min() ?? 0) - layout.maxLift
            return cross >= min(0, far) && cross <= crossLength
        case .left:
            let far = (tiles.map(\.crossEnd).max() ?? 0) + layout.maxLift
            return cross >= 0 && cross <= max(crossLength, far)
        }
    }

    /// Where a tile is drawn right now (target values, not mid-spring), in
    /// content space. Unmagnified frames pass through unchanged.
    func displayFrame(id: String, base: CGRect) -> CGRect {
        guard layout.focus != nil else { return base }
        return presentedFrame(base: base, scale: layout.scales[id] ?? 1, shift: layout.shifts[id] ?? 0)
    }

    func presentedFrame(base: CGRect, scale: CGFloat, shift: CGFloat) -> CGRect {
        var frame = base
        if edge.isVertical {
            // Side docks: the icon is as tall as the tile and grows sideways.
            let lift = (scale - 1) * base.height
            frame.size.height = base.height * scale
            frame.origin.y = base.midY + shift - frame.height / 2
            frame.size.width = base.width + lift
            if edge == .right { frame.origin.x = base.minX - lift }
            // Reach the shelf's screen-edge side too: the column is as wide
            // as the widest widget, and the cursor there magnifies this tile,
            // so it should hover it as well. Labels and the bounce use the
            // far side, which this leaves alone.
            if edge == .left {
                frame.size.width += frame.minX
                frame.origin.x = 0
            } else {
                frame.size.width = max(frame.width, contentSize.width - frame.minX)
            }
        } else {
            // Bottom dock: the icon is as wide as the tile and grows upward.
            let lift = (scale - 1) * base.width
            frame.size.width = base.width * scale
            frame.origin.x = base.midX + shift - frame.width / 2
            frame.origin.y = base.minY - lift
            frame.size.height = base.height + lift
        }
        return frame
    }

    // MARK: - Layout math

    private func apply(focus: CGFloat, motion: MagnifyMotion?) {
        let next = computeLayout(focus: focus)
        guard next != layout else { return }
        lastChangeEngaged = layout.focus == nil
        lastMotion = motion
        withAnimation(motion?.animation) { layout = next }
        onLayoutChanged?()
    }

    private func computeLayout(focus: CGFloat) -> MagnifyLayout {
        let slot = (tiles.map(\.length).max() ?? 0) + iconGap
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

        // The point under the cursor stays put, unless that would push the
        // shelf off screen (a long dock near its ends): then the growth moves
        // to the other end, and only past both limits does it spill evenly.
        let total = growth.reduce(0, +)
        var lead = atFocus
        if let limits = alongLimitsProvider?() {
            let roomLead = max(0, limits.lead)
            let roomTrail = max(0, limits.trail)
            lead = total <= roomLead + roomTrail
                ? min(max(atFocus, total - roomTrail), roomLead)
                : roomLead + (total - roomLead - roomTrail) / 2
        }

        var result = MagnifyLayout()
        result.focus = focus
        var before: CGFloat = 0
        for (tile, grow) in zip(tiles, growth) {
            result.scales[tile.id] = 1 + grow / tile.length
            result.shifts[tile.id] = before + grow / 2 - lead
            result.growths[tile.id] = grow
            result.steps.append(.init(center: tile.start + tile.length / 2, growthThrough: before + grow))
            before += grow
            result.maxLift = max(result.maxLift, grow)
        }
        result.growthAtFocus = lead
        result.leading = lead
        result.trailing = total - lead
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
            self.lastMotion = nil
            self.room = .zero
            self.onRoomChanged?(.zero)
        }
        lastChangeEngaged = false
        guard animated, !Self.reduceMotion, layout.focus != nil else {
            lastMotion = nil
            withAnimation(nil) { layout = MagnifyLayout() }
            onLayoutChanged?()
            finish()
            return
        }
        lastMotion = Self.settleMotion
        withAnimation(Self.settleMotion.animation, completionCriteria: .logicallyComplete) {
            layout = MagnifyLayout()
        } completion: {
            finish()
        }
        onLayoutChanged?()
    }

    // MARK: - Motion (Reduce Motion: follow the cursor with no spring)

    private static var engageMotion: MagnifyMotion? {
        reduceMotion ? nil : MagnifyMotion(response: 0.16, dampingFraction: 0.86)
    }

    private static var followMotion: MagnifyMotion? {
        reduceMotion ? nil : MagnifyMotion(response: 0.12, dampingFraction: 0.86, interactive: true)
    }

    private static let settleMotion = MagnifyMotion(response: 0.2, dampingFraction: 0.92)
}

/// One of the magnifier's springs, so views outside SwiftUI (the bounce
/// layer, the label window) can move the same way.
struct MagnifyMotion: Equatable {
    var response: Double
    var dampingFraction: Double
    var interactive = false

    var animation: Animation {
        interactive
            ? .interactiveSpring(response: response, dampingFraction: dampingFraction)
            : .spring(response: response, dampingFraction: dampingFraction)
    }

    /// The same spring for Core Animation.
    func caSpring(keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: response, bounce: 1 - dampingFraction)
        spring.keyPath = keyPath
        spring.duration = spring.settlingDuration
        return spring
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

// MARK: - Control-Shift flip

/// Holding Control and Shift over the dock flips magnification, like the
/// native Dock. Flags-changed monitors exist only while the dock is up
/// (`start` on reveal, `stop` on hide), so there is no cost otherwise.
///
/// The global monitor sees modifier changes while another app is
/// frontmost; macOS may withhold those without Accessibility access, so
/// the dock's own mouse moves also report the modifier state (`update`).
/// No polling either way.
final class MagnifyFlipKeys {
    /// True while both keys are held.
    var onChange: ((Bool) -> Void)?
    private var monitors: [Any] = []
    private var held = false

    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.update(event.modifierFlags)
        }) { monitors.append(global) }
        // Portside is a regular app while Settings is open: its own events.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }) { monitors.append(local) }
        update(NSEvent.modifierFlags)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        update([])
    }

    func update(_ flags: NSEvent.ModifierFlags) {
        let now = flags.contains(.control) && flags.contains(.shift)
        guard now != held else { return }
        held = now
        onChange?(now)
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
        if case .icon(let id) = target {
            content.modifier(PresentedIconTransform(scale: scale, shift: shift, edge: edge) { scale, shift in
                guard magnifier.labelTargetID == id else { return }
                DispatchQueue.main.async {
                    guard magnifier.labelTargetID == id else { return }
                    magnifier.onIconPresented?(id, scale, shift)
                }
            })
        } else if case .hitArea(let id) = target {
            // Real frame changes (not a render transform): AppKit hit-tests
            // and anchors the menu with the view's frame.
            let grow = magnifier.layout.growths[id] ?? 0
            let shift = magnifier.layout.shifts[id] ?? 0
            switch edge {
            case .bottom:
                content.padding(.top, -grow).padding(.horizontal, -grow / 2).offset(x: shift)
            case .left:
                content.padding(.trailing, -grow).padding(.vertical, -grow / 2).offset(y: shift)
            case .right:
                content.padding(.leading, -grow).padding(.vertical, -grow / 2).offset(y: shift)
            }
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

/// The icon and its label share the same interpolated spring values.
/// A separate window animation drifts when the cursor changes targets.
private struct PresentedIconTransform: GeometryEffect {
    var scale: CGFloat
    var shift: CGFloat
    let edge: DockEdge
    let report: (CGFloat, CGFloat) -> Void

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(scale, shift) }
        set { scale = newValue.first; shift = newValue.second }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        report(scale, shift)
        let anchor = edge.growthAnchor
        let x = size.width * anchor.x * (1 - scale) + (edge.isVertical ? 0 : shift)
        let y = size.height * anchor.y * (1 - scale) + (edge.isVertical ? shift : 0)
        return ProjectionTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
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
