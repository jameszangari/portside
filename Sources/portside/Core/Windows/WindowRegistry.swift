import CoreGraphics
import Foundation

/// A running app as the registry sees it, read from `NSRunningApplication`
/// on the main thread (see `AXWindowSource.swift`), or built by tests.
struct RunningAppRecord: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let launchDate: Date?
    var isHidden = false

    /// Same process, not a later one that reused the pid.
    func isSameLaunch(as other: RunningAppRecord) -> Bool {
        pid == other.pid && launchDate == other.launchDate && bundleIdentifier == other.bundleIdentifier
    }
}

/// One launch of one process. A pid seen again after a quit, or with a
/// different launch date, gets a new generation, so an old key never matches
/// the new process.
struct AppKey: Hashable {
    let pid: pid_t
    let generation: UInt64
}

/// Ephemeral window identity: valid only while this registry runs and the
/// window stays open. Never persist it. It is not a CG window number and
/// says nothing about a window after its app relaunches.
struct WindowID: Hashable {
    let app: AppKey
    let serial: UInt64
}

/// What the registry knows about one app's windows.
enum WindowAccess: Equatable {
    /// Accessibility is not granted: app-level state only.
    case appOnly
    /// The first read has not answered yet.
    case loading
    case ready
    /// The last read timed out or failed. Windows are as last read.
    case unresponsive
}

struct AppSnapshot: Equatable {
    let key: AppKey
    let bundleIdentifier: String?
    let name: String
    let isActive: Bool
    let isHidden: Bool
    let windowAccess: WindowAccess
}

struct WindowSnapshot: Equatable {
    let id: WindowID
    let title: String
    /// The app's focused window (whether or not the app is frontmost).
    let isFocused: Bool
    let isMain: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
    /// AX coordinates: origin at the top-left of the primary display, y down.
    let frame: CGRect?
    let displayID: CGDirectDisplayID?
}

struct WindowRegistrySnapshot: Equatable {
    var accessibilityGranted = false
    /// Most recently activated first.
    var apps: [AppSnapshot] = []
    /// Most recently focused first.
    var windows: [WindowSnapshot] = []

    static let empty = WindowRegistrySnapshot()
}

/// One window as a source read it. `handle` identifies the window between
/// reads of the same app (an AX element in production).
struct WindowReading {
    let handle: AnyHashable
    var title: String?
    var frame: CGRect?
    var isMinimized = false
    var isFullScreen = false
    var isFocused = false
    var isMain = false
}

enum WindowReadResult {
    case windows([WindowReading])
    /// Timed out, not answering yet, or refused.
    case failed
}

/// A live change subscription for one app. `cancel` may be called from any
/// thread and must not block.
protocol WindowObservation: AnyObject, Sendable {
    func cancel()
}

enum WindowObserveResult {
    case observing(WindowObservation)
    /// The app has not finished launching. The registry retries a few times.
    case notReady
    /// No notifications. Windows refresh only when the app activates.
    case failed
}

/// Where window state comes from. Every call runs off the main thread, at most
/// one at a time per app, and must return within its own deadline. Sendable
/// because calls for different apps run on different threads.
protocol WindowSource: AnyObject, Sendable {
    /// `changed` may run on any thread whenever the app's windows change.
    func observe(_ pid: pid_t, changed: @escaping () -> Void) -> WindowObserveResult
    func readWindows(of pid: pid_t, observation: WindowObservation?) -> WindowReadResult
}

/// A display's frame in AX coordinates.
struct DisplayFrame: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
}

/// Shared app and window snapshots for 2.0 features (switcher, window
/// commands). Apps come from `RunningApps` events; windows from a
/// `WindowSource` (Accessibility in production) that runs off the main
/// thread on one serial lane per app, so a slow app delays only itself.
///
/// Idle until a feature calls `addClient`; it observes nothing while idle and
/// releases every observer when the last client goes. Without Accessibility
/// it keeps app-only state and never asks for the permission. It does not
/// move, resize or fit windows; `WindowFitter` owns that and its own
/// observers. Main actor only.
@MainActor
final class WindowRegistry: ObservableObject {
    @Published private(set) var snapshot = WindowRegistrySnapshot.empty

