import AppKit
import os
import ServiceManagement

/// "Open Portside at login" through `SMAppService.mainApp`. The system is
/// the source of truth: nothing is stored in dock.json. Settings calls
/// `refresh()` when the window opens, and every toggle re-reads the status,
/// so the switch always shows what macOS actually has.
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// Short message from the last failed register or unregister.
    @Published private(set) var error: String?

    private static let logger = Logger(subsystem: "com.james.portside", category: "LaunchAtLogin")

    /// Login items need an .app bundle. `swift run` runs a bare executable
    /// from .build, which macOS cannot register.
    let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    /// On covers requiresApproval: the item is registered and waits for the
    /// user to allow it in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        guard isAvailable else { return }
        status = SMAppService.mainApp.status
        Self.logger.info("status: \(Self.describe(self.status), privacy: .public)")
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Self.logger.info("\(enabled ? "register" : "unregister", privacy: .public) succeeded")
        } catch {
            Self.logger.error("\(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Could not \(enabled ? "turn on" : "turn off") login launch: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
