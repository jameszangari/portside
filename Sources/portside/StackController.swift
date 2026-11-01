import AppKit
import Combine
import SwiftUI
import os.log

/// Expands and collapses filesystem folder stacks. Same overlay placement as
/// app groups (beside the tile, away from the screen edge). Grid, fan, or list.
///
/// Event-driven: tile clicks, outside clicks, model changes. A file drag over
/// a stack tile opens the grid immediately (no spring-load delay). One-shot
/// cancelable timer for dismiss only.
final class StackController: ObservableObject {
    @Published private(set) var expandedID: String?
    @Published private(set) var isClosing = false

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onCollapsed: (() -> Void)?
    var onDragOverGrid: ((Bool, String) -> Void)?

    let contents = StackContents()
    private let overlay = OverlayPanel()
    private let dockModel: DockModel
    private let hover: DockHover
    private var outsideClickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingDismiss: DispatchWorkItem?
    private var pendingCollapseReason: String?
    private var dragTileStackID: String?
    private(set) var isDragOverGrid = false
    private var openedByHover = false
    private let logger = Logger(subsystem: "com.james.portside", category: "Stacks")

    init(dockModel: DockModel, hover: DockHover) {
        self.dockModel = dockModel
        self.hover = hover
        overlay.ignoresMouseEvents = false
        overlay.onMouseEntered = { [weak self] in
            guard let self else { return }
            if self.isClosing, self.openedByHover, let id = self.expandedID {
                self.expand(id, byHover: true)
            }
            self.onMouseEntered?()
        }
        overlay.onMouseExited = { [weak self] in self?.onMouseExited?() }

        dockModel.$stacks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stacks in
                guard let self else { return }
                self.contents.sync(stacks: stacks)
                if let id = self.expandedID, !stacks.contains(where: { $0.id == id }) {
                    self.collapse(reason: "stack removed")
                }
            }
            .store(in: &subscriptions)
        contents.sync(stacks: dockModel.stacks)
    }

    var isExpanded: Bool { expandedID != nil }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        overlay.containsScreenPoint(point)
    }

    var gridScreenFrame: NSRect? {
        expandedID == nil ? nil : overlay.hitFrame
    }

    func toggle(_ stackID: String) {
        if expandedID == stackID, !isClosing {
            if openedByHover {
                openedByHover = false
                return
            }
            collapse(reason: "tile clicked")
        } else {
            expand(stackID)
        }
    }

    func expand(_ stackID: String, byHover: Bool = false) {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        pendingCollapseReason = nil
        if expandedID == stackID, isClosing {
            isClosing = false
            openedByHover = byHover
            return
        }
        isClosing = false
        guard let stack = dockModel.stacks.first(where: { $0.id == stackID }),
              let anchor = hover.screenFrame(forTargetID: stack.hoverID) else { return }
        expandedID = stackID
        openedByHover = byHover
        hover.isSuppressed = true
        contents.refresh(stack, reason: "expand")
        let edge = hover.edge
        let content = StackPopoverView(
            stackID: stackID,
            edge: edge,
            dockModel: dockModel,
            stacks: self,
            onOpen: { [weak self] item in self?.open(item) },
            onDeposit: { [weak self] urls, at in self?.deposit(urls, into: stackID, at: at) },
            onDragOverGrid: { [weak self] inside, reason in self?.dragOverGridChanged(inside, reason: reason) }
        )
        .id(stackID)
        overlay.present(AnyView(content), anchor: anchor, edge: edge, gap: 0, hitInsets: StackPopoverView.hitInsets(for: edge))
        installOutsideClickMonitor()
        logger.info("expanded \(stack.displayName, privacy: .public) by \(byHover ? "hover" : "click", privacy: .public)")
    }

    func collapse(reason: String, animated: Bool = true) {
        guard expandedID != nil else { return }
        if isClosing {
            if !animated { finishCollapse(reason: reason) }
            return
        }
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
            isDragOverGrid = false
            onDragOverGrid?(false, "grid closed")
        }
        overlay.dismiss()
        removeOutsideClickMonitor()
        hover.isSuppressed = false
        logger.info("collapsed (\(reason, privacy: .public))")
        onCollapsed?()
    }

    func stripMenuOpened() {
        guard expandedID != nil else { return }
        collapse(reason: "context menu opened on the strip")
    }

    func stripMouseDown(at screenPoint: NSPoint) {
        guard let id = expandedID,
              let stack = dockModel.stacks.first(where: { $0.id == id }) else { return }
        if hover.screenFrame(forTargetID: stack.hoverID)?.contains(screenPoint) != true {
            collapse(reason: "clicked elsewhere on the dock")
        }
    }

    func targetsChanged() {
        guard let id = expandedID,
              let stack = dockModel.stacks.first(where: { $0.id == id }),
              let anchor = hover.screenFrame(forTargetID: stack.hoverID) else { return }
        overlay.reanchor(anchor)
    }

    func itemDragChanged(_ dragging: Bool, fromStrip: Bool) {
        if dragging, fromStrip, expandedID != nil {
            collapse(reason: "item drag started on the strip")
        }
    }

    // MARK: - Drag open

    /// Opens the folder grid as soon as a file drag enters the tile.
    func dragOverStackTileChanged(_ stackID: String?) {
        if stackID == dragTileStackID { return }
        dragTileStackID = stackID
        guard let stackID else { return }
        if expandedID == stackID {
            if isClosing { expand(stackID, byHover: true) }
            return
        }
        expand(stackID, byHover: true)
    }

    private func dragOverGridChanged(_ inside: Bool, reason: String) {
        guard inside != isDragOverGrid else { return }
        isDragOverGrid = inside
        onDragOverGrid?(inside, reason)
    }

    // MARK: - Actions

    func openFolder(_ stackID: String) {
        guard let stack = dockModel.stacks.first(where: { $0.id == stackID }) else { return }
        collapse(reason: "open in Finder", animated: false)
        NSWorkspace.shared.open(stack.url)
    }

    func open(_ item: StackItem) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(item.url, configuration: config) { _, error in
            if let error {
                stackLogger.error("open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Move (same volume) or copy dropped files into the folder.
    /// `at` is the display index in the open grid (nil appends).
    func deposit(_ urls: [URL], into stackID: String, at index: Int? = nil) {
        guard let stack = dockModel.stacks.first(where: { $0.id == stackID }) else { return }
        let destDir = stack.url
        let seed = contents.items(for: stack).map { $0.url.lastPathComponent }
        let insertAt = index ?? seed.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var landed: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                let dest = destDir.appendingPathComponent(name)
                do {
                    if fm.fileExists(atPath: dest.path) {
                        stackLogger.info("deposit skipped, exists: \(name, privacy: .public)")
                        // Still count it so a drop onto an existing name can
                        // reorder the already-present item in the grid.
                        landed.append(name)
                        continue
                    }
                    try fm.moveItem(at: url, to: dest)
                    landed.append(name)
                } catch {
                    do {
                        try fm.copyItem(at: url, to: dest)
                        landed.append(name)
                    } catch {
                        stackLogger.error("deposit failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Other sorts decide the position themselves.
                if !landed.isEmpty, stack.sort == .manual {
                    self.dockModel.insertStackItemOrder(stackID: stackID, names: landed, at: insertAt, seed: seed)
                }
                if let latest = self.dockModel.stacks.first(where: { $0.id == stackID }) {
                    self.contents.refresh(latest, reason: "deposit")
                }
            }
        }
    }

    // MARK: - Outside click

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.expandedID != nil else { return }
            let screen = NSEvent.mouseLocation
            if self.overlay.containsScreenPoint(screen) { return }
            if let id = self.expandedID,
               let stack = self.dockModel.stacks.first(where: { $0.id == id }),
               self.hover.screenFrame(forTargetID: stack.hoverID)?.contains(screen) == true {
                return
            }
            self.collapse(reason: "clicked outside")
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

private let stackLogger = Logger(subsystem: "com.james.portside", category: "Stacks")