    private final class AppEntry {
        let key: AppKey
        var record: RunningAppRecord
        let lane: DispatchQueue
        var access: WindowAccess
        var ids: [AnyHashable: WindowID] = [:]
        var windows: [WindowID: WindowReading] = [:]
        /// Front-to-back order of the last read.
        var order: [WindowID] = []
        var hasRead = false
        var observation: WindowObservation?
        var attaching = false
        var attachAttempts = 0
        var reading = false
        var readAgain = false
        /// Bumped when Accessibility is revoked, so late answers are dropped.
        var epoch = 0

        init(key: AppKey, record: RunningAppRecord, access: WindowAccess) {
            self.key = key
            self.record = record
            self.access = access
            lane = DispatchQueue(label: "com.james.portside.windows.\(record.pid)", qos: .userInitiated)
        }
    }

    private let source: WindowSource
    private let isAccessGranted: @MainActor () -> Bool
    private let currentApps: @MainActor () -> (apps: [RunningAppRecord], frontmost: pid_t?)
    private let currentDisplays: @MainActor () -> [DisplayFrame]
    private let retryDelay: DispatchTimeInterval
    private static let maxAttachAttempts = 10

    private var clients = 0
    private var entries: [pid_t: AppEntry] = [:]
    private var appOrder: [AppKey] = []
    private var windowOrder: [WindowID] = []
    private var activePID: pid_t?
    private var accessGranted = false
    private var displays: [DisplayFrame] = []
    private var nextGeneration: UInt64 = 0
    private var nextSerial: UInt64 = 0
    /// Live event subscriptions (see `WindowRegistry.live`), kept for the
    /// registry's lifetime. Their handlers do nothing while idle.
    var feeds: [Any] = []

    var isRunning: Bool { clients > 0 }

    /// `retryDelay` is the wait between observer attempts on a launching app.
    init(
        source: WindowSource,
        isAccessGranted: @escaping @MainActor () -> Bool,
        currentApps: @escaping @MainActor () -> (apps: [RunningAppRecord], frontmost: pid_t?),
        currentDisplays: @escaping @MainActor () -> [DisplayFrame] = { [] },
        retryDelay: DispatchTimeInterval = .milliseconds(300)
    ) {
        self.source = source
        self.isAccessGranted = isAccessGranted
        self.currentApps = currentApps
        self.currentDisplays = currentDisplays
        self.retryDelay = retryDelay
    }

    // MARK: Clients

    /// Starts tracking for one feature. Call the returned closure (once is
    /// enough; more calls do nothing) to release it, for example from
    /// `ModuleContext.onStop`. The last release stops everything.
    func addClient() -> () -> Void {
        clients += 1
        if clients == 1 { begin() }
        var released = false
        return { [weak self] in
            MainActor.assumeIsolated {
                guard !released else { return }
                released = true
                self?.removeClient()
            }
        }
    }

    private func removeClient() {
        clients -= 1
        if clients == 0 { end() }
    }

    private func begin() {
        accessGranted = isAccessGranted()
        displays = currentDisplays()
        let seed = currentApps()
        activePID = seed.frontmost
        for record in seed.apps { _ = upsert(record) }
        if let front = seed.frontmost, let entry = entries[front] { bumpApp(entry.key) }
        publish()
    }

    private func end() {
        for entry in entries.values { entry.observation?.cancel() }
        entries = [:]
        appOrder = []
        windowOrder = []
        activePID = nil
        snapshot = .empty
    }

    // MARK: Lookups

    /// Current state of a window, or nil when it closed, its app quit, or the
    /// id belongs to an earlier launch. Check right before acting on it.
    func window(_ id: WindowID) -> WindowSnapshot? {
        guard current(id.app)?.windows[id] != nil else { return nil }
        return snapshot.windows.first { $0.id == id }
    }

    func app(_ key: AppKey) -> AppSnapshot? {
        guard current(key) != nil else { return nil }
        return snapshot.apps.first { $0.key == key }
    }

    // MARK: App events (from RunningApps)

    func appLaunched(_ record: RunningAppRecord) {
        guard isRunning else { return }
        _ = upsert(record)
        publish()
    }

    /// Also adds an app that switched to the regular policy after launch.
    func appActivated(_ record: RunningAppRecord) {
        guard isRunning else { return }
        let entry = upsert(record)
        activePID = record.pid
        bumpApp(entry.key)
        if let focused = entry.order.first(where: { entry.windows[$0]?.isFocused == true }) { bumpWindow(focused) }
        requestRead(entry)
        publish()
    }

