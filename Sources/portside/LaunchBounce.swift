import AppKit
import QuartzCore
import os.log

/// Native-style launch bounce for pinned app tiles in the strip (any edge)
/// and app cells in an open group grid. The icon always bounces away from
/// the screen edge: up on the bottom dock, sideways on the side docks.
///
/// The dock panel has only a few points of room above the icons, so a
/// SwiftUI offset would clip. Instead the bouncing icon is drawn in its own
/// click-through window sitting over the tile, and the tile hides its icon
/// while that window is up. The tile keeps its slot and its click target, so
/// neighbors never move.
///
/// With magnification on, a strip tile bounces at its magnified size and
/// keeps following the magnifier (size and slot, with the same spring), so
/// clicking an app never makes the dock jump back to normal size.
///
/// Event driven: Core Animation runs the bounce (repeat count = safety cap),
/// and the launch is followed with KVO on `NSRunningApplication` plus the
/// workspace launch notification. No timers.
///
/// React analogy: a portal plus a tiny store. `bouncingID` is the state the
/// tile subscribes to; the window is the portal content.
final class LaunchBouncer: ObservableObject {
    /// Key of the tile that is bouncing (`BounceTarget.key`). The tile hides
    /// its icon while set.
    @Published private(set) var bouncingID: String?

    /// What bounces: where its icon is on screen, and which window level the
    /// bounce window needs to sit above it.
    struct BounceTarget {
        /// Strip tiles use the app id; grid cells use `gridKey`.
        let key: String
        let level: NSWindow.Level
        /// The icon's screen rect for an icon size, or nil if it is gone.
        /// Strip tiles return their drawn (maybe magnified) icon instead.
        let iconFrame: (CGFloat) -> NSRect?
    }

    static func gridKey(groupID: String, appID: String) -> String {
        "grid:\(groupID)/\(appID)"
    }

    /// Measured from a screen recording of the native Dock (macOS 27, 37pt
    /// tiles): each bounce is a plain parabola, like a ball thrown straight
    /// up. Slow at the top, rebounds off the dock with no pause or settle.
    /// Fitted period 0.700s, peak 12.2pt (0.33 of the tile), error 0.3pt.
    static let cycleDuration: CFTimeInterval = 0.70
    /// Peak height as a fraction of the icon size.
    static let heightRatio: CGFloat = 12.2 / 37
    /// Safety cap: 14 bounces (9.8s), then stop even if the app never
    /// reports it finished launching.
    static let maxCycles: Float = 14

    private let dockModel: DockModel
    private let hover: DockHover
    /// Magnification: the largest size a strip icon can be drawn at (0 when
    /// off), how far it can move while bouncing, and the spring of the
    /// latest change (nil: instant).
    var magnifiedDrawSize: (() -> CGFloat)?
    var magnifiedReach: (() -> CGFloat)?
    var magnifyMotion: (() -> MagnifyMotion?)?
    private let window: NSPanel
    private let iconLayer = CALayer()
    private let logger = Logger(subsystem: "com.james.portside", category: "LaunchBounce")

    private var app: PinnedApp?
    private var target: BounceTarget?
    /// Edge the bounce started on. It points away from this edge.
    private var edge: DockEdge = .bottom
    /// Called once when this bounce ends; true if it landed (launched or
    /// safety cap), false if it was cut short.
    private var onEnd: ((Bool) -> Void)?
    private var tileSize: CGFloat = 0
    /// Bounce height, fixed when the bounce starts.
    private var peak: CGFloat = 0
    /// Size the icon bitmap was drawn for.
    private var renderedSize: CGFloat = 0
    private var startedAt: CFTimeInterval = 0
    /// Layer time the bounce animation began, so a shortened copy keeps its phase.
    private var animationBegin: CFTimeInterval = 0
    /// Incremented per bounce so stale completions and callbacks are ignored.
    private var generation = 0
    private var isStopping = false
    private var observations: [NSKeyValueObservation] = []
    /// Held while observed: if it deallocates with KVO observers attached,
    /// AppKit throws (seen as a crash on the first launch).
    private var launchingApp: NSRunningApplication?
    private var launchObserver: NSObjectProtocol?

    private static let animationKey = "launchBounce"

    init(dockModel: DockModel, hover: DockHover) {
        self.dockModel = dockModel
        self.hover = hover
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // Same level as the edge window (above the dock panel, below labels).
        window.level = EdgeTracker.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true

        let content = NSView(frame: .zero)
        content.wantsLayer = true
        content.layer?.addSublayer(iconLayer)
        iconLayer.contentsGravity = .resize
        iconLayer.anchorPoint = .zero
        window.contentView = content
    }

