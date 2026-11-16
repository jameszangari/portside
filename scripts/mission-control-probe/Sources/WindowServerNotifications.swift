import AppKit
import Darwin

/// Private symbols stay in this diagnostic file, dynamically loaded or disabled.
/// Process-lifetime storage keeps late C callbacks safe while the probe exits.
final class WindowServerNotifications {
    static let shared = WindowServerNotifications()
    private typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Connection = @convention(c) () -> Int32
    private typealias Register = @convention(c) (Int32, Callback, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias Request = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> Int32
    private let lock = NSLock()
    private var enabled = false
    private var queued = false
    private var counts: [UInt32: Int] = [:]
    private var handle: UnsafeMutableRawPointer?
    private var request: Request?
    private var connection: Int32 = 0
    private var anchors = Set<UInt32>()
    private var watched = Set<UInt32>()
    private var active: Bool?
    private var samples = 0
    var changed: (Bool) -> Void = { _ in }

    func start(anchors: [UInt32]) {
        guard handle == nil else { return }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
            ProbeLog.write("DETECT unavailable: SkyLight could not be loaded; use default visual probe")
            return
        }
        self.handle = handle
        guard let main: Connection = symbol("SLSMainConnectionID"),
              let register: Register = symbol("SLSRegisterConnectionNotifyProc"),
              let request: Request = symbol("SLSRequestNotificationsForWindows") else {
            ProbeLog.write("DETECT unavailable: notification symbols missing; use default visual probe")
            return
        }
        self.request = request
        connection = main()
        self.anchors = Set(anchors)
        guard !self.anchors.isEmpty else {
            ProbeLog.write("DETECT unavailable: no probe window to seed notifications")
            return
        }
        // Create/destroy, order in/out, and added/removed from a Space.
        for event: UInt32 in [811, 804, 815, 816, 1325, 1326] {
            let result = register(connection, { event, data, length, _, _ in
                // Window events carry the window number first (observed, not documented).
                var window: UInt32?
                if let data, length >= 4 { window = data.loadUnaligned(as: UInt32.self) }
                WindowServerNotifications.shared.receive(event, window: window, length: length)
            }, event, nil)
            ProbeLog.write("WINDOWSERVER subscribe event=\(event) result=\(result)")
            guard result == 0 else {
                ProbeLog.write("DETECT unavailable: subscription failed; use default visual probe")
                return
            }
        }
        lock.lock()
        enabled = true
        lock.unlock()
        sample(reason: "startup")
    }

    private func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private func receive(_ event: UInt32, window: UInt32?, length: Int) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        if trace, let window {
            DispatchQueue.main.async { Self.describe(event: event, window: window, length: length) }
        }
        if event == 815, let window {
            // The shield's order-in names it directly, about one settle read
            // before it appears in the public window list.
            DispatchQueue.main.async { [self] in
                lock.lock()
                let running = enabled
                lock.unlock()
                if running, isShield(window) {
                    orderedInAt = ProcessInfo.processInfo.systemUptime
                    publish(true, reason: "order-in")
                }
            }
        }
        counts[event, default: 0] += 1
        let shouldQueue = !queued
        queued = true
        lock.unlock()
        guard shouldQueue else { return }
        // Read at once, since the Dock starts sliding in during a trackpad
        // gesture. A created surface may not be on screen yet, so one bounded
        // settle read follows per burst, never a repeating timer or a retry.
        DispatchQueue.main.async { [self] in
            lock.lock()
            let running = enabled
            lock.unlock()
            if running { sample(reason: "window event") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            lock.lock()
            queued = false
            let running = enabled
            lock.unlock()
            if running { sample(reason: "settle") }
        }
    }

    private let trace = ProcessInfo.processInfo.environment["PROBE_TRACE"] != nil

    /// Looks up one window by number, without scanning the full list.
    static func describe(event: UInt32, window: UInt32, length: Int) {
        let ids = [window] as CFArray
        let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first
        let owner = info?[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = info?[kCGWindowLayer as String] as? Int ?? -1
        let on = info?[kCGWindowIsOnscreen as String] as? Bool ?? false
        var size = "?"
        if let dict = info?[kCGWindowBounds as String] as? [String: Any],
           let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) { size = "\(bounds.width)x\(bounds.height)" }
        ProbeLog.write("TRACE event=\(event) len=\(length) window=\(window) owner=\(owner) layer=\(layer) size=\(size) on=\(on) sls={\(shared.direct(window))}")
    }

    private typealias Owner = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias PID = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias Level = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Bounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

    private var orderedInAt: TimeInterval?

