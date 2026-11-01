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
/// changes, tile frame changes and hover changes. Timers (all one-shot,
/// cancelable): the optional hover-intent delay to open, a short grace delay
/// when a hover-opened grid closes, and the close animation's length.
///
/// Launch bounce: clicking a not-running app in the grid keeps the grid open
/// and bounces that cell until the app finishes launching, then the grid
/// closes. Any close (or switching groups) stops the bounce first, so
/// nothing is left floating or hidden.
///
/// Drag-open: a Finder drag over a group tile opens its grid immediately
/// (apps and files). The grid opens as if hovered (transient), counts as
/// part of the drag region while the drag is over it, and closes after the
/// hover grace delay once the drag has left both the tile and the grid.
///
/// Inline rename: the grid's title becomes a text field and the overlay
/// panel takes key focus only while it is being edited.
///
/// React analogy: a controlled popover. `expandedID` and `editingID` are the
/// state; the strip and the grid read them.
final class GroupController: ObservableObject {
    @Published private(set) var expandedID: String?
    /// While true, the popover is animating out before `finishCollapse`.
    /// Hovering or clicking its tile (or re-entering a hover-opened grid)
    /// in that window reopens it.
    @Published private(set) var isClosing = false
    /// Group whose name is being edited in the open grid.
    @Published private(set) var editingID: String?
    /// The name field's text while editing.
    @Published var draftName = ""
    /// Slot where a strip-dragged app (or in-grid reorder) would land in the
    /// open group. The popover draws the same dashed gap as a Finder drop.
    @Published private(set) var memberInsertIndex: Int?
    /// App id being dragged into or within the open group (hides that cell).
    @Published private(set) var draggingMemberID: String?

    /// Cursor entered or left the open group's panel.
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    /// A group closed. The cursor may now be outside the dock with no exit
    /// event coming (the panel vanished under it), so the engine re-checks.
    var onCollapsed: (() -> Void)?
    /// Editing started or ended. The dock must not hide while editing.
    var onEditingChanged: ((Bool) -> Void)?
    /// A file drag entered the open grid (true) or left it, dropped or not
    /// (false, with a reason for the log). Feeds the engine's drag region.
    var onDragOverGrid: ((Bool, String) -> Void)?

    private let overlay = OverlayPanel()
    private let dockModel: DockModel
    private let runningApps: RunningApps
    private let hover: DockHover
    let bouncer: LaunchBouncer
    /// Notification badges for grid cells.
    let badges: DockBadges
    /// Grid cells report their drags here (drag an app out to remove it
    /// from the group).
    let dragOut: DragOutController
    /// An app is being dragged (from the grid or the strip). A
    /// hover-opened grid does not close mid-drag.
    private var isItemDragging = false
    /// Grid cell icon frames (overlay content coordinates), by bounce key.
    /// Kept across closes: reopening the same group reuses its SwiftUI
    /// views, which do not report an unchanged frame again.
    private var cellIconFrames: [String: CGRect] = [:]
    private var outsideClickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    /// A rename asked for before the group's tile was laid out (a group that
    /// was just created). Picked up by `targetsChanged`.
    private var pendingRenameID: String?
    private var pendingCollapseReason: String?
    private var pendingHoverOpen: DispatchWorkItem?
    private var pendingHoverClose: DispatchWorkItem?
    private var pendingDismiss: DispatchWorkItem?
    /// Group tile a file drag is over right now (nil: none, or no drag).
    private var dragTileGroupID: String?
    /// A file drag is over the open grid right now.
    private(set) var isDragOverGrid = false
    /// Member cell frames in overlay content (SwiftUI global) space.
    private var memberContentFrames: [String: CGRect] = [:]
    /// The open grid came from hovering, so the next click on its tile
    /// keeps it open instead of toggling it shut.
    private var openedByHover = false
    private let logger = Logger(subsystem: "com.james.portside", category: "Groups")

