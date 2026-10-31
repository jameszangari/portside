import AppKit
import os

/// What the user picked when asked to remove a group tile.
enum GroupRemovalChoice {
    case ungroup, remove, cancel
}

/// What the user picked when dragging a member out of an open group grid.
enum GroupMemberRemovalChoice {
    case removeFromGroup, removeFromDock, cancel
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

        let choice: GroupRemovalChoice
        switch present(alert) {
        case .alertFirstButtonReturn: choice = .ungroup
        case .alertSecondButtonReturn: choice = .remove
        default: choice = .cancel
        }
        logger.info("group \(group.id, privacy: .public) (\(count) apps): \(String(describing: choice), privacy: .public)")
        return choice
    }

    /// Alert after dragging a member out of an open group grid.
    static func confirmMember(_ app: PinnedApp) -> GroupMemberRemovalChoice {
        let alert = NSAlert()
        alert.messageText = "Remove \(app.displayName)?"
        alert.informativeText = "Take it out of the group (it stays on the dock), or remove it from the dock entirely."
        alert.icon = AppIcon.image(points: 64)
        alert.addButton(withTitle: "Remove from Group")
        let dock = alert.addButton(withTitle: "Remove from Dock")
        dock.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let choice: GroupMemberRemovalChoice
        switch present(alert) {
        case .alertFirstButtonReturn: choice = .removeFromGroup
        case .alertSecondButtonReturn: choice = .removeFromDock
        default: choice = .cancel
        }
        logger.info("member \(app.displayName, privacy: .public): \(String(describing: choice), privacy: .public)")
        return choice
    }

    /// Runs `alert` modally and restores focus to the previous app.
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSApp.activate()
        let response = alert.runModal()
        if let previous, !previous.isTerminated {
            previous.activate(from: .current)
        } else if previous == nil, NSApp.activationPolicy() == .accessory {
            NSApp.deactivate()
        }
        return response
    }
}
