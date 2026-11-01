import AppKit
import ApplicationServices
import os.log

/// Fits other apps' windows clear of the pinned dock, the way apps shrink
/// to `visibleFrame` when the native Dock's hiding is off. Nothing can
/// shrink `visibleFrame` for other apps, so this watches window moves and
/// resizes through Accessibility and pulls back any window edge that sits
/// flush with the dock's screen edge (Rectangle Maximize, Window > Fill,
/// tiling). Windows placed partly over the dock by hand are left alone, like
/// the native Dock does.
///
/// Event-driven (`AXObserver`), no polling. AX calls block until the other
/// app answers, so all of it runs off the main thread: observers on their
/// own run loop thread, fitting on a serial queue with short AX timeouts.
/// The dock's reveal path never waits on another app.
///
/// Needs Accessibility. Without it, this logs once and does nothing.
final class WindowFitter {
    /// What a fitted window must stay clear of, in AX coordinates (origin at
    /// the top-left of the primary display, y grows down).
    private struct Target {
        let edge: DockEdge
        /// The dock's display.
        let screen: CGRect
        /// The coordinate a window's dock-side edge may reach: max y for the
        /// bottom, min x for the left, max x for the right.
        let limit: CGFloat
    }

    /// AXUIElement as a dictionary key (CFEqual / CFHash).
    private struct WindowKey: Hashable {
        let element: AXUIElement
        static func == (a: WindowKey, b: WindowKey) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// How close (points) a window edge must be to the screen edge to count
    /// as flush. Rectangle lands 1pt short on some layouts.
    private static let flushTolerance: CGFloat = 2
    /// Quiet time after a window's last move/resize before fitting it.
    /// Rectangle sends a follow-up move right after its resize, so fitting
    /// on the first event gets overwritten.
    private static let settleDelay: DispatchTimeInterval = .milliseconds(60)
    /// Quiet time after an animated change (Window > Fill sends about 40
    /// resizes 8ms apart) or a re-fit. macOS keeps re-applying Fill's frame
    /// for 150 to 300ms after its last AX event (measured).
    private static let animatedSettleDelay: DispatchTimeInterval = .milliseconds(300)
    /// More events than this in one burst means an animation.
    private static let animatedBurst = 4
    /// Longest a single AX call may block on an unresponsive app.
    private static let axTimeout: Float = 0.25
    /// Below this, a fitted window would be useless; leave it alone.
    private static let minimumLength: CGFloat = 120

    private let logger = Logger(subsystem: "com.james.portside", category: "WindowFitter")
    private let queue = DispatchQueue(label: "com.james.portside.windowfit", qos: .userInitiated)
    private var observerRunLoop: CFRunLoop?

    // Main thread only.
    private var reservation: Reservation?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var running = false
    private var loggedUntrusted = false

    // `queue` only.
    private var target: Target?
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: [WindowKey: DispatchWorkItem] = [:]
    /// Windows that did not take the fitted frame, with the attempt count.
    /// After two, they are left alone (an app enforcing its own size).
    private var refusals: [WindowKey: Int] = [:]
    /// Events since the window's last fit check.
    private var burstCounts: [WindowKey: Int] = [:]
    /// Recent fit times per window, to spot an app resetting its size.
    private var recentFits: [WindowKey: [CFTimeInterval]] = [:]

    init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.observerRunLoop = CFRunLoopGetCurrent()
            ready.signal()
            // Keeps the run loop alive with no sources attached yet.
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "com.james.portside.windowfit.observers"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    // MARK: - Main thread API

    /// The dock's reservation changed (nil: nothing reserved). Starts or
    /// stops watching windows.
    func setReservation(_ new: Reservation?) {
        dispatchPrecondition(condition: .onQueue(.main))
        reservation = new
        guard let new else {
            stop(reason: "reservation off")
            return
        }
        guard AXIsProcessTrusted() else {
            if !loggedUntrusted {
                loggedUntrusted = true
                logger.info("Accessibility not granted, windows are not fitted to the dock")
            }
            stop(reason: "no Accessibility")
            return
        }
        loggedUntrusted = false
        let target = Self.target(for: new)
        queue.async { self.target = target }
        start()
    }