    /// A WindowManager window at level 19 covering a display, read directly.
    private func isShield(_ window: UInt32) -> Bool {
        guard let owner: Owner = symbol("SLSGetWindowOwner"), let pid: PID = symbol("SLSConnectionGetPID"),
              let level: Level = symbol("SLSGetWindowLevel"), let bounds: Bounds = symbol("SLSGetWindowBounds") else { return false }
        var cid: Int32 = 0
        var process: pid_t = 0
        var value: Int32 = 0
        var rect = CGRect.zero
        guard owner(connection, window, &cid) == 0, pid(cid, &process) == 0,
              level(connection, window, &value) == 0, bounds(connection, window, &rect) == 0,
              NSRunningApplication(processIdentifier: process)?.bundleIdentifier == "com.apple.WindowManager" else { return false }
        return OverlayPresence.isActive([.init(owner: "WindowManager", layer: Int(value), bounds: rect, onScreen: true)],
                                        displays: displayBounds())
    }

    private func displayBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
    }

    /// Direct per-window SkyLight reads; trace only, each symbol optional.
    func direct(_ window: UInt32) -> String {
        var parts: [String] = []
        if let owner: Owner = symbol("SLSGetWindowOwner") {
            var cid: Int32 = 0
            let result = owner(connection, window, &cid)
            var name = "?"
            if result == 0, let pid: PID = symbol("SLSConnectionGetPID") {
                var value: pid_t = 0
                if pid(cid, &value) == 0 { name = NSRunningApplication(processIdentifier: value)?.bundleIdentifier ?? "pid \(value)" }
            }
            parts.append("owner=\(name) r=\(result)")
        }
        if let level: Level = symbol("SLSGetWindowLevel") {
            var value: Int32 = 0
            let result = level(connection, window, &value)
            parts.append("level=\(value) r=\(result)")
        }
        if let bounds: Bounds = symbol("SLSGetWindowBounds") {
            var rect = CGRect.zero
            let result = bounds(connection, window, &rect)
            parts.append("bounds=\(rect.width)x\(rect.height)@\(rect.minX),\(rect.minY) r=\(result)")
        }
        return parts.joined(separator: " ")
    }

    func displaysChanged(anchors: [UInt32]) {
        self.anchors = Set(anchors)
        lock.lock()
        let running = enabled
        lock.unlock()
        if running { sample(reason: "display change") }
    }

    private func sample(reason: String) {
        samples += 1
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            ProbeLog.write("DETECT window list unavailable; hiding probe panels")
            publish(false, reason: "query failed")
            return
        }
        var relevant = anchors
        var surfaces: [OverlayPresence.Surface] = []
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "WindowManager" || owner == "Dock" else { continue }
            if let number = window[kCGWindowNumber as String] as? NSNumber { relevant.insert(number.uint32Value) }
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let dict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            surfaces.append(.init(owner: owner, layer: layer, bounds: bounds,
                                  onScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        if watched != relevant, let request {
            var numbers = Array(relevant)
            let result = request(connection, &numbers, Int32(numbers.count))
            guard result == 0 else {
                ProbeLog.write("DETECT window subscription failed result=\(result); stopping detection")
                stop()
                publish(false, reason: "subscription failed")
                return
            }
            watched = relevant
        }
        let displays = displayBounds()
        if ProcessInfo.processInfo.environment["PROBE_TRACE"] != nil {
            let shields = surfaces.filter { $0.owner == "WindowManager" && $0.layer == 19 }
                .map { "\($0.bounds.width)x\($0.bounds.height) on=\($0.onScreen)" }
            ProbeLog.write("TRACE \(reason) wm19=\(shields)")
        }
        let detected = OverlayPresence.isActive(surfaces, displays: displays)
        // The public list can lag an order-in; do not drop it for a short grace.
        if !detected, let orderedInAt, ProcessInfo.processInfo.systemUptime - orderedInAt < 0.15 {
            if trace { ProbeLog.write("TRACE \(reason) list lags order-in; keeping active") }
            return
        }
        orderedInAt = nil
        publish(detected, reason: reason)
    }

    private func publish(_ next: Bool, reason: String) {
        guard next != active else { return }
        active = next
        ProbeLog.write("OVERLAY \(next ? "ACTIVE" : "INACTIVE") source=\(reason) samples=\(samples)")
        changed(next)
    }

    func stop() {
        lock.lock()
        enabled = false
        let totals = counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        lock.unlock()
        ProbeLog.write("WINDOWSERVER stopped samples=\(samples) events={\(totals)}")
        // The executable now exits. Its connection and subscriptions die with
        // it; the handle and singleton remain alive until then for late callbacks.
    }
}
