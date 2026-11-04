import AppKit
import ApplicationServices
import Combine
import OSLog

/// Tracks Accessibility (TCC) trust for this process and helps the user grant it.
///
/// A common failure mode: Settings already shows Portside toggled on, but
/// `AXIsProcessTrusted()` is still false. That almost always means the entry
/// was granted to a different binary (another path, an old ad-hoc build, or a
/// re-signed `/Applications` install). Turning the toggle off and on, or
/// removing the stale entry and re-adding this copy, fixes it.
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

    /// Prompt for Accessibility so a named feature can work. Prefer this over
    /// the bare system sheet when the Settings toggle may already look granted.
    func requestAccess(forFeature feature: String) {
        refresh()
        if isTrusted { return }
        presentHelp(feature: feature)
    }

    /// Same as `requestAccess(forFeature:)` with a generic reason.
    func requestAccess() {
        requestAccess(forFeature: "this feature")
    }

    func openSettings() {
        // Pref pane deep link; falls back to Privacy & Security if the
        // Accessibility sub-pane id changes across macOS versions.
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
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility access needed"
        alert.informativeText = """
        Portside needs Accessibility access for \(feature).

        If Portside already appears enabled in Privacy & Security, this running copy is not the one that was granted access (a rebuild, a move between folders, or a re-signed install). Turn Portside off and on again there, or remove the stale entry and use “Add This Copy…” below.

        Running: \(path)
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Add This Copy…")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openSettings()
        case .alertSecondButtonReturn:
            registerThisCopy()
        default:
            break
        }
    }

    /// Asks TCC to register this process. Shows Apple's sheet and/or adds a
    /// second Portside row when the existing row points at another binary.
    private func registerThisCopy() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        if isTrusted {
            log.info("Accessibility granted after Add This Copy")
            return
        }
        // Sheet dismissed or already listed. Point them at Settings so they
        // can flip the toggle for the newly registered row.
        openSettings()
        let followUp = NSAlert()
        followUp.messageText = "Finish in System Settings"
        followUp.informativeText = """
        Look for Portside in Privacy & Security → Accessibility (or Device Control and Data Access). If more than one Portside is listed, enable the one for:

        \(Self.runningIdentity)

        Turn it off and on once if it already looks enabled.
        """
        followUp.addButton(withTitle: "OK")
        followUp.runModal()
    }

    private static var runningIdentity: String {
        let bundle = Bundle.main.bundleURL
        // Prefer the .app path when launched from a bundle; otherwise the exe.
        if bundle.pathExtension == "app" {
            return bundle.path
        }
        return Bundle.main.executableURL?.path ?? bundle.path
    }
}