    init(dockModel: DockModel, runningApps: RunningApps, hover: DockHover, bouncer: LaunchBouncer, dragOut: DragOutController, badges: DockBadges) {
        self.dockModel = dockModel
        self.runningApps = runningApps
        self.hover = hover
        self.bouncer = bouncer
        self.dragOut = dragOut
        self.badges = badges
        overlay.ignoresMouseEvents = false
        overlay.onMouseEntered = { [weak self] in
            guard let self else { return }
            self.cancelHoverClose()
            if self.isClosing, self.openedByHover, let id = self.expandedID {
                self.expand(id, byHover: true)
            }
            self.onMouseEntered?()
        }
        overlay.onMouseExited = { [weak self] in
            self?.scheduleHoverCloseIfHoverOpened()
            self?.onMouseExited?()
        }

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

    /// The open grid's card (plus its bridge to the tile), nil when closed.
    var gridScreenFrame: NSRect? {
        expandedID == nil ? nil : overlay.hitFrame
    }

    /// An item drag started or ended. A drag that starts on the strip closes
    /// any open grid (a strip app drag reopens one via `dragOverGroupTileChanged`
    /// when the cursor rests on a group tile). A drag from inside the grid
    /// keeps it; when that ends, a hover-opened grid gets its normal grace
    /// close if the cursor left it.
    func itemDragChanged(_ dragging: Bool, fromStrip: Bool) {
        isItemDragging = dragging
        if dragging {
            pendingHoverOpen?.cancel()
            pendingHoverOpen = nil
            cancelHoverClose()
            if fromStrip, expandedID != nil {
                clearMemberInsert()
                collapse(reason: "item drag started on the strip")
            }
        } else {
            clearMemberInsert()
            scheduleHoverCloseIfHoverOpened()
        }
    }

    func toggle(_ groupID: String) {
        if expandedID == groupID, !isClosing {
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
        cancelHoverClose()
        pendingDismiss?.cancel()
        pendingDismiss = nil
        pendingCollapseReason = nil
        if expandedID == groupID, isClosing {
            // Caught mid-close: play the open again from where it is.
            isClosing = false
            openedByHover = byHover
            logger.info("reopened while closing by \(byHover ? "hover" : "click", privacy: .public)")
            return
        }
        isClosing = false
        guard let group = dockModel.groups.first(where: { $0.id == groupID }),
              let anchor = hover.screenFrame(forTargetID: DockEntry.group(group).id) else { return }
        if expandedID != groupID {
            bouncer.cancelGridBounce(reason: "switched group")
        }
        if isEditing { endRename(commit: true) }
        let started = CACurrentMediaTime()
        expandedID = groupID
        openedByHover = byHover
        hover.isSuppressed = true
        let edge = hover.edge
        // A new identity per group, so switching groups plays the open again.
        let content = GroupPopoverView(
            groupID: groupID,
            edge: edge,
            dockModel: dockModel,
            runningApps: runningApps,
            groups: self,
            badges: badges,
            onLaunch: { [weak self] app, afterOpen in self?.launch(app, afterOpen: afterOpen) },
            onOpenDocuments: { [weak self] urls, app in self?.launch(app, documents: urls) },
            onAddApps: { [weak self] apps, at in
                for (offset, app) in apps.enumerated() {
                    self?.dockModel.addToGroup(app, groupID: groupID, at: at + offset)
                }
            },
            onDragOverGrid: { [weak self] inside, reason in self?.dragOverGridChanged(inside, reason: reason) }
        )
        .id(groupID)
        // The popover draws its own bridge across the gap and its own shadow.
        overlay.present(AnyView(content), anchor: anchor, edge: edge, gap: 0, hitInsets: GroupPopoverView.hitInsets(for: edge))
        installOutsideClickMonitor()
        let ms = (CACurrentMediaTime() - started) * 1000
        let how = byHover ? "hover" : "click"
        logger.info("expanded \(group.name, privacy: .public) (\(group.apps.count) apps) by \(how, privacy: .public) on the \(edge.rawValue, privacy: .public) edge in \(ms, format: .fixed(precision: 2))ms")
    }

    func collapse(reason: String, animated: Bool = true) {
        pendingHoverOpen?.cancel()
        pendingHoverOpen = nil
        cancelHoverClose()
        guard expandedID != nil else { return }
        if isClosing {
            // Already animating out. An instant close (dock hiding) cuts it short.
            if !animated { finishCollapse(reason: reason) }
            return
        }
        if isEditing { endRename(commit: true) }
        // Before the close animation: the bounce window sits above the grid
        // and would otherwise float over it while it fades.
        bouncer.cancelGridBounce(reason: "group closed")
        if animated && GroupPopoverMotion.shouldAnimate {
            pendingCollapseReason = reason
            isClosing = true
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isClosing else { return }
                self.finishCollapse(reason: self.pendingCollapseReason ?? reason)
            }
            pendingDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + GroupPopoverMotion.dismissDuration, execute: work)
            return
        }
        finishCollapse(reason: reason)
    }

