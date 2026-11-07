import AppKit
import ApplicationServices
import Combine

/// AXUIElement as a dictionary key (CFEqual / CFHash): the registry's window handle.
struct AXElementKey: Hashable {
    let element: AXUIElement
    static func == (a: AXElementKey, b: AXElementKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Windows through public Accessibility calls, for `WindowRegistry`. Reads
/// use a short messaging timeout and give up on the whole app at the first
/// timeout, so a hung app costs one timeout per read. Observers live on one
/// run loop thread of their own, started on first use.
///
/// Watches window create, close, title, minimize and focus changes only.
/// Move and resize stay with `WindowFitter`, which owns its own observers.
final class AXWindowSource: WindowSource, @unchecked Sendable {
    /// Longest a single AX call may block on an unresponsive app.
    static let axTimeout: Float = 0.25
    /// Registered on the app element.
    static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    ]
    /// Registered on each window as a read first sees it.
    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute,
        kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen",
    ]
    private static let listedSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]

    private let lock = NSLock()
    private var runLoop: CFRunLoop?

    /// Started on first use, then kept for the life of the process.
    private func observerRunLoop() -> CFRunLoop {
        lock.lock()
        defer { lock.unlock() }
        if let runLoop { return runLoop }
        let ready = DispatchSemaphore(value: 0)
        var started: CFRunLoop?
        let thread = Thread {
            started = CFRunLoopGetCurrent()
            ready.signal()
            // Keeps the run loop alive with no sources attached yet.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "com.james.portside.windows.observers"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        runLoop = started
        return started!
    }

    func observe(_ pid: pid_t, changed: @escaping () -> Void) -> WindowObserveResult {
        var created: AXObserver?
        guard AXObserverCreate(pid, axWindowSourceCallback, &created) == .success, let observer = created else { return .failed }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        let runLoop = observerRunLoop()
        let observation = AXObservation(observer: observer, runLoop: runLoop, changed: changed)
        var added = 0
        for name in Self.appNotifications {
            switch AXObserverAddNotification(observer, app, name as CFString, observation.refcon) {
            case .success, .notificationAlreadyRegistered: added += 1
            case .cannotComplete: return .notReady
            default: break
            }
        }
        guard added > 0 else { return .failed }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        CFRunLoopWakeUp(runLoop)
        return .observing(observation)
    }

    func readWindows(of pid: pid_t, observation: WindowObservation?) -> WindowReadResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) {
        case .success: break
        case .noValue, .attributeUnsupported: return .windows([])
        default: return .failed
        }
        guard let elements = value as? [AXUIElement] else { return .windows([]) }
        let focused = Self.element(app, kAXFocusedWindowAttribute)
        let main = Self.element(app, kAXMainWindowAttribute)
        var readings: [WindowReading] = []
        var listed: [AXUIElement] = []
        for window in elements {
            AXUIElementSetMessagingTimeout(window, Self.axTimeout)
            var raw: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                window, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            if result == .cannotComplete { return .failed }
            guard result == .success, let values = raw as? [AnyObject], values.count == Self.attributes.count,
                  values[0] as? String == kAXWindowRole,
                  let subrole = values[1] as? String, Self.listedSubroles.contains(subrole)
            else { continue }
            readings.append(WindowReading(
                handle: AXElementKey(element: window),
                title: values[2] as? String,
                frame: Self.frame(position: values[4], size: values[5]),
                isMinimized: (values[3] as? NSNumber)?.boolValue ?? false,
                isFullScreen: (values[6] as? NSNumber)?.boolValue ?? false,
                isFocused: focused.map { CFEqual($0, window) } ?? false,
                isMain: main.map { CFEqual($0, window) } ?? false
            ))
            listed.append(window)
        }
        (observation as? AXObservation)?.watch(listed)
        return .windows(readings)
    }

    private static func element(_ app: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Displays in AX coordinates (origin at the primary display's top-left).
    @MainActor static func currentDisplays() -> [DisplayFrame] {
        let screens = NSScreen.screens
        guard let primaryTop = screens.first?.frame.maxY else { return [] }
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let f = screen.frame
            return DisplayFrame(id: number.uint32Value, frame: CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height))
        }
    }
}

