import AppKit
import Combine
import SwiftUI
import os.log

/// Expands and collapses app groups. The expanded group is a grid in its own
/// interactive overlay panel, placed like a hover label: beside the group's
/// tile on the side facing away from the screen edge.
///
/// Event driven only: tile clicks, clicks elsewhere (strip mouse down, or a
/// global mouse-down monitor installed only while a group is open), model
/// changes, tile frame changes and hover changes. The only timer is the
/// optional hover-intent delay: one cancelable one-shot work item.
///
/// Inline rename: the grid's title becomes a text field and the overlay
/// panel takes key focus only while it is being edited.
///
/// React analogy: a controlled popover. `expandedID` and `editingID` are the
/// state; the strip and the grid read them.
final class GroupController: ObservableObject {
    @Published private(set) var expandedID: String?
    /// Group whose name is being edited in the open grid.
    @Published private(set) var editingID: String?
    /// The name field's text while editing.
    @Published var draftName = ""

    /// Cursor entered or left the open group's panel.
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    /// A group closed. The cursor may now be outside the dock with no exit
    /// event coming (the panel vanished under it), so the engine re-checks.
    var onCollapsed: (() -> Void)?
    /// Editing started or ended. The dock must not hide while editing.
    var onEditingChanged: ((Bool) -> Void)?

    private let overlay = OverlayPanel()
    private let dockModel: DockModel
    private let runningApps: RunningApps
    private let hover: DockHover
    private var outsideClickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    /// A rename asked for before the group's tile was laid out (a group that
    /// was just created). Picked up by `targetsChanged`.
    private var pendingRenameID: String?
    private var pendingHoverOpen: DispatchWorkItem?
    /// The open grid came from hovering, so the next click on its tile
    /// keeps it open instead of toggling it shut.
    private var openedByHover = false
    private let logger = Logger(subsystem: "com.james.portside", category: "Groups")

    init(dockModel: DockModel, runningApps: RunningApps, hover: DockHover) {
        self.dockModel = dockModel
        self.runningApps = runningApps
        self.hover = hover
        overlay.ignoresMouseEvents = false
        overlay.onMouseEntered = { [weak self] in self?.onMouseEntered?() }
        overlay.onMouseExited = { [weak self] in self?.onMouseExited?() }

        // Close if the open group is ungrouped or removed. Next main loop
        // turn: @Published emits before the new value is stored.
        dockModel.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let id = self.expandedID else { return }
                if !self.dockModel.groups.contains(where: { $0.id == id }) {
                    self.collapse(reason: "group removed")
                }
            }
            .store(in: &subscriptions)

