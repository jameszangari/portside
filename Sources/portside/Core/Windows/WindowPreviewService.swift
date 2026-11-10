import AppKit
import CoreGraphics
import Foundation
import os.log

/// One window a surface wants a picture of, as the window registry knows it.
/// `frame` is in AX coordinates (top-left origin, y down), which are the
/// coordinates ScreenCaptureKit reports window frames in.
struct PreviewTarget: Equatable {
    let window: WindowID
    let title: String
    let frame: CGRect?
    let isMinimized: Bool

    var pid: pid_t { window.app.pid }
}

/// One on-screen window ScreenCaptureKit can capture.
struct CapturableWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
}

/// Where pictures come from. The live one is `ScreenCaptureKitCapturer`;
/// tests use a fake, so nothing here needs the permission.
protocol WindowImageCapturer: AnyObject, Sendable {
    /// The windows on screen right now. Reads no pixels.
    func windows() async throws -> [CapturableWindow]
    /// One still picture of one window, at most `maxPixels` on its longest
    /// side. Never a stream.
    func image(of window: CGWindowID, maxPixels: Int) async throws -> CGImage
}

/// Finds the capturable window that is a registry window. Accessibility has
/// no public window number, so identity is the pid plus an equal frame, and
/// the title only when frames tie. Two candidates it cannot tell apart give
/// nil: an icon is better than another window's picture.
enum PreviewMatcher {
    static let frameTolerance: CGFloat = 2

    static func match(_ target: PreviewTarget, in candidates: [CapturableWindow]) -> CGWindowID? {
        guard let frame = target.frame else { return nil }
        let framed = candidates.filter {
            $0.pid == target.pid && $0.layer == 0 && $0.isOnScreen && close($0.frame, frame)
        }
        if framed.count == 1 { return framed[0].id }
        guard framed.count > 1, !target.title.isEmpty else { return nil }
        let titled = framed.filter { $0.title == target.title }
        return titled.count == 1 ? titled[0].id : nil
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }
}

/// Why a window shows its icon instead of a picture.
enum PreviewFallback: Error, Equatable {
    case notEnabled
    case noPermission
    case locked
    case noSurface
    case minimized
    /// Not on screen now (another Space, a full screen window, hidden app) or
    /// not told apart from another window.
    case notFound
    case failed
}

enum PreviewState {
    /// Nothing started or answered yet; show the icon.
    case loading
    case ready(CGImage)
    case fallback(PreviewFallback)
}

/// The shared window picture service (P2-SW-03): the App Switcher is its
/// first surface and Dock hover can attach to it as another.
///
/// - Capture is an explicit opt-in (`setOptedIn`) and needs Screen Recording,
///   read with a call that never prompts. ScreenCaptureKit is not touched
///   unless both hold, so this never raises the system prompt.
/// - One still picture of one window per request. No stream, no full-screen
///   capture, nothing written to disk.
/// - Only while a surface is attached (the switcher is showing), and only for
///   rows the surface asks about, which are the visible ones.
/// - A bounded memory cache and a small concurrency limit. A window asked for
///   by two surfaces is captured once.
/// - Turning it off, losing the permission, locking the screen, sleeping the
///   display or the last surface leaving cancels work and drops every picture.
@MainActor
final class WindowPreviewService: ObservableObject {
    /// Pictures kept at once, oldest dropped first. A full switcher shows nine
    /// rows; this leaves room for a couple while scrolling.
    static let maxImages = 12
    /// Longest side of a stored picture, in pixels (a row shows it at 64 pt).
    static let maxPixels = 256
    static let maxConcurrent = 3
    /// The on-screen window list is reused for this long, so a burst of rows
    /// asks ScreenCaptureKit once.
    static let windowListLifetime: TimeInterval = 1

    /// Bumped on every change; views observe it.
    @Published private(set) var revision = 0

    private let capturer: WindowImageCapturer
    private let permission: () -> PermissionState
    private let isLocked: () -> Bool
    private let now: () -> TimeInterval
    private let watchesSystem: Bool
    private let logger = Logger(subsystem: "com.james.portside", category: "WindowPreviews")

    private(set) var isOptedIn = false
    private var surfaces = Set<String>()
    private var entries: [WindowID: PreviewState] = [:]
    /// Ready pictures, oldest first.
    private var order: [WindowID] = []
    private var running: [WindowID: Task<Void, Never>] = [:]
    private var queue: [PreviewTarget] = []
    private var generation = 0
    private var listTask: Task<[CapturableWindow], Error>?
    private var listTime: TimeInterval = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var captureCount = 0
    private(set) var listCount = 0

