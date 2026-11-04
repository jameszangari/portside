import AppKit
import os

/// UI side of "Hide the macOS Dock": the first-time explanation, error
/// alerts, and keeping `DockModel.hideNativeDock` in sync with what
/// `NativeDock` actually did. The setting only turns on after a verified
/// hide, and turns off on any failure.
final class NativeDockController {
    private let dockModel: DockModel
    private static let logger = Logger(subsystem: "com.james.portside", category: "NativeDock")

    init(dockModel: DockModel) {
        self.dockModel = dockModel
    }

    /// Launch: crash recovery already ran in `PortsideMain`, so any backup
    /// is gone (or restore failed and hide will refuse). Hide again if the
    /// setting is on.
    func applyAtLaunch() {
        guard dockModel.hideNativeDock else { return }
        // On by default, so a first launch still owes the explanation.
        if !dockModel.nativeDockExplained {
            guard confirmFirstTime() else {
                Self.logger.info("launch: canceled at the first-time explanation")
                dockModel.setHideNativeDock(false)
                return
            }
            dockModel.markNativeDockExplained()
        }
        Self.logger.info("launch: Hide the macOS Dock is on, hiding")
        do {
            try NativeDock.hide()
            NativeDock.startWatchdog()
        } catch {
            Self.logger.error("launch: hide failed, turning the setting off: \(error.localizedDescription, privacy: .public)")
            dockModel.setHideNativeDock(false)
        }
    }

    /// Settings toggle.
    func setHidden(_ hidden: Bool) {
        if hidden {
            guard !dockModel.hideNativeDock else { return }
            if !dockModel.nativeDockExplained {
                guard confirmFirstTime() else {
                    Self.logger.info("hide: canceled at the first-time explanation")
                    return
                }
                dockModel.markNativeDockExplained()
            }
            do {
                try NativeDock.hide()
                NativeDock.startWatchdog()
                dockModel.setHideNativeDock(true)
            } catch {
                dockModel.setHideNativeDock(false)
                showError("Could not hide the macOS Dock", error)
            }
        } else {
            // Off even if restore fails: the backup stays on disk and is
            // retried at the next launch, or from the menu bar item.
            dockModel.setHideNativeDock(false)
            do {
                try NativeDock.restore()
            } catch {
                showError("Could not restore the macOS Dock", error)
            }
        }
    }

    /// Menu bar "Restore macOS Dock". Always available as an escape hatch.
    func restoreFromMenu() {
        dockModel.setHideNativeDock(false)
        do {
            if try NativeDock.restore() == .nothingToRestore {
                showInfo("Nothing to restore", "Portside has not changed the macOS Dock's settings, so there is no backup to restore.")
            }
        } catch {
            showError("Could not restore the macOS Dock", error)
        }
    }

    /// Quit, applicationWillTerminate, and signals. No UI: the app is going
    /// away.
    static func restoreForExit(reason: String) {
        guard NativeDock.backupExists else { return }
        logger.info("\(reason, privacy: .public): restoring the native Dock")
        do {
            try NativeDock.restore()
        } catch {
            logger.error("\(reason, privacy: .public): restore failed, backup kept for the next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Alerts

    private func confirmFirstTime() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hide the macOS Dock?"
        alert.informativeText = """
            Portside turns on the macOS Dock's auto-hide and sets its reveal delay so long that it never appears, then restarts the Dock. Its position and size are not changed.

            Your current Dock settings are saved first and put back exactly when you turn this off or quit Portside. If Portside crashes, they are put back right away.

            To undo it by hand, choose Restore macOS Dock from the Portside menu bar item, or run: portside --restore-dock
            """
        // Without a bundle the default icon is a generic alias-folder.
        alert.icon = AppIcon.image(points: 64)
        alert.addButton(withTitle: "Hide Dock")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ title: String, _ error: Error) {
        showInfo(title, error.localizedDescription)
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.icon = AppIcon.image(points: 64)
        NSApp.activate()
        alert.runModal()
    }
}
