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
/// changes, and tile frame changes. No timers.
///
/// React analogy: a controlled popover. `expandedID` is the state; the strip
/// reads it to highlight the open tile.
final class GroupController: ObservableObject {
    @Published private(set) var expandedID: String?

    /// Cursor entered or left the open group's panel.
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    /// A group closed. The cursor may now be outside the dock with no exit
    /// event coming (the panel vanished under it), so the engine re-checks.
    var onCollapsed: (() -> Void)?

    private let overlay = OverlayPanel()
    private let dockModel: DockModel
    private let runningApps: RunningApps
    private let hover: DockHover
    private var outsideClickMonitor: Any?
    private var entriesSubscription: AnyCancellable?
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
        entriesSubscription = dockModel.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let id = self.expandedID else { return }
                if !self.dockModel.groups.contains(where: { $0.id == id }) {
                    self.collapse(reason: "group removed")
                }
            }
    }

    var isExpanded: Bool { expandedID != nil }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        overlay.containsScreenPoint(point)
    }

    func toggle(_ groupID: String) {
        if expandedID == groupID {
            collapse(reason: "tile clicked")
        } else {
            expand(groupID)
        }
    }

    func expand(_ groupID: String) {
        guard let group = dockModel.groups.first(where: { $0.id == groupID }),
              let anchor = hover.screenFrame(forTargetID: DockEntry.group(group).id) else { return }
        let started = CACurrentMediaTime()
        expandedID = groupID
        hover.isSuppressed = true
        let edge = hover.edge
        let content = GroupPopoverView(
            groupID: groupID,
            edge: edge,
            dockModel: dockModel,
            runningApps: runningApps,
            onLaunch: { [weak self] app in self?.launch(app) }
        )
        overlay.present(AnyView(content), anchor: anchor, edge: edge, gap: DockHover.labelGap)
        installOutsideClickMonitor()
        let ms = (CACurrentMediaTime() - started) * 1000
        logger.info("expanded \(group.name, privacy: .public) (\(group.apps.count) apps) on the \(edge.rawValue, privacy: .public) edge in \(ms, format: .fixed(precision: 2))ms")
    }

    func collapse(reason: String) {
        guard expandedID != nil else { return }
        expandedID = nil
        overlay.dismiss()
        removeOutsideClickMonitor()
        hover.isSuppressed = false
        logger.info("collapsed (\(reason, privacy: .public))")
        onCollapsed?()
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
    /// open group next to its tile.
    func targetsChanged() {
        guard let id = expandedID,
              let anchor = hover.screenFrame(forTargetID: "group:" + id) else { return }
        overlay.reanchor(anchor)
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