    init(
        capturer: WindowImageCapturer,
        permission: @escaping () -> PermissionState = { CGPreflightScreenCaptureAccess() ? .granted : .denied },
        isLocked: @escaping () -> Bool = WindowPreviewService.screenIsLocked,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        watchesSystem: Bool = true
    ) {
        self.capturer = capturer
        self.permission = permission
        self.isLocked = isLocked
        self.now = now
        self.watchesSystem = watchesSystem
    }

    /// The session lock flag from `CGSessionCopyCurrentDictionary` (public).
    nonisolated static func screenIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    var permissionState: PermissionState { permission() }
    var attachedSurfaces: Set<String> { surfaces }
    var inFlightCount: Int { running.count }
    var storedImageCount: Int { order.count }

    // MARK: Switches

    /// The person's choice (and the module running). Off cancels everything
    /// and forgets every picture.
    func setOptedIn(_ on: Bool) {
        guard on != isOptedIn else { return }
        isOptedIn = on
        if !on { stop() }
    }

    /// A surface that shows pictures is on screen. Nothing is captured for a
    /// surface that has not attached.
    func attach(surface: String) {
        guard surfaces.insert(surface).inserted else { return }
        if surfaces.count == 1, watchesSystem { observeSystem() }
    }

    /// The last surface leaving cancels work and drops every picture, so no
    /// picture outlives the panel that showed it.
    func detach(surface: String) {
        guard surfaces.remove(surface) != nil else { return }
        if surfaces.isEmpty {
            removeObservers()
            stop()
        }
    }

    /// Drops everything in flight and stored. Also what a lock, a display
    /// sleep, a session switch and a revoked permission do.
    func stop() {
        generation += 1
        for task in running.values { task.cancel() }
        running = [:]
        queue = []
        listTask?.cancel()
        listTask = nil
        let hadEntries = !entries.isEmpty
        entries = [:]
        order = []
        if hadEntries { revision += 1 }
    }

    // MARK: Asking

    /// Why nothing can be captured right now, or nil when it can.
    var blocker: PreviewFallback? {
        if !isOptedIn { return .notEnabled }
        if surfaces.isEmpty { return .noSurface }
        if permission() != .granted { return .noPermission }
        if isLocked() { return .locked }
        return nil
    }

    /// What to draw for a window now. Reads state only.
    func state(for target: PreviewTarget) -> PreviewState {
        if let blocker { return .fallback(blocker) }
        if target.isMinimized { return .fallback(.minimized) }
        return entries[target.window] ?? .loading
    }

    /// Starts a capture for a visible row unless one is stored or running,
    /// whichever surface asked first.
    func request(_ target: PreviewTarget) {
        if blocker != nil {
            // A revoked permission or a lock ends work already started.
            if blocker == .noPermission || blocker == .locked { stop() }
            return
        }
        guard !target.isMinimized, target.frame != nil else { return }
        guard entries[target.window] == nil else { return }
        entries[target.window] = .loading
        queue.append(target)
        pump()
    }

    // MARK: Work

    private func pump() {
        while running.count < Self.maxConcurrent, !queue.isEmpty {
            let target = queue.removeFirst()
            let mine = generation
            running[target.window] = Task { [weak self] in
                await self?.capture(target, generation: mine)
            }
        }
    }

    private func capture(_ target: PreviewTarget, generation mine: Int) async {
        let result = await picture(of: target)
        guard mine == generation else { return }
        running[target.window] = nil
        // Re-read the gates: they may have changed while the picture was taken.
        if blocker != nil {
            stop()
            return
        }
        switch result {
        case .success(let image):
            captureCount += 1
            entries[target.window] = .ready(image)
            order.append(target.window)
            while order.count > Self.maxImages {
                entries[order.removeFirst()] = nil
            }
        case .failure(let reason):
            entries[target.window] = .fallback(reason)
        }
        revision += 1
        pump()
    }

    private func picture(of target: PreviewTarget) async -> Result<CGImage, PreviewFallback> {
        do {
            let windows = try await windowList()
            guard !Task.isCancelled else { return .failure(.failed) }
            guard let id = PreviewMatcher.match(target, in: windows) else { return .failure(.notFound) }
            // Last look before pixels are read.
            if blocker != nil { return .failure(.failed) }
            let image = try await capturer.image(of: id, maxPixels: Self.maxPixels)
            return .success(image)
        } catch {
            if !Task.isCancelled { logger.info("window preview failed: \(String(describing: error), privacy: .public)") }
            return .failure(.failed)
        }
    }

    /// One shared list per burst of rows.
    private func windowList() async throws -> [CapturableWindow] {
        if let listTask, now() - listTime < Self.windowListLifetime { return try await listTask.value }
        let capturer = self.capturer
        let task = Task { try await capturer.windows() }
        listTask = task
        listTime = now()
        listCount += 1
        return try await task.value
    }

    // MARK: Interruptions

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: stop)))
        }
        // The screen lock's own notification, so a lock cancels at once
        // rather than at the next row.
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: stop)))
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }
}