    func appTerminated(_ record: RunningAppRecord) {
        guard isRunning, let entry = entries[record.pid], entry.record.isSameLaunch(as: record) else { return }
        remove(entry)
        if activePID == record.pid { activePID = nil }
        publish()
    }

    func appHiddenChanged(_ record: RunningAppRecord, hidden: Bool) {
        guard isRunning, let entry = entries[record.pid], entry.record.isSameLaunch(as: record) else { return }
        entry.record.isHidden = hidden
        publish()
    }

    /// Accessibility was granted or revoked. Granted: attach and read every
    /// app. Revoked: release observers, drop windows, keep apps.
    func accessibilityChanged() {
        guard isRunning else { return }
        let granted = isAccessGranted()
        guard granted != accessGranted else { return }
        accessGranted = granted
        for entry in entries.values {
            if granted {
                entry.access = .loading
                attach(entry)
            } else {
                entry.epoch += 1
                entry.observation?.cancel()
                entry.observation = nil
                entry.attaching = false
                entry.attachAttempts = 0
                entry.reading = false
                entry.readAgain = false
                entry.ids = [:]
                entry.windows = [:]
                entry.order = []
                entry.hasRead = false
                entry.access = .appOnly
            }
        }
        if !granted { windowOrder = [] }
        publish()
    }

    func displaysChanged() {
        guard isRunning else { return }
        displays = currentDisplays()
        publish()
    }

    // MARK: Entries

    private func current(_ key: AppKey) -> AppEntry? {
        guard let entry = entries[key.pid], entry.key == key else { return nil }
        return entry
    }

    /// The entry for this launch. A different launch on the same pid (a quit
    /// that never reported) replaces the old entry and its windows.
    private func upsert(_ record: RunningAppRecord) -> AppEntry {
        if let existing = entries[record.pid] {
            if existing.record.isSameLaunch(as: record) { return existing }
            remove(existing)
        }
        nextGeneration += 1
        let entry = AppEntry(
            key: AppKey(pid: record.pid, generation: nextGeneration),
            record: record,
            access: accessGranted ? .loading : .appOnly
        )
        entries[record.pid] = entry
        appOrder.append(entry.key)
        attach(entry)
        return entry
    }

    private func remove(_ entry: AppEntry) {
        entry.observation?.cancel()
        entry.observation = nil
        entries[entry.key.pid] = nil
        appOrder.removeAll { $0 == entry.key }
        windowOrder.removeAll { $0.app == entry.key }
    }

    // MARK: Observation and reads (answers come back on main)