    private func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watch(app)
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self?.queue.async { self?.unwatch(pid) }
        })
        // The primary display's height anchors AX coordinates.
        workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let reservation = self.reservation else { return }
            let target = Self.target(for: reservation)
            self.queue.async { self.target = target }
        })
        let apps = NSWorkspace.shared.runningApplications
        apps.forEach(watch)
        logger.info("watching windows of \(apps.filter(Self.isWatchable).count) apps")
    }

    private func stop(reason: String) {
        guard running else { return }
        running = false
        workspaceObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        workspaceObservers = []
        queue.async {
            self.target = nil
            for pid in Array(self.observers.keys) { self.unwatch(pid) }
            self.pending.values.forEach { $0.cancel() }
            self.pending = [:]
            self.refusals = [:]
            self.burstCounts = [:]
            self.recentFits = [:]
        }
        logger.info("stopped watching windows (\(reason, privacy: .public))")
    }

    private static func isWatchable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    private func watch(_ app: NSRunningApplication) {
        guard Self.isWatchable(app) else { return }
        let pid = app.processIdentifier
        queue.async { self.attach(pid: pid, attempt: 0) }
    }

    /// Reservation (AppKit coordinates) to AX coordinates.
    private static func target(for r: Reservation) -> Target {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? r.screenFrame.maxY
        let s = r.screenFrame
        let screen = CGRect(x: s.minX, y: primaryTop - s.maxY, width: s.width, height: s.height)
        let limit: CGFloat = switch r.edge {
        case .bottom: screen.maxY - r.depth
        case .left: screen.minX + r.depth
        case .right: screen.maxX - r.depth
        }
        return Target(edge: r.edge, screen: screen, limit: limit)
    }

    // MARK: - Observers (queue)

    private func attach(pid: pid_t, attempt: Int) {
        guard target != nil, observers[pid] == nil, let runLoop = observerRunLoop else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, windowFitterCallback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notReady = false
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            let result = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if result == .cannotComplete { notReady = true }
        }
        if notReady {
            // A just-launched app answers AX only once it finishes launching.
            if attempt < 10 {
                queue.asyncAfter(deadline: .now() + .milliseconds(300)) { self.attach(pid: pid, attempt: attempt + 1) }
            }
            return
        }
        observers[pid] = observer
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        CFRunLoopWakeUp(runLoop)
    }

    private func unwatch(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        if let runLoop = observerRunLoop {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        refusals = refusals.filter { key, _ in
            var owner: pid_t = 0
            return AXUIElementGetPid(key.element, &owner) == .success && owner != pid
        }
    }

    /// Observer thread: a window was created, moved, or resized.
    fileprivate func windowChanged(_ element: AXUIElement) {
        queue.async {
            guard self.target != nil else { return }
            let key = WindowKey(element: element)
            self.pending[key]?.cancel()
            let count = (self.burstCounts[key] ?? 0) + 1
            self.burstCounts[key] = count
            // Fitted moments ago and changed again: macOS (or the app) is
            // still settling it, so wait longer before the next try.
            let refit = self.recentFits[key]?.last.map { CACurrentMediaTime() - $0 < 1 } ?? false
            let delay = count > Self.animatedBurst || refit ? Self.animatedSettleDelay : Self.settleDelay
            let work = DispatchWorkItem { [weak self] in
                self?.pending[key] = nil
                self?.burstCounts[key] = nil
                self?.fit(element, key: key)
            }
            self.pending[key] = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - Fitting (queue)

    private func fit(_ window: AXUIElement, key: WindowKey) {
        guard let target, (refusals[key] ?? 0) < 2 else { return }
        AXUIElementSetMessagingTimeout(window, Self.axTimeout)
        guard Self.string(window, kAXRoleAttribute) == kAXWindowRole,
              Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              Self.bool(window, "AXFullScreen") != true,
              Self.bool(window, kAXMinimizedAttribute) != true,
              let frame = Self.frame(window),
              target.screen.contains(CGPoint(x: frame.midX, y: frame.midY)),
              let fitted = Self.fitted(frame, to: target)
        else { return }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else { return }

        let started = CACurrentMediaTime()
        // Size first: moving a left-flush window right before shrinking it
        // would push its far edge off screen, where the app may clamp it.
        Self.setSize(window, fitted.size)
        if fitted.origin != frame.origin { Self.setPosition(window, fitted.origin) }
        let ms = (CACurrentMediaTime() - started) * 1000

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        if let result = Self.frame(window), Self.fitted(result, to: target) == nil {
            let now = CACurrentMediaTime()
            recentFits = recentFits.compactMapValues { times in
                let kept = times.filter { now - $0 < 2 }
                return kept.isEmpty ? nil : kept
            }
            recentFits[key, default: []].append(now)
            if recentFits[key]!.count >= 3 {
                // Took the frame, then reset itself, three times in 2s.
                refusals[key] = 2
                logger.info("\(app, privacy: .public) window keeps resetting its size, leaving it alone")
                return
            }
            logger.info("fitted \(app, privacy: .public) window to the \(target.edge.rawValue, privacy: .public) dock: \(Int(frame.width))x\(Int(frame.height)) -> \(Int(result.width))x\(Int(result.height)) in \(ms, format: .fixed(precision: 1))ms")
        } else {
            refusals[key, default: 0] += 1
            logger.info("\(app, privacy: .public) window refused the fitted frame (attempt \(self.refusals[key] ?? 0))")
        }
    }

    /// The frame `frame` should have, or nil if it is not flush with the
    /// dock's screen edge (or already clear of the dock).
    private static func fitted(_ frame: CGRect, to t: Target) -> CGRect? {
        let tol = flushTolerance
        var r = frame
        switch t.edge {
        case .bottom:
            guard frame.maxY >= t.screen.maxY - tol, frame.maxY > t.limit + 0.5 else { return nil }
            r.size.height = t.limit - frame.minY
            guard r.height >= minimumLength else { return nil }
        case .left:
            guard frame.minX <= t.screen.minX + tol, frame.minX < t.limit - 0.5 else { return nil }
            r.origin.x = t.limit
            r.size.width = frame.maxX - t.limit
            guard r.width >= minimumLength else { return nil }
        case .right:
            guard frame.maxX >= t.screen.maxX - tol, frame.maxX > t.limit + 0.5 else { return nil }
            r.size.width = t.limit - frame.minX
            guard r.width >= minimumLength else { return nil }
        }
        return r
    }

    // MARK: - AX helpers

    private static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        value(el, name) as? String
    }

    private static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (value(el, name) as? NSNumber)?.boolValue
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    private static func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }
}

/// AXObserver callback (a C function pointer, so it cannot capture).
private func windowFitterCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowFitter>.fromOpaque(refcon).takeUnretainedValue().windowChanged(element)
}
