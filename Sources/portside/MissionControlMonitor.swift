import AppKit
import os.log

/// Tells the engine when Mission Control or App Exposé opens and closes, so
/// the dock can step aside while the system shows the macOS Dock.
///
/// Both modes put a WindowManager "shield" window at level 19 over a whole
/// display. There is no public notification for that, so this listens to
/// WindowServer window events (create, destroy, order in/out, Space changes)
/// and checks for the shield when one arrives. Event driven: no timer runs
/// while nothing changes on screen.
///
/// Private API: SkyLight is opened with dlopen/dlsym. If anything is missing
/// or a subscription fails, this logs once and never reports a change, so the
/// dock keeps its normal behavior. The level and geometry are observed on
/// macOS 27, not a documented contract; see docs/ARCHITECTURE.md.
final class MissionControlMonitor {
    static let shared = MissionControlMonitor()

    private typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias Register = @convention(c) (Int32, Callback, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias Request = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, Int32) -> Int32
    private typealias WindowOwner = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias ConnectionPID = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias WindowLevel = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias WindowBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

    /// Created, destroyed, ordered in, ordered out, added to or removed from a Space.
    private static let events: [UInt32] = [811, 804, 815, 816, 1325, 1326]
    private static let orderedIn: UInt32 = 815
    private static let shieldLevel = 19
    private static let windowManager = "com.apple.WindowManager"

    private let logger = Logger(subsystem: "com.james.portside", category: "MissionControl")
    /// Guards state touched from SkyLight's callback thread.
    private let lock = NSLock()
    private var enabled = false
    private var queued = false
    private var registered = false
    private var connection: Int32 = 0
    private var request: Request?
    private var owner: WindowOwner?
    private var ownerPID: ConnectionPID?
    private var level: WindowLevel?
    private var bounds: WindowBounds?
    private var anchors = Set<UInt32>()
    private var watched = Set<UInt32>()
    /// When an order-in published active. The public window list lags it by
    /// one event burst, so a list read that disagrees right after is ignored.
    private var orderedInAt: TimeInterval?

    /// True while either mode is open. Main thread only.
    private(set) var isActive = false
    /// Called on the main thread when `isActive` changes.
    var onChange: ((Bool) -> Void)?

    /// Begin listening. `anchors` are Portside's own window numbers, which
    /// WindowServer needs before it delivers any window events.
    func start(anchors: [UInt32]) {
        self.anchors = Set(anchors)
        guard !registered else {
            setEnabled(true)
            check(reason: "restart")
            return
        }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main: MainConnection = symbol(handle, "SLSMainConnectionID"),
              let register: Register = symbol(handle, "SLSRegisterConnectionNotifyProc"),
              let request: Request = symbol(handle, "SLSRequestNotificationsForWindows") else {
            logger.error("SkyLight window events unavailable, dock stays up in Mission Control")
            return
        }
        // Optional: without these the slower window-list read still works.
        owner = symbol(handle, "SLSGetWindowOwner")
        ownerPID = symbol(handle, "SLSConnectionGetPID")
        level = symbol(handle, "SLSGetWindowLevel")
        bounds = symbol(handle, "SLSGetWindowBounds")
        self.request = request
        connection = main()
        for event in Self.events {
            let result = register(connection, { event, data, length, _, _ in
                // Window events carry the window number first (observed).
                var window: UInt32?
                if let data, length >= 4 { window = data.loadUnaligned(as: UInt32.self) }
                MissionControlMonitor.shared.receive(event, window: window)
            }, event, nil)
            guard result == 0 else {
                logger.error("SkyLight event \(event) subscription failed (\(result)), dock stays up in Mission Control")
                return
            }
        }
        // Registrations live as long as the process; stop() only mutes them.
        registered = true
        setEnabled(true)
        logger.info("listening for Mission Control and App Exposé")
        check(reason: "start")
    }

    func stop() {
        setEnabled(false)
        orderedInAt = nil
        publish(false, reason: "stopped")
    }

    private func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    private var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// SkyLight's callback thread.
    private func receive(_ event: UInt32, window: UInt32?) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let first = !queued
        queued = true
        lock.unlock()
        if event == Self.orderedIn, let window {
            // The shield's order-in names it directly, about 50 ms before it
            // shows in the window list. The Dock is still sliding in then.
            DispatchQueue.main.async { [self] in
                guard isEnabled, isShield(window) else { return }
                orderedInAt = ProcessInfo.processInfo.systemUptime
                publish(true, reason: "shield ordered in")
            }
        }
        guard first else { return }
        // One read now and one bounded settle read per burst: a new window
        // is not always on screen yet. Never a repeating timer.
        DispatchQueue.main.async { [self] in
            if isEnabled { check(reason: "window event") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            lock.lock()
            queued = false
            let running = enabled
            lock.unlock()
            if running { check(reason: "settle") }
        }
    }

    /// One window read straight from SkyLight: WindowManager, level 19,
    /// covering a display.
    private func isShield(_ window: UInt32) -> Bool {
        guard let owner, let ownerPID, let level, let bounds else { return false }
        var ownerConnection: Int32 = 0
        var pid: pid_t = 0
        var value: Int32 = 0
        var rect = CGRect.zero
        guard owner(connection, window, &ownerConnection) == 0, ownerPID(ownerConnection, &pid) == 0,
              level(connection, window, &value) == 0, Int(value) == Self.shieldLevel,
              bounds(connection, window, &rect) == 0,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Self.windowManager else { return false }
        return Self.coversDisplay(rect)
    }

    /// Public window list read. Also subscribes to Dock and WindowManager
    /// windows as they appear, so their events keep arriving.
    private func check(reason: String) {
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        var relevant = anchors
        var shield = false
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "WindowManager" || owner == "Dock" else { continue }
            if let number = window[kCGWindowNumber as String] as? NSNumber { relevant.insert(number.uint32Value) }
            guard owner == "WindowManager", !shield,
                  window[kCGWindowLayer as String] as? Int == Self.shieldLevel,
                  window[kCGWindowIsOnscreen as String] as? Bool == true,
                  let dict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            shield = Self.coversDisplay(rect)
        }
        if watched != relevant, let request {
            var numbers = Array(relevant)
            let result = request(connection, &numbers, Int32(numbers.count))
            if result == 0 {
                watched = relevant
            } else {
                logger.error("SkyLight window subscription failed (\(result)), dock stays up in Mission Control")
                stop()
                return
            }
        }
        if !shield, let orderedInAt, ProcessInfo.processInfo.systemUptime - orderedInAt < 0.15 { return }
        orderedInAt = nil
        publish(shield, reason: reason)
    }

    private static func coversDisplay(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let display = CGDisplayBounds(id.uint32Value)
            return display.width > 0 && rect.insetBy(dx: -1, dy: -1).contains(display)
        }
    }

    private func publish(_ active: Bool, reason: String) {
        guard active != isActive else { return }
        isActive = active
        logger.info("Mission Control or App Exposé \(active ? "opened" : "closed", privacy: .public) (\(reason, privacy: .public))")
        onChange?(active)
    }
}