    private func attach(_ entry: AppEntry) {
        guard accessGranted, entry.observation == nil, !entry.attaching else { return }
        entry.attaching = true
        let key = entry.key, epoch = entry.epoch, source = source
        entry.lane.async { [weak self] in
            let result = source.observe(key.pid) { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.windowsChanged(key) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishAttach(key, epoch: epoch, result) } }
        }
    }

    private func finishAttach(_ key: AppKey, epoch: Int, _ result: WindowObserveResult) {
        guard let entry = current(key), entry.epoch == epoch, accessGranted else {
            if case .observing(let observation) = result { observation.cancel() }
            return
        }
        entry.attaching = false
        switch result {
        case .observing(let observation):
            entry.observation = observation
            requestRead(entry)
        case .notReady:
            // A just-launched app answers AX only once it finishes launching.
            entry.attachAttempts += 1
            if entry.attachAttempts < Self.maxAttachAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let entry = self.current(key), entry.epoch == epoch else { return }
                        self.attach(entry)
                    }
                }
            } else {
                entry.access = .unresponsive
                publish()
            }
        case .failed:
            requestRead(entry)
        }
    }

    private func windowsChanged(_ key: AppKey) {
        guard let entry = current(key) else { return }
        requestRead(entry)
    }

    /// Coalesced: while a read is in flight, any number of changes queue one
    /// more read, so a burst of title changes costs at most two reads.
    private func requestRead(_ entry: AppEntry) {
        guard accessGranted, !entry.attaching else { return }
        if entry.reading {
            entry.readAgain = true
            return
        }
        entry.reading = true
        let key = entry.key, epoch = entry.epoch, observation = entry.observation, source = source
        entry.lane.async { [weak self] in
            let result = source.readWindows(of: key.pid, observation: observation)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishRead(key, epoch: epoch, result) } }
        }
    }

    private func finishRead(_ key: AppKey, epoch: Int, _ result: WindowReadResult) {
        // An earlier launch on this pid, or a read from before a revoke.
        guard let entry = current(key), entry.epoch == epoch else { return }
        entry.reading = false
        guard accessGranted else { return }
        switch result {
        case .windows(let readings):
            apply(readings, to: entry)
            entry.access = .ready
        case .failed:
            entry.access = .unresponsive
        }
        if entry.readAgain {
            entry.readAgain = false
            requestRead(entry)
        }
        publish()
    }

    private func apply(_ readings: [WindowReading], to entry: AppEntry) {
        var order: [WindowID] = []
        var ids: [AnyHashable: WindowID] = [:]
        var windows: [WindowID: WindowReading] = [:]
        var added: [WindowID] = []
        for reading in readings where ids[reading.handle] == nil {
            let id: WindowID
            if let known = entry.ids[reading.handle] {
                id = known
            } else {
                nextSerial += 1
                id = WindowID(app: entry.key, serial: nextSerial)
                added.append(id)
            }
            ids[reading.handle] = id
            windows[id] = reading
            order.append(id)
        }
        let open = Set(order)
        windowOrder.removeAll { $0.app == entry.key && !open.contains($0) }
        if !added.isEmpty {
            // A known app's new window goes after that app's latest window;
            // a first read goes after the windows of more recent apps.
            let index = windowOrder.firstIndex { $0.app == entry.key }.map { $0 + 1 }
                ?? insertionIndex(for: entry.key)
            windowOrder.insert(contentsOf: added, at: index)
        }
        entry.ids = ids
        entry.windows = windows
        entry.order = order
        entry.hasRead = true
        if activePID == entry.key.pid, let focused = order.first(where: { windows[$0]?.isFocused == true }) {
            bumpWindow(focused)
        }
    }

    /// After the last window of any app that is more recent than `key`.
    private func insertionIndex(for key: AppKey) -> Int {
        guard let rank = appOrder.firstIndex(of: key) else { return windowOrder.count }
        let newer = Set(appOrder[..<rank])
        return (windowOrder.lastIndex { newer.contains($0.app) }).map { $0 + 1 } ?? 0
    }

    private func bumpApp(_ key: AppKey) {
        appOrder.removeAll { $0 == key }
        appOrder.insert(key, at: 0)
    }

    private func bumpWindow(_ id: WindowID) {
        windowOrder.removeAll { $0 == id }
        windowOrder.insert(id, at: 0)
    }

    // MARK: Snapshot

    private func publish() {
        var next = WindowRegistrySnapshot(accessibilityGranted: accessGranted)
        next.apps = appOrder.compactMap { key in
            guard let entry = current(key) else { return nil }
            return AppSnapshot(
                key: key,
                bundleIdentifier: entry.record.bundleIdentifier,
                name: entry.record.name,
                isActive: activePID == key.pid,
                isHidden: entry.record.isHidden,
                windowAccess: entry.access
            )
        }
        next.windows = windowOrder.compactMap { id in
            guard let reading = current(id.app)?.windows[id] else { return nil }
            return WindowSnapshot(
                id: id,
                title: reading.title ?? "",
                isFocused: reading.isFocused,
                isMain: reading.isMain,
                isMinimized: reading.isMinimized,
                isFullScreen: reading.isFullScreen,
                frame: reading.frame,
                displayID: reading.frame.flatMap { Self.display(for: $0, in: displays) }
            )
        }
        if next != snapshot { snapshot = next }
    }

    /// The display holding the frame's center, else the one it overlaps most.
    static func display(for frame: CGRect, in displays: [DisplayFrame]) -> CGDirectDisplayID? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = displays.first(where: { $0.frame.contains(center) }) { return hit.id }
        let overlaps = displays.map { display -> (CGDirectDisplayID, CGFloat) in
            let area = display.frame.intersection(frame)
            return (display.id, area.isNull ? 0 : area.width * area.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}