    // MARK: - Start

    /// A pinned strip tile was clicked and its app is not running. Starts the
    /// bounce if it applies, then launches the app either way.
    /// With `documents`, the app opens them once launched (a file drop).
    func launch(_ app: PinnedApp, size: CGFloat, documents: [URL] = [],
                afterOpen: ((NSRunningApplication?) -> Void)? = nil) {
        launch(app, size: size, target: stripTarget(for: app), documents: documents, afterOpen: afterOpen)
    }

    /// Launches a not-running app and bounces `target` while it starts, if
    /// the setting and Reduce Motion allow. True if the bounce is running.
    @discardableResult
    func launch(_ app: PinnedApp, size: CGFloat, target: BounceTarget, documents: [URL] = [],
                afterOpen: ((NSRunningApplication?) -> Void)? = nil,
                onEnd: ((Bool) -> Void)? = nil) -> Bool {
        let bounces = shouldBounce(target)
        if bounces { start(app, size: size, target: target, onEnd: onEnd) }
        let myGeneration = generation
        AppLauncher.open(app, running: nil, documents: documents) { [weak self] result, error in
            if error == nil { afterOpen?(result) }
            guard bounces, let self, myGeneration == self.generation else { return }
            self.launchResult(result, error: error)
        }
        return bouncingID == target.key
    }

    /// Whether a click would bounce right now (setting on, no Reduce Motion).
    var isEnabled: Bool {
        dockModel.animateOpeningApplications && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func shouldBounce(_ target: BounceTarget) -> Bool {
        // A second click while it is still launching does not restart it.
        isEnabled && bouncingID != target.key
    }

    /// The tile's icon in the strip. The running dot sits between the icon
    /// and the screen edge, so the icon is the far `size` points of the tile.
    private func stripTarget(for app: PinnedApp) -> BounceTarget {
        BounceTarget(key: app.id, level: EdgeTracker.windowLevel) { [weak hover] _ in
            // The drawn frame: magnified tiles bounce at their magnified size.
            guard let hover, let tile = hover.displayScreenFrame(forTargetID: app.id) else { return nil }
            let size = hover.edge.isVertical ? tile.height : tile.width
            switch hover.edge {
            case .bottom: return NSRect(x: tile.midX - size / 2, y: tile.maxY - size, width: size, height: size)
            case .left: return NSRect(x: tile.maxX - size, y: tile.midY - size / 2, width: size, height: size)
            case .right: return NSRect(x: tile.minX, y: tile.midY - size / 2, width: size, height: size)
            }
        }
    }

    private func start(_ app: PinnedApp, size: CGFloat, target: BounceTarget, onEnd: ((Bool) -> Void)?) {
        cancel(reason: "another app clicked")
        generation += 1
        self.app = app
        self.target = target
        self.onEnd = onEnd
        edge = hover.edge
        tileSize = size
        isStopping = false
        startedAt = CACurrentMediaTime()
        // Above whatever the tile lives in (dock panel or group overlay).
        window.level = target.level
        let drawn = target.iconFrame(size).map { max($0.width, $0.height) } ?? size
        peak = drawn * Self.heightRatio
        guard place(animated: false) else {
            logger.info("bounce skipped for \(app.displayName, privacy: .public): tile not on screen")
            self.app = nil
            self.target = nil
            self.onEnd = nil
            return
        }

        renderIcon()
        window.orderFrontRegardless()
        bouncingID = target.key

        animationBegin = iconLayer.convertTime(CACurrentMediaTime(), from: nil)
        addAnimation(repeatCount: Self.maxCycles)
        observeWorkspaceLaunch(of: app)
        let kind = Self.isGridKey(target.key) ? "grid cell" : "strip tile"
        logger.info("bounce started: \(app.displayName, privacy: .public) \(kind, privacy: .public) at \(drawn, format: .fixed(precision: 0))pt (tile \(size, format: .fixed(precision: 0))pt) on the \(self.edge.rawValue, privacy: .public) edge")
    }

    /// Unit vector the icon moves along at the top of a bounce (layer
    /// coordinates, y up): away from the screen edge.
    private var direction: CGVector {
        switch edge {
        case .bottom: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: 1, dy: 0)
        case .right: CGVector(dx: -1, dy: 0)
        }
    }

    // MARK: - Animation

