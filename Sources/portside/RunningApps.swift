import AppKit
import os.log

/// Tracks running regular (Dock-visible) apps, updated only by
/// NSWorkspace notifications. No timers.
///
/// React analogy: a store fed by an event subscription; the strip
/// re-renders when `apps` changes.
final class RunningApps: ObservableObject {
    @Published private(set) var apps: [NSRunningApplication] = [] {
        didSet { reindex() }
    }
    /// Portside itself is a regular app right now (Settings is open), so its
    /// own dock shows it as running, like the native Dock does.
    @Published private(set) var includesSelf = false
    /// Running apps that are hidden (Cmd-H), for the translucent-icon option.
    @Published private(set) var hiddenPIDs: Set<pid_t> = []
    /// A regular app quit. The engine feeds this to the recents list.
    var onQuit: ((NSRunningApplication) -> Void)?
    /// Every workspace event this class observes, with its app, before the
    /// list refreshes. `WindowRegistry` uses it instead of its own observers.
    var onEvent: ((Notification.Name, NSRunningApplication) -> Void)?

    private var observers: [NSObjectProtocol] = []
    /// `apps` by bundle id and by bundle path. Every tile looks itself up on
    /// each render; a scan bridged two strings per running app each time.
    private var byBundleID: [String: NSRunningApplication] = [:]
    private var byPath: [String: NSRunningApplication] = [:]
    private let logger = Logger(subsystem: "com.james.portside", category: "RunningApps")

    init() {
        refresh(reason: "initial")
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            // Some apps switch to the regular activation policy after launch;
            // they activate when they do, so this catches them.
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // runningApplications can still list an app when its terminate
                // notification arrives, so exclude it explicitly.
                let terminated = name == NSWorkspace.didTerminateApplicationNotification ? app?.processIdentifier : nil
                if terminated != nil, let app, app.activationPolicy == .regular { self?.onQuit?(app) }
                if let app { self?.onEvent?(name, app) }
                self?.refresh(reason: name.rawValue, app: app, excluding: terminated)
            })
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Portside's own activation policy changed. There is no notification for
    /// that, so the owner calls this.
    func activationPolicyChanged() {
        refresh(reason: "portside activation policy")
    }

    private func refresh(reason: String, app: NSRunningApplication? = nil, excluding excludedPID: pid_t? = nil) {
        let regular = NSApp.activationPolicy() == .regular
        if regular != includesSelf {
            includesSelf = regular
            logger.info("portside \(regular ? "shown" : "hidden", privacy: .public) in its own dock")
        }
        // Portside is listed separately (see includesSelf): an unbundled
        // `swift run` build has no bundle URL, and clicking it must open
        // Settings rather than launch a second copy.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let next = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != selfPID && $0.processIdentifier != excludedPID
        }
        let hidden = Set(next.filter(\.isHidden).map(\.processIdentifier))
        if hidden != hiddenPIDs { hiddenPIDs = hidden }
        // Activation fires constantly; only publish when membership changes.
        if next.map(\.processIdentifier) != apps.map(\.processIdentifier) {
            // An app that launched or quit may have moved or been renamed.
            PinnedApp.clearLookups()
            apps = next
            let name = app?.localizedName ?? "-"
            logger.info("running apps: \(next.count) (\(reason, privacy: .public): \(name, privacy: .public))")
        }
    }

    /// Running instance matching a pinned app, by bundle id or bundle path.
    func runningInstance(of pinned: PinnedApp) -> NSRunningApplication? {
        if let id = pinned.bundleIdentifier, let running = byBundleID[id] { return running }
        return byPath[pinned.path]
    }

    private func reindex() {
        var ids: [String: NSRunningApplication] = [:]
        var paths: [String: NSRunningApplication] = [:]
        for app in apps {
            if let id = app.bundleIdentifier, ids[id] == nil { ids[id] = app }
            if let path = app.bundleURL?.path, paths[path] == nil { paths[path] = app }
        }
        byBundleID = ids
        byPath = paths
    }

    func isHidden(_ running: NSRunningApplication?) -> Bool {
        running.map { hiddenPIDs.contains($0.processIdentifier) } ?? false
    }

    func isRunning(_ pinned: PinnedApp) -> Bool {
        runningInstance(of: pinned) != nil
    }
}
