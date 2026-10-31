import AppKit
import os

/// What the user picked when asked to remove a group tile.
enum GroupRemovalChoice {
    case ungroup, remove, cancel
}

/// The "Remove group?" alert for the two ways a group tile can be removed
/// (its menu and dragging it out). Portside is an accessory app, so the alert
/// takes focus only for as long as it is up: the app that was frontmost gets
/// it back afterward, like the Settings window does.
enum GroupRemoval {
    private static let logger = Logger(subsystem: "com.james.portside", category: "GroupRemoval")

    /// Groups with no apps have nothing to lose, so they are removed without asking.
    static func needsConfirmation(_ group: FolderGroup) -> Bool {
        !group.apps.isEmpty
    }

    /// Runs the alert modally and returns the choice.
    static func confirm(_ group: FolderGroup) -> GroupRemovalChoice {
        let count = group.apps.count
        let alert = NSAlert()
        alert.messageText = "Remove group \(group.name)?"
        alert.informativeText = "This removes the group and its \(count) app\(count == 1 ? "" : "s") from the dock."
        alert.icon = AppIcon.image(points: 64)
        alert.addButton(withTitle: "Ungroup Instead")
        let remove = alert.addButton(withTitle: "Remove Group")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        // Whoever was frontmost, unless that is Portside itself (Settings open).
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSApp.activate()
        let response = alert.runModal()
        if let previous, !previous.isTerminated {
            previous.activate(from: .current)
        } else if previous == nil, NSApp.activationPolicy() == .accessory {
            NSApp.deactivate()
        }

        let choice: GroupRemovalChoice
        switch response {
        case .alertFirstButtonReturn: choice = .ungroup
        case .alertSecondButtonReturn: choice = .remove
        default: choice = .cancel
        }
        logger.info("group \(group.id, privacy: .public) (\(count) apps): \(String(describing: choice), privacy: .public)")
        return choice
    }
}
