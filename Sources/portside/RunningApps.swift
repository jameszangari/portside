import AppKit
import os.log

/// Tracks running regular (Dock-visible) apps, updated only by
/// NSWorkspace notifications. No timers.
///
/// React analogy: a store fed by an event subscription; the strip
/// re-renders when `apps` changes.
final class RunningApps: ObservableObject {
    @Published private(set) var apps: [NSRunningApplication] = []

    private var observers: [NSObjectProtocol] = []
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
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // runningApplications can still list an app when its terminate
                // notification arrives, so exclude it explicitly.
                let terminated = name == NSWorkspace.didTerminateApplicationNotification ? app?.processIdentifier : nil
                self?.refresh(reason: name.rawValue, app: app, excluding: terminated)
            })
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func refresh(reason: String, app: NSRunningApplication? = nil, excluding excludedPID: pid_t? = nil) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let next = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != selfPID && $0.processIdentifier != excludedPID
        }
        // Activation fires constantly; only publish when membership changes.
        if next.map(\.processIdentifier) != apps.map(\.processIdentifier) {
            apps = next
            let name = app?.localizedName ?? "-"
            logger.info("running apps: \(next.count) (\(reason, privacy: .public): \(name, privacy: .public))")
        }
    }

    /// Running instance matching a pinned app, by bundle id or bundle path.
    func runningInstance(of pinned: PinnedApp) -> NSRunningApplication? {
        apps.first { running in
            if let id = pinned.bundleIdentifier, running.bundleIdentifier == id { return true }
            return running.bundleURL?.path == pinned.path
        }
    }

    func isRunning(_ pinned: PinnedApp) -> Bool {
        runningInstance(of: pinned) != nil
    }
}
