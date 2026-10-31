import AppKit
import os

/// What the user picked after dropping a dock tile on the Trash.
enum DockTrashDropChoice {
    case removeFromDock, moveToTrash, cancel
}

/// A dock tile that was released on the Trash.
enum DockTrashDropTarget {
    case app(PinnedApp)
    case group(FolderGroup)
    case stack(FolderStack)
    case widget(id: String, title: String)

    var displayName: String {
        switch self {
        case .app(let app): app.displayName
        case .group(let group): group.name
        case .stack(let stack): stack.displayName
        case .widget(_, let title): title
        }
    }

    /// Only filesystem items can go in the Trash. Groups and widgets only unpin.
    var canMoveToTrash: Bool {
        switch self {
        case .app, .stack: true
        case .group, .widget: false
        }
    }
}

/// Alert when a dock tile is dropped on the Trash tile. Nothing is removed
/// or trashed until the user picks. Focus returns to the previous app after,
/// like the group-removal alert.
enum DockTrashDrop {
    private static let logger = Logger(subsystem: "com.james.portside", category: "TrashDrop")

    static func confirm(_ target: DockTrashDropTarget) -> DockTrashDropChoice {
        let alert = NSAlert()
        alert.messageText = "Remove \(target.displayName)?"
        if target.canMoveToTrash {
            alert.informativeText = "Remove it from the dock, or move the item to the Trash."
        } else {
            alert.informativeText = "Remove it from the dock? This does not delete anything on disk."
        }
        alert.icon = AppIcon.image(points: 64)
        alert.addButton(withTitle: "Remove from Dock")
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        trash.isEnabled = target.canMoveToTrash
        alert.addButton(withTitle: "Cancel")

        let previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSApp.activate()
        let response = alert.runModal()
        if let previous, !previous.isTerminated {
            previous.activate(from: .current)
        } else if previous == nil, NSApp.activationPolicy() == .accessory {
            NSApp.deactivate()
        }

        let choice: DockTrashDropChoice
        switch response {
        case .alertFirstButtonReturn: choice = .removeFromDock
        case .alertSecondButtonReturn: choice = target.canMoveToTrash ? .moveToTrash : .cancel
        default: choice = .cancel
        }
        logger.info("trash drop \(target.displayName, privacy: .public): \(String(describing: choice), privacy: .public)")
        return choice
    }

    /// Moves `url` to the Trash. Returns nil on success, or an error message.
    static func moveToTrash(_ url: URL) -> String? {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            logger.error("move to Trash failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