    private func addAnimation(repeatCount: Float) {
        let vertical = direction.dy != 0
        let peak = self.peak * (vertical ? direction.dy : direction.dx)
        let anim = CAKeyframeAnimation(keyPath: vertical ? "transform.translation.y" : "transform.translation.x")
        anim.values = [0, peak, 0]
        anim.keyTimes = [0, 0.5, 1]
        // These two curves are exact parabolas: y = 1 - (1 - x)^2 going up,
        // y = x^2 coming down.
        anim.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 1.0 / 3, 2.0 / 3, 2.0 / 3, 1),
            CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1.0 / 3),
        ]
        anim.duration = Self.cycleDuration
        anim.repeatCount = repeatCount
        anim.beginTime = animationBegin
        anim.isRemovedOnCompletion = true
        let myGeneration = generation
        anim.delegate = AnimationEnd { [weak self] finished in
            // A replaced animation reports finished == false; only a real end counts.
            guard finished, let self, myGeneration == self.generation else { return }
            self.finish(reason: self.isStopping ? "launched" : "safety cap", landed: true)
        }
        iconLayer.add(anim, forKey: Self.animationKey)
    }

    /// Let the bounce in progress land, then stop. Swaps the running animation
    /// for a copy with the same start time and just enough repeats.
    private func stopAfterCurrentBounce(reason: String) {
        guard app != nil, !isStopping else { return }
        isStopping = true
        let now = iconLayer.convertTime(CACurrentMediaTime(), from: nil)
        let done = max(1, ((now - animationBegin) / Self.cycleDuration).rounded(.up))
        let ms = (CACurrentMediaTime() - startedAt) * 1000
        logger.info("\(reason, privacy: .public) after \(ms, format: .fixed(precision: 0))ms, landing after bounce \(Int(done))")
        guard Float(done) < Self.maxCycles else { return }
        addAnimation(repeatCount: Float(done))
    }

    // MARK: - Launch tracking

    private func observeWorkspaceLaunch(of app: PinnedApp) {
        let myGeneration = generation
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, myGeneration == self.generation,
                  let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.matches(running, app) else { return }
            self.stopAfterCurrentBounce(reason: "launch notification")
        }
    }

    /// `openApplication` finished (on the main queue). The app may still be
    /// starting up, so follow `isFinishedLaunching`.
    private func launchResult(_ running: NSRunningApplication?, error: Error?) {
        guard let running, error == nil else {
            cancel(reason: "launch failed")
            return
        }
        if running.isFinishedLaunching {
            stopAfterCurrentBounce(reason: "finished launching")
            return
        }
        launchingApp = running
        let myGeneration = generation
        let check: (NSRunningApplication) -> Void = { [weak self] running in
            DispatchQueue.main.async {
                guard let self, myGeneration == self.generation else { return }
                if running.isTerminated {
                    self.cancel(reason: "app quit while launching")
                } else if running.isFinishedLaunching {
                    self.stopAfterCurrentBounce(reason: "finished launching")
                }
            }
        }
        observations = [
            running.observe(\.isFinishedLaunching, options: [.initial, .new]) { app, _ in check(app) },
            running.observe(\.isTerminated, options: [.new]) { app, _ in check(app) },
        ]
    }

    private static func matches(_ running: NSRunningApplication, _ app: PinnedApp) -> Bool {
        if let id = app.bundleIdentifier, running.bundleIdentifier == id { return true }
        return running.bundleURL?.path == app.path
    }

    // MARK: - Placement

    /// Puts the window over the tile's icon, with headroom on the side the
    /// bounce goes. False if the tile is gone or off screen. `animated`:
    /// the icon moves with the magnifier's spring (it grew or shifted).
    @discardableResult
    private func place(animated: Bool) -> Bool {
        guard let target, let icon = target.iconFrame(tileSize) else { return false }
        let headroom = peak.rounded() + 2
        let travel = direction
        // The icon plus the space it travels through.
        let reach = icon.union(icon.offsetBy(dx: travel.dx * headroom, dy: travel.dy * headroom))
        var frame = window.frame
        let moveWindow = !frame.contains(reach)
        if moveWindow {
            // While magnifying, room all around for the icon to grow and
            // slide without moving the window (the layer animates inside it).
            let slack = Self.isGridKey(target.key) ? 0 : (magnifiedReach?() ?? 0)
            let room = reach.insetBy(dx: -slack, dy: -slack)
            // Tiles can sit on half points. The window server rounds window
            // frames to whole points, so the window takes the whole part and
            // the layer the fraction; otherwise the icon lands half a point
            // off and visibly ticks when the tile's own icon comes back.
            let origin = NSPoint(x: room.minX.rounded(.down), y: room.minY.rounded(.down))
            frame = NSRect(x: origin.x, y: origin.y, width: room.width.rounded(.up) + 1, height: room.height.rounded(.up) + 1)
            window.setFrame(frame, display: false)
        }
        let layerFrame = CGRect(x: icon.minX - frame.minX, y: icon.minY - frame.minY, width: icon.width, height: icon.height)
        let motion = animated && !moveWindow ? magnifyMotion?() : nil
        let from = iconLayer.presentation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = layerFrame
        CATransaction.commit()
        if let motion, let from {
            // Same spring as the tiles, from where the icon is drawn now.
            let position = motion.caSpring(keyPath: "position")
            position.fromValue = NSValue(point: from.position)
            position.toValue = NSValue(point: iconLayer.position)
            iconLayer.add(position, forKey: "magnify.position")
            let bounds = motion.caSpring(keyPath: "bounds")
            bounds.fromValue = NSValue(rect: from.bounds)
            bounds.toValue = NSValue(rect: iconLayer.bounds)
            iconLayer.add(bounds, forKey: "magnify.bounds")
        } else {
            iconLayer.removeAnimation(forKey: "magnify.position")
            iconLayer.removeAnimation(forKey: "magnify.bounds")
        }
        return true
    }

    /// Tile frames changed (items added, removed, reordered, dock resized,
    /// grid moved). Follows the tile, or stops if it is gone.
    func tilesChanged() {
        guard app != nil else { return }
        if !place(animated: false) { cancel(reason: "tile removed") }
    }

    /// The magnifier grew, shrank or shifted the tiles. A bouncing strip
    /// tile follows with the same spring.
    func magnificationChanged() {
        guard app != nil, let target, !Self.isGridKey(target.key) else { return }
        if !place(animated: true) { cancel(reason: "tile removed") }
    }

    /// Strip icon size changed while bouncing (grid cells keep their size).
    func tileSizeChanged(_ size: CGFloat) {
        guard app != nil, let target, !Self.isGridKey(target.key), size != tileSize else { return }
        tileSize = size
        renderIcon()
        tilesChanged()
    }

    /// Draws the icon at exactly the tile's pixel size with high quality
    /// interpolation, like the tile's own SwiftUI image. Letting the layer
    /// scale the large cached bitmap itself (bilinear) looked slightly
    /// different, which showed as a shimmer when the bounce handed back to
    /// the tile.
    /// While magnification is on, a strip tile can grow, so its icon is
    /// drawn at the magnified size and the layer scales it down (trilinear).
    private func renderIcon() {
        guard let app, let target else { return }
        let source = IconCache.shared.icon(for: app.url)
        let scale = DockScreen.backingScale
        let magnified = Self.isGridKey(target.key) ? 0 : (magnifiedDrawSize?() ?? 0)
        renderedSize = max(tileSize, magnified)
        let pixels = Int((renderedSize * scale).rounded())
        var image: Any = source
        if pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            graphics.imageInterpolation = .high
            NSGraphicsContext.current = graphics
            source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            if let bitmap = context.makeImage() { image = bitmap }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = image
        iconLayer.contentsScale = scale
        iconLayer.minificationFilter = renderedSize > tileSize ? .trilinear : .linear
        CATransaction.commit()
    }

    // MARK: - Stop

    /// Stop right away and put everything back (dock hiding, dock moved,
    /// setting turned off, launch failed, tile removed).
    func cancel(reason: String) {
        guard app != nil else { return }
        finish(reason: reason)
    }

    /// The group grid is closing or switching groups: stop a grid cell's
    /// bounce right away. Strip bounces keep going.
    func cancelGridBounce(reason: String) {
        guard app != nil, let target, Self.isGridKey(target.key) else { return }
        finish(reason: reason)
    }

    private static func isGridKey(_ key: String) -> Bool { key.hasPrefix("grid:") }

    private func finish(reason: String, landed: Bool = false) {
        guard let app else { return }
        let ms = (CACurrentMediaTime() - startedAt) * 1000
        logger.info("bounce ended (\(reason, privacy: .public)): \(app.displayName, privacy: .public) after \(ms, format: .fixed(precision: 0))ms")
        generation += 1
        self.app = nil
        target = nil
        let ended = onEnd
        onEnd = nil
        isStopping = false
        observations.forEach { $0.invalidate() }
        observations = []
        launchingApp = nil
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        iconLayer.removeAllAnimations()
        bouncingID = nil
        if landed {
            // The icon is at rest over the tile's own icon, so keep it one more
            // main loop turn while the tile redraws its icon (no blank frame).
            let myGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, myGeneration == self.generation else { return }
                self.window.orderOut(nil)
            }
        } else {
            window.orderOut(nil)
        }
        // Last, with all state cleared, so the callback can start anything.
        ended?(landed)
    }
}

/// Closure-based `CAAnimationDelegate` (the animation retains it).
private final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let handler: (Bool) -> Void
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { handler(flag) }
}