    private func finishCollapse(reason: String) {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        pendingCollapseReason = nil
        guard expandedID != nil else { return }
        isClosing = false
        expandedID = nil
        openedByHover = false
        if isDragOverGrid {
            // The grid vanished under the drag; no exit will come from it.
            isDragOverGrid = false
            onDragOverGrid?(false, "grid closed")
        }
        bouncer.cancelGridBounce(reason: "group closed")
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
        cancelHoverClose()
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

    /// A context menu opened over the strip (not over the grid): the menu
    /// replaces any open grid, including the group's own.
    func stripMenuOpened() {
        pendingHoverOpen?.cancel()
        pendingHoverOpen = nil
        guard expandedID != nil else { return }
        collapse(reason: "context menu opened on the strip")
    }

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
        // The engine calls the bouncer's tilesChanged right after this, so a
        // bouncing grid cell follows the grid.
    }

    /// The hovered strip item changed (nil: nothing, or the cursor left the
    /// strip). With "Open groups on hover" on, resting on a group tile opens
    /// it after the hover-intent delay; if another group is already open it
    /// switches at once. Hover-opened grids close when the cursor leaves the
    /// tile and grid (with a short grace delay), unless pinned by a click.
    func hoveredTargetChanged(_ targetID: String?) {
        pendingHoverOpen?.cancel()
        pendingHoverOpen = nil
        updateHoverOpenedClose(targetID: targetID)
        guard dockModel.openGroupsOnHover, !isEditing, !isItemDragging,
              let targetID, targetID.hasPrefix("group:") else { return }
        let groupID = String(targetID.dropFirst("group:".count))
        if expandedID == groupID {
            // Back on the tile while its hover-opened grid fades out.
            if isClosing, openedByHover { expand(groupID, byHover: true) }
            return
        }
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

    /// Hover-opened only: leaving the group's tile starts a grace close
    /// unless the cursor is entering the grid (or another group tile).
    private func updateHoverOpenedClose(targetID: String?) {
        guard openedByHover, let id = expandedID, !isEditing, !isClosing else { return }
        let tileID = "group:" + id
        if targetID == tileID {
            cancelHoverClose()
            return
        }
        if let targetID, targetID.hasPrefix("group:") {
            cancelHoverClose()
            return
        }
        scheduleHoverCloseIfHoverOpened()
    }

    private func scheduleHoverCloseIfHoverOpened() {
        guard openedByHover, expandedID != nil, !isEditing, !isClosing else { return }
        cancelHoverClose()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingHoverClose = nil
            self?.closeHoverOpenedIfCursorOutside()
        }
        pendingHoverClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dockModel.groupHoverCloseGrace, execute: work)
    }

    private func closeHoverOpenedIfCursorOutside() {
        guard openedByHover, let id = expandedID, !isEditing else { return }
        // A drag over the grid or the tile keeps it, wherever the cursor
        // reads (drag callbacks and the cursor can disagree at the edges).
        if isDragOverGrid || dragTileGroupID == id || isItemDragging { return }
        let location = NSEvent.mouseLocation
        if overlay.containsScreenPoint(location) { return }
        if let tile = hover.screenFrame(forTargetID: "group:" + id), tile.contains(location) { return }
        collapse(reason: "hover left tile and grid")
    }

    private func cancelHoverClose() {
        pendingHoverClose?.cancel()
        pendingHoverClose = nil
    }

    // MARK: - Member frames / insert slot (Finder, strip drag, reorder)

    /// The open grid reports each member cell's frame in overlay content space.
    func setMemberContentFrames(_ frames: [String: CGRect]) {
        memberContentFrames = frames.filter { !$0.key.hasPrefix("group-insert") }
    }

    /// Update the dashed insert gap from a screen point (strip app drag).
    func updateMemberInsert(atScreen point: NSPoint, hidingAppID: String?) {
        guard expandedID != nil,
              let content = overlay.contentPoint(fromScreen: point) else {
            clearMemberInsert()
            return
        }
        updateMemberInsert(atContent: content, hidingAppID: hidingAppID)
    }

    /// Update the dashed insert gap from overlay content coordinates (grid reorder).
    func updateMemberInsert(atContent point: CGPoint, hidingAppID: String?) {
        draggingMemberID = hidingAppID
        let frames = memberContentFrames.filter { $0.key != hidingAppID }.map(\.value)
        let index = Self.slotIndex(frames: frames, at: point)
        if memberInsertIndex != index {
            memberInsertIndex = index
        }
    }

    /// Where a grid member being dragged belongs among `ids` (group order):
    /// it steps past a neighbor only once the cursor crosses that
    /// neighbor's midpoint in reading order. Uses the cells' real frames, so
    /// a neighbor still sliding aside can never pull the member back.
    func reorderSlot(ids: [String], dragged: String, at point: CGPoint) -> Int {
        guard var slot = ids.firstIndex(of: dragged) else { return 0 }
        func precedes(_ id: String) -> Bool {
            guard let f = memberContentFrames[id] else { return false }
            return point.y < f.minY || (point.y <= f.maxY && point.x < f.midX)
        }
        func follows(_ id: String) -> Bool {
            guard let f = memberContentFrames[id] else { return false }
            return point.y > f.maxY || (point.y >= f.minY && point.x > f.midX)
        }
        while slot > 0, precedes(ids[slot - 1]) { slot -= 1 }
        while slot < ids.count - 1, follows(ids[slot + 1]) { slot += 1 }
        return slot
    }

    func clearMemberInsert() {
        if memberInsertIndex != nil { memberInsertIndex = nil }
        if draggingMemberID != nil { draggingMemberID = nil }
    }

    /// Reading-order index 0...count from cell midpoints (same rules as the
    /// Finder drop gap in the grid).
    static func slotIndex(frames: [CGRect], at point: CGPoint) -> Int {
        let ordered = frames.sorted { a, b in
            if abs(a.minY - b.minY) < 4 { return a.minX < b.minX }
            return a.minY < b.minY
        }
        if ordered.isEmpty { return 0 }
        for (i, frame) in ordered.enumerated() {
            if point.y < frame.midY - frame.height * 0.45 { return i }
            if abs(point.y - frame.midY) <= frame.height * 0.55, point.x < frame.midX {
                return i
            }
        }
        return ordered.count
    }

    /// Finish a strip app drag: add to the open group (or the group tile under
    /// the cursor) at the insert slot. Returns true if the drop was consumed.
    @discardableResult
    func finishStripAppDrop(_ app: PinnedApp) -> Bool {
        let point = NSEvent.mouseLocation
        let insert = memberInsertIndex
        let hiding = draggingMemberID
        defer { clearMemberInsert() }

        if let groupID = expandedID {
            let overGrid = containsScreenPoint(point)
            let overTile = hover.screenFrame(forTargetID: "group:" + groupID)?.contains(point) == true
            if overGrid || overTile {
                let at = insert ?? dockModel.groups.first(where: { $0.id == groupID })?.apps.count ?? 0
                dockModel.addToGroup(app, groupID: groupID, at: at)
                logger.info("strip drop: added \(app.displayName, privacy: .public) to group at \(at)")
                // Keep a drag-opened grid from closing the moment the drag ends.
                cancelHoverClose()
                openedByHover = false
                return true
            }
        }
        if let groupID = dragTileGroupID {
            dockModel.addToGroup(app, groupID: groupID)
            logger.info("strip drop: added \(app.displayName, privacy: .public) onto group tile")
            return true
        }
        _ = hiding
        return false
    }

    // MARK: - Drag open (file / app drags)

    /// The group tile under a Finder drag over the strip changed (nil: not
    /// on a group tile, or the drag left the strip or dropped). Opens the
    /// grid immediately, including for `.app` drags that can be dropped in.
    func dragOverGroupTileChanged(_ groupID: String?) {
        guard groupID != dragTileGroupID else { return }
        dragTileGroupID = groupID
        guard let groupID else {
            // Left the tile: a drag-opened grid stays only while the drag
            // goes on into it. The grid's own enter cancels this close.
            scheduleHoverCloseIfHoverOpened()
            return
        }
        guard !isEditing else { return }
        if expandedID == groupID {
            cancelHoverClose()
            if isClosing, openedByHover { expand(groupID, byHover: true) }
            return
        }
        logger.info("drag-open: expanding group \(groupID, privacy: .public)")
        expand(groupID, byHover: true)
    }

    /// A file drag entered or left the open grid (from the grid's drop
    /// delegate). Inside, the grid never closes on a grace timer; leaving
    /// starts the grace close unless the drag is back on the tile.
    private func dragOverGridChanged(_ inside: Bool, reason: String) {
        guard inside != isDragOverGrid else {
            // Dropped: the delegate reports exit again right after.
            return
        }
        isDragOverGrid = inside
        if inside {
            cancelHoverClose()
            if isClosing, openedByHover, let id = expandedID { expand(id, byHover: true) }
        } else {
            scheduleHoverCloseIfHoverOpened()
        }
        onDragOverGrid?(inside, reason)
    }

    private func launch(_ app: PinnedApp, documents: [URL] = [], afterOpen: ((NSRunningApplication?) -> Void)? = nil) {
        let running = runningApps.runningInstance(of: app)
        if running == nil, let groupID = expandedID, !isClosing, bouncer.isEnabled {
            let target = LaunchBouncer.BounceTarget(
                key: LaunchBouncer.gridKey(groupID: groupID, appID: app.id),
                // Above the grid overlay (and its labels' level).
                level: NSWindow.Level(rawValue: OverlayPanel.windowLevel.rawValue + 1)
            ) { [weak self] _ in self?.cellIconScreenFrame(appID: app.id, groupID: groupID) }
            let bouncing = bouncer.launch(app, size: GroupPopoverView.iconSize, target: target, documents: documents, afterOpen: afterOpen) { [weak self] landed in
                // Landed: the app is up, so close the grid like any launch.
                // Cut short: the grid closed, the dock hid or moved, or the
                // launch failed; leave the grid as it is.
                if landed { self?.collapse(reason: "opened \(app.displayName)") }
            }
            if bouncing { return }
            // Bounce did not start (cell not on screen); it was launched anyway.
            collapse(reason: "opened \(app.displayName)")
            return
        }
        AppLauncher.open(app, running: running, documents: documents) { result, error in
            if error == nil { afterOpen?(result) }
        }
        collapse(reason: "opened \(app.displayName)")
    }

    /// A grid cell's icon moved, appeared (frame) or went away (nil).
    func cellIconFrameChanged(groupID: String, appID: String, frame: CGRect?) {
        cellIconFrames[LaunchBouncer.gridKey(groupID: groupID, appID: appID)] = frame
        if groupID == expandedID { bouncer.tilesChanged() }
    }

    private func cellIconScreenFrame(appID: String, groupID: String) -> NSRect? {
        guard expandedID == groupID, !isClosing,
              let rect = cellIconFrames[LaunchBouncer.gridKey(groupID: groupID, appID: appID)] else { return nil }
        return overlay.screenRect(forContentRect: rect)
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