        // Name prompt for a new group, once its tile exists.
        dockModel.groupCreated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.beginRename(id, reason: "group created") }
            .store(in: &subscriptions)
    }

    var isExpanded: Bool { expandedID != nil }
    var isEditing: Bool { editingID != nil }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        overlay.containsScreenPoint(point)
    }

    func toggle(_ groupID: String) {
        if expandedID == groupID {
            if openedByHover {
                openedByHover = false
                logger.info("tile clicked after hover opened it, staying open")
                return
            }
            collapse(reason: "tile clicked")
        } else {
            expand(groupID)
        }
    }

    func expand(_ groupID: String, byHover: Bool = false) {
        pendingHoverOpen?.cancel()
        pendingHoverOpen = nil
        guard let group = dockModel.groups.first(where: { $0.id == groupID }),
              let anchor = hover.screenFrame(forTargetID: DockEntry.group(group).id) else { return }
        if isEditing { endRename(commit: true) }
        let started = CACurrentMediaTime()
        expandedID = groupID
        openedByHover = byHover
        hover.isSuppressed = true
        let edge = hover.edge
        let content = GroupPopoverView(
            groupID: groupID,
            edge: edge,
            dockModel: dockModel,
            runningApps: runningApps,
            groups: self,
            onLaunch: { [weak self] app in self?.launch(app) }
        )
        overlay.present(AnyView(content), anchor: anchor, edge: edge, gap: DockHover.labelGap)
        installOutsideClickMonitor()
        let ms = (CACurrentMediaTime() - started) * 1000
        let how = byHover ? "hover" : "click"
        logger.info("expanded \(group.name, privacy: .public) (\(group.apps.count) apps) by \(how, privacy: .public) on the \(edge.rawValue, privacy: .public) edge in \(ms, format: .fixed(precision: 2))ms")
    }

    func collapse(reason: String) {
        pendingHoverOpen?.cancel()
        pendingHoverOpen = nil
        guard expandedID != nil else { return }
        // Clicking away from a field commits it, like Finder.
        if isEditing { endRename(commit: true) }
        expandedID = nil
        openedByHover = false
        overlay.dismiss()
        removeOutsideClickMonitor()
        hover.isSuppressed = false
        logger.info("collapsed (\(reason, privacy: .public))")
        onCollapsed?()
    }

    // MARK: - Inline rename

    /// Open the group's grid (if needed) with its title as an editable field.
    func beginRename(_ groupID: String, reason: String) {
        guard let group = dockModel.groups.first(where: { $0.id == groupID }) else { return }
        if expandedID != groupID {
            expand(groupID)
        }
        guard expandedID == groupID else {
            // The tile has no frame yet (just created). Wait for the strip.
            pendingRenameID = groupID
            return
        }
        pendingRenameID = nil
        openedByHover = false
        draftName = group.name
        editingID = groupID
        overlay.beginKeyFocus()
        logger.info("rename started (\(reason, privacy: .public)): \(group.name, privacy: .public), overlay key: \(self.overlay.isKey)")
        onEditingChanged?(true)
    }

    /// Return commits, Escape cancels. A blank name keeps the old one.
    func endRename(commit: Bool) {
        guard let id = editingID else { return }
        let old = dockModel.groups.first { $0.id == id }?.name ?? ""
        if commit {
            dockModel.renameGroup(groupID: id, to: draftName)
        }
        let now = dockModel.groups.first { $0.id == id }?.name ?? ""
        editingID = nil
        overlay.endKeyFocus()
        logger.info("rename \(commit ? "committed" : "canceled", privacy: .public): \(old, privacy: .public) -> \(now, privacy: .public), overlay key: \(self.overlay.isKey)")
        onEditingChanged?(false)
    }

    // MARK: - Strip events

    /// A mouse down landed on the dock strip. Anything but the open group's
    /// own tile closes it (the tile's click toggles it instead).
    func stripMouseDown(at screenPoint: NSPoint) {
        guard let id = expandedID else { return }
        let tile = hover.screenFrame(forTargetID: "group:" + id)
        if tile?.contains(screenPoint) != true {
            collapse(reason: "clicked elsewhere on the dock")
        }
    }

    /// Tile frames changed (strip resized, items added, reordered). Keep the
    /// open group next to its tile, and start a rename that was waiting for
    /// its tile.
    func targetsChanged() {
        if let pending = pendingRenameID {
            beginRename(pending, reason: "group created")
            return
        }
        guard let id = expandedID,
              let anchor = hover.screenFrame(forTargetID: "group:" + id) else { return }
        overlay.reanchor(anchor)
    }

    /// The hovered strip item changed (nil: nothing, or the cursor left the
    /// strip). With "Open groups on hover" on, resting on a group tile opens
    /// it after the hover-intent delay; if another group is already open it
    /// switches at once. Never closes anything: D's close rules do that.
    func hoveredTargetChanged(_ targetID: String?) {
        pendingHoverOpen?.cancel()
        pendingHoverOpen = nil
        guard dockModel.openGroupsOnHover, !isEditing,
              let targetID, targetID.hasPrefix("group:") else { return }
        let groupID = String(targetID.dropFirst("group:".count))
        if expandedID == groupID { return }
        if expandedID != nil {
            expand(groupID, byHover: true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingHoverOpen = nil
            self?.expand(groupID, byHover: true)
        }
        pendingHoverOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dockModel.groupHoverDelay, execute: work)
    }

    private func launch(_ app: PinnedApp) {
        AppLauncher.open(app, running: runningApps.runningInstance(of: app))
        collapse(reason: "opened \(app.displayName)")
    }

    /// Clicks in other apps never reach Portside's windows, so a global
    /// monitor (mouse events need no permission) closes the group, like
    /// clicking away from a native Dock stack. Only installed while open.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.collapse(reason: "clicked outside Portside")
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }
}