/// One app's observer. Callbacks arrive on the observer thread; `cancel`
/// removes the run loop source on that same thread, so no callback can
/// outlive the object.
private final class AXObservation: WindowObservation, @unchecked Sendable {
    let observer: AXObserver
    let runLoop: CFRunLoop
    private let changed: () -> Void
    private let canceled = CancelFlag()
    /// Windows with notifications registered. Touched only from the app's
    /// registry lane (inside `readWindows`).
    private var watched: Set<AXElementKey> = []

    var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    init(observer: AXObserver, runLoop: CFRunLoop, changed: @escaping () -> Void) {
        self.observer = observer
        self.runLoop = runLoop
        self.changed = changed
    }

    func watch(_ windows: [AXUIElement]) {
        var next = Set<AXElementKey>()
        for window in windows {
            let key = AXElementKey(element: window)
            next.insert(key)
            guard !watched.contains(key) else { continue }
            for name in AXWindowSource.windowNotifications {
                AXObserverAddNotification(observer, window, name as CFString, refcon)
            }
        }
        watched = next
    }

    func notify() {
        if !canceled.isSet { changed() }
    }

    func cancel() {
        guard canceled.set() else { return }
        let source = AXObserverGetRunLoopSource(observer)
        let runLoop = runLoop
        // The block holds self until the source is gone.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            _ = self
        }
        CFRunLoopWakeUp(runLoop)
    }
}

/// Set-once flag readable from any thread.
private final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    /// True the first time only.
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// AXObserver callback (a C function pointer, so it cannot capture).
private func axWindowSourceCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AXObservation>.fromOpaque(refcon).takeUnretainedValue().notify()
}

extension RunningAppRecord {
    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "pid \(app.processIdentifier)",
            launchDate: app.launchDate,
            isHidden: app.isHidden
        )
    }
}

extension WindowRegistry {
    /// The production registry, fed by `RunningApps` workspace events (no
    /// observers of its own for app lifecycle), Accessibility trust changes
    /// (observed, never requested) and display changes.
    static func live(runningApps: RunningApps) -> WindowRegistry {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let registry = WindowRegistry(
            source: AXWindowSource(),
            isAccessGranted: { AccessibilityPermissionAdapter().currentState() == .granted },
            currentApps: { [weak runningApps] in
                let apps = runningApps?.apps.map(RunningAppRecord.init) ?? []
                return (apps, NSWorkspace.shared.frontmostApplication?.processIdentifier)
            },
            currentDisplays: AXWindowSource.currentDisplays
        )
        runningApps.onEvent = { [weak registry] name, app in
            guard app.processIdentifier != selfPID else { return }
            MainActor.assumeIsolated {
                guard let registry else { return }
                let record = RunningAppRecord(app)
                switch name {
                case NSWorkspace.didTerminateApplicationNotification:
                    registry.appTerminated(record)
                case _ where app.activationPolicy != .regular:
                    return
                case NSWorkspace.didLaunchApplicationNotification:
                    registry.appLaunched(record)
                case NSWorkspace.didActivateApplicationNotification:
                    registry.appActivated(record)
                case NSWorkspace.didHideApplicationNotification:
                    registry.appHiddenChanged(record, hidden: true)
                case NSWorkspace.didUnhideApplicationNotification:
                    registry.appHiddenChanged(record, hidden: false)
                default:
                    return
                }
            }
        }
        registry.feeds = [
            AccessibilityTrust.shared.$isTrusted.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
                .sink { [weak registry] _ in MainActor.assumeIsolated { registry?.accessibilityChanged() } },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak registry] _ in MainActor.assumeIsolated { registry?.displaysChanged() } },
        ]
        return registry
    }
}
