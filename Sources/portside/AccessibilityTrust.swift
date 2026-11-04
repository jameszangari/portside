import AppKit
import ApplicationServices
import Combine
import OSLog

/// Tracks Accessibility (TCC) trust for this process and helps the user grant it.
///
/// On recent macOS, System Settings can show Portside enabled while
/// `AXIsProcessTrusted()` stays false. That is a stale TCC row: the toggle was
/// written for an older code signature (typical after a Portside update).
/// Flipping the switch does not rewrite the row. Clearing it with
/// `tccutil reset Accessibility <bundle-id>`, quitting Portside, and granting
/// once on the next launch does.
final class AccessibilityTrust: ObservableObject {
    static let shared = AccessibilityTrust()

    @Published private(set) var isTrusted: Bool

    private let log = Logger(subsystem: "com.james.portside", category: "accessibility")
    private var observers: [NSObjectProtocol] = []

    private init() {
        isTrusted = AXIsProcessTrusted()
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // TCC can lag a beat after the toggle flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.refresh()
            }
        }
        observers.append(token)

        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        observers.append(active)
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for token in observers {
            center.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refresh() {
        let next = AXIsProcessTrusted()
        if next != isTrusted {
            log.info("Accessibility trust changed: \(next, privacy: .public)")
            isTrusted = next
        }
    }

    /// Prompt for Accessibility so a named feature can work.
    func requestAccess(forFeature feature: String) {
        refresh()
        if isTrusted { return }
        presentHelp(feature: feature)
    }

    func requestAccess() {
        requestAccess(forFeature: "this feature")
    }

    func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Private

    private func presentHelp(feature: String) {
        let path = Self.runningIdentity
        let bundleID = Bundle.main.bundleIdentifier ?? "com.james.portside"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility access needed"
        alert.informativeText = """
        Portside needs Accessibility access for \(feature).

        If Portside already looks enabled in Privacy & Security → Accessibility (or Device Control and Data Access), that row is stale after an update. Turning it off and on will not help. Reset the permission, quit Portside completely, open it again, then enable Portside when macOS asks.

        Running: \(path)
        """
        alert.addButton(withTitle: "Reset Permission…")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetAndRelaunch(bundleID: bundleID)
        case .alertSecondButtonReturn:
            openSettings()
        default:
            break
        }
    }

    /// Clears the stale Accessibility decision for this bundle, then asks the
    /// user to quit so the next launch can take a fresh grant.
    private func resetAndRelaunch(bundleID: String) {
        let status = Self.resetAccessibility(bundleID: bundleID)
        log.info("tccutil reset Accessibility \(bundleID, privacy: .public) exit \(status)")

        let followUp = NSAlert()
        followUp.alertStyle = .informational
        if status == 0 {
            followUp.messageText = "Permission cleared"
            followUp.informativeText = """
            Quit Portside completely (this clears the menu bar agent), open it again from Applications, use Show Windows and Recents once more, then turn Portside on when System Settings asks.

            Do not only toggle an existing Portside row: that leaves the stale grant in place.
            """
        } else {
            followUp.messageText = "Couldn’t reset automatically"
            followUp.informativeText = """
            Run this in Terminal, then quit and reopen Portside:

            tccutil reset Accessibility \(bundleID)

            After relaunch, use Show Windows and Recents and enable Portside when asked.
            """
        }
        followUp.addButton(withTitle: "Quit Portside")
        followUp.addButton(withTitle: "Open Settings")
        followUp.addButton(withTitle: "Cancel")

        switch followUp.runModal() {
        case .alertFirstButtonReturn:
            // Give the user a moment to read; terminate tears down the agent.
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            openSettings()
        default:
            break
        }
    }

    /// `tccutil reset Accessibility <bundle-id>`. Returns the process exit status,
    /// or -1 if the tool could not start.
    @discardableResult
    private static func resetAccessibility(bundleID: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }

    private static var runningIdentity: String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle.path
        }
        return Bundle.main.executableURL?.path ?? bundle.path
    }
}
