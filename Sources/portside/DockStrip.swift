import SwiftUI
import UniformTypeIdentifiers
import os.log

private let stripLogger = Logger(subsystem: "com.james.portside", category: "DockStrip")

/// Screen-derived limits for the strip. Updated when displays change.
final class DockLayout: ObservableObject {
    @Published private(set) var visibleSize: CGSize = .zero
    /// Largest tile that fits everything on screen right now, as computed by
    /// the strip. The Settings icon size slider stops here, the same limit
    /// the separator drag uses.
    @Published private(set) var fitTileSize: CGFloat = DockModel.iconSizeRange.upperBound
    private var observer: NSObjectProtocol?

    /// Room left for the panel's own insets and a small margin at each end.
    private let reservedLength: CGFloat = 40

    init() {
        update()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }
    }

    /// Longest the strip may be along `edge` (width on the bottom, height on
    /// the sides, below the menu bar).
    func maxStripLength(for edge: DockEdge) -> CGFloat {
        (edge.isVertical ? visibleSize.height : visibleSize.width) - reservedLength
    }

    func reportFitTileSize(_ size: CGFloat) {
        let clamped = min(size, DockModel.iconSizeRange.upperBound)
        if clamped != fitTileSize { fitTileSize = clamped }
    }

    private func update() {
        visibleSize = DockScreen.visibleFrame.size
    }
}

/// Strip interactions the engine has to know about (they affect hiding).
final class DockInteractions {
    /// True while the separator is being dragged to resize the icons.
    var onResizingChanged: ((Bool) -> Void)?
    /// The strip's measured size, after every change (icon size, items,
    /// widgets, edge). The panel sizes its window from this. The first
    /// report comes while the panel is being built, before anyone listens,
    /// so the last one is kept and replayed when this is set.
    var onContentSizeChanged: ((CGSize) -> Void)? {
        didSet { if let lastContentSize { onContentSizeChanged?(lastContentSize) } }
    }
    private(set) var lastContentSize: CGSize?

    func contentSizeChanged(_ size: CGSize) {
        lastContentSize = size
        onContentSizeChanged?(size)
    }
    /// A group tile was clicked (expand or collapse it).
    var onGroupTapped: ((String) -> Void)?
    /// "Rename" from a group tile's context menu.
    var onRenameGroup: ((String) -> Void)?
    /// "Settings..." from the separator's context menu.
    var onOpenSettings: (() -> Void)?
    /// Asks whether to remove a group tile (alert, hide held off meanwhile).
    var confirmRemoveGroup: ((FolderGroup) -> GroupRemovalChoice)?
    /// A file drag entered the strip (true) or left it, dropped or not
    /// (false, with a reason for the log).
    var onDragOverStrip: ((Bool, String) -> Void)?
    /// The group tile under a file drag that would open files (nil: none,
    /// or the drag left or dropped). Drives spring-loading.
    var onDragOverGroupTile: ((String?) -> Void)?
}

/// SwiftUI view that renders the dock strip: pinned apps, a separator,
/// running apps that are not pinned (like the native Dock), a separator,
/// then widgets. Horizontal on the bottom edge, vertical on the sides.
///
/// Like the native Dock, tiles shrink below `iconSize` when everything would
/// not fit on screen. Widgets are measured in tiles, so they shrink too.
/// On side docks widgets keep their width, so the column is as wide as the
/// widest widget.
///
/// Reorder uses a plain DragGesture inside the strip, not .onDrag: SwiftUI
/// never starts a drag session from this panel because Portside is never the
/// active app, and .onDrag has no "ended" callback anyway. The same gesture
/// removes an item dragged clearly out of the dock (`DragOutController`);
/// widgets get a drag-out-only gesture.
struct DockStrip: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var runningApps: RunningApps
    @ObservedObject var widgets: WidgetStore
    @ObservedObject var layout: DockLayout
    /// Which group is expanded, so its tile can show it.
    @ObservedObject var groups: GroupController
    /// Not observed here: only the tiles care which one is bouncing.
    let bouncer: LaunchBouncer
    /// Receives item frames for hover labels. Not observed: it never
    /// changes what the strip renders.
    let hover: DockHover
    let interactions: DockInteractions
    /// Drag-out-to-remove: the "Remove" label, poof and Escape.
    let dragOut: DragOutController
    /// Not observed here either: only small per-tile modifiers read it, so
    /// a mouse move never re-renders the strip.
    let magnifier: Magnifier
    /// The Trash tile's state and actions. The tile observes it.
    let trash: TrashController

    /// Id of the pinned entry (app or group) or widget being dragged, if any.
    @State private var dragging: String?
    /// Token of the current drag (see `DragOutController`), nil when idle.
    @State private var dragToken: Int?
    /// Where the dragged entry was when the drag began.
    @State private var dragStartIndex = 0
    /// The dragged item is clearly outside the dock right now.
    @State private var dragOutside = false
    /// Cursor (screen coordinates) and tile size when a separator drag began.
    @State private var resizeStart: (mouse: CGPoint, tile: CGFloat)?
    /// App tile a file drag is over that can open the dragged items.
    @State private var dropTargetID: String?
    /// The file drag over the strip right now (URLs and per-app verdicts).
    @State private var fileDrop = FileDropSession()
    /// Tile frames in the strip's root space, for hit-testing drops.
    @State private var tileFrames: [HoverTarget] = []

    private let spacing = DockMetrics.spacing
    private let alongPadding: CGFloat = 8
    private let separatorPadding: CGFloat = 4
    private var separatorLength: CGFloat { 1 + separatorPadding * 2 }
    private static let space = "strip"

    /// Largest tile that still fits everything on screen, ignoring `iconSize`.
    private func maxTileSize(extrasCount: Int, showsTrash: Bool, edge: DockEdge) -> CGFloat {
        let apps = dockModel.entries.count + extrasCount + (showsTrash ? 1 : 0)
        let separators = (extrasCount > 0 ? 1 : 0) + (widgets.hosts.isEmpty && !showsTrash ? 0 : 1)
        let items = apps + widgets.hosts.count + separators
        // Horizontal: widgets are N tiles wide with gaps inside them.
        // Vertical: every item is one tile tall.
        let units = edge.isVertical ? widgets.hosts.count : widgets.hosts.reduce(0) { $0 + $1.size.rawValue }
        let innerWidgetGaps = edge.isVertical ? 0 : units - widgets.hosts.count
        let fixed = alongPadding * 2 + separatorLength * CGFloat(separators)
            + spacing * CGFloat(max(items - 1, 0) + innerWidgetGaps)
        let tileUnits = CGFloat(max(apps + units, 1))
        let fit = ((layout.maxStripLength(for: edge) - fixed) / tileUnits).rounded(.down)
        return max(DockModel.iconSizeRange.lowerBound, fit)
    }

    private var unpinnedRunning: [(PinnedApp, NSRunningApplication)] {
        runningApps.apps.compactMap { running in
            guard let app = PinnedApp(runningApp: running), !dockModel.isPinned(app) else { return nil }
            if dockModel.allPinnedApps.contains(where: { runningApps.runningInstance(of: $0) == running }) { return nil }
            return (app, running)
        }
    }

    var body: some View {
        let edge = dockModel.edge
        let extras = unpinnedRunning
        let showsSelf = runningApps.includesSelf
        let showsTrash = dockModel.showTrash
        let maxTile = maxTileSize(extrasCount: extras.count + (showsSelf ? 1 : 0), showsTrash: showsTrash, edge: edge)
        let tile = min(dockModel.iconSize, maxTile)
        // Items align to the far side so icons line up with widgets.
        let stack = edge.isVertical
            ? AnyLayout(VStackLayout(alignment: edge == .left ? .trailing : .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))

        stack {
            ForEach(dockModel.entries) { entry in
                entryView(entry, tile: tile)
                    .opacity(dragging == entry.id ? (dragOutside ? 0.25 : 0.5) : 1)
                    .scaleEffect(dragging == entry.id ? 1.08 : 1, anchor: edge.growthAnchor)
                    .gesture(reorderGesture(for: entry, tile: tile, vertical: edge.isVertical))
            }

            if !extras.isEmpty || showsSelf {
                separator(tile: tile, maxTile: maxTile, edge: edge)
                    .magnifiedShift()
                ForEach(extras, id: \.0.id) { app, running in
                    DockItemView(app: app, running: running, isPinned: false, size: tile, dockModel: dockModel, bouncer: bouncer,
                                 isDropTarget: dropTargetID == app.id)
                }
                if showsSelf {
                    PortsideTileView(size: tile) { interactions.onOpenSettings?() }
                }
            }

            // Widgets, then the Trash at the far end, like the native Dock's
            // stacks and Trash section.
            if !widgets.hosts.isEmpty || showsTrash {
                separator(tile: tile, maxTile: maxTile, edge: edge)
                    .magnifiedShift()
                ForEach(widgets.hosts) { host in
                    host.view
                        .magnifiedShift()
                        .opacity(dragging == host.id ? (dragOutside ? 0.25 : 0.5) : 1)
                        .gesture(widgetDragGesture(for: host, tile: tile))
                        .contextMenu {
                            Button("Remove Widget") { dockModel.setWidget(host.id, enabled: false) }
                        }
                }
                if showsTrash {
                    TrashTileView(trash: trash, size: tile, isDropTarget: dropTargetID == TrashController.hoverID)
                }
            }
        }
        .environment(\.dockTileSize, tile)
        .environment(\.dockEdge, edge)
        .coordinateSpace(name: DockStrip.space)
        .padding(edge.isVertical ? .vertical : .horizontal, alongPadding)
        .padding(edge.farSide, 6)
        .padding(edge.nearSide, 3)
        .magnifiedShelf(dockModel.look)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(
            dockModel: dockModel, interactions: interactions, session: fileDrop, targetID: $dropTargetID,
            tileFrames: tileFrames, apps: dropApps(extras: extras), trash: showsTrash ? trash : nil,
            runningApps: runningApps, bouncer: bouncer,
            tile: tile, slotLength: tile + spacing, leadingInset: alongPadding, vertical: edge.isVertical))
        .onChange(of: maxTile, initial: true) { _, fit in layout.reportFitTileSize(fit) }
        .onChange(of: tile) { _, size in bouncer.tileSizeChanged(size) }
        .fixedSize()
        // NSHostingView does not report intrinsic size changes to AppKit
        // here, so the strip reports its own size.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            interactions.contentSizeChanged(size)
        }
        // Root space = the hosting view's bounds, so DockPanel can convert
        // hover target frames to screen coordinates.
        .coordinateSpace(name: DockHover.space)
        .onPreferenceChange(HoverTargetsKey.self) { targets in
            magnifier.updateTiles(targets)
            hover.updateTargets(targets)
            tileFrames = targets
        }
        // Fills the hosting view, which is bigger than the strip only while
        // magnified tiles need room. The strip stays against the screen edge
        // and centered along it, so adding room never moves it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.stripAlignment)
        .environment(\.magnifier, magnifier)
    }

    /// App tiles that take file drops, by hover id: pinned apps and running
    /// apps that are not pinned. Groups, Portside's own tile, widgets and
    /// separators are not in here, so they reject non-app drops.
    private func dropApps(extras: [(PinnedApp, NSRunningApplication)]) -> [String: (app: PinnedApp, isPinned: Bool)] {
        var apps: [String: (app: PinnedApp, isPinned: Bool)] = [:]
        for case .app(let app) in dockModel.entries { apps[app.id] = (app, true) }
        for (app, _) in extras { apps[app.id] = (app, false) }
        return apps
    }

    @ViewBuilder private func entryView(_ entry: DockEntry, tile: CGFloat) -> some View {
        switch entry {
        case .app(let app):
            DockItemView(app: app, running: runningApps.runningInstance(of: app), isPinned: true, size: tile, dockModel: dockModel, bouncer: bouncer,
                         isDropTarget: dropTargetID == app.id)
        case .group(let group):
            GroupTileView(
                group: group,
                size: tile,
                isExpanded: groups.expandedID == group.id,
                anyRunning: group.apps.contains { runningApps.isRunning($0) },
                onToggle: { interactions.onGroupTapped?(group.id) },
                onRename: { interactions.onRenameGroup?(group.id) },
                onRemove: { removeGroupAfterConfirming(group, fromDrag: false) },
                dockModel: dockModel
            )
        }
    }

    // MARK: - Separator (drag to resize)

    /// A thin line between sections. Like the native Dock's separator,
    /// dragging it away from the screen edge grows the icons and toward the
    /// edge shrinks them.
    private func separator(tile: CGFloat, maxTile: CGFloat, edge: DockEdge) -> some View {
        let vertical = edge.isVertical
        return Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: vertical ? tile * 0.8 : 1, height: vertical ? 1 : tile * 0.8)
            .padding(vertical ? .vertical : .horizontal, separatorPadding)
            .padding(edge.farSide, tile * 0.1)
            .contentShape(Rectangle())
            .modifier(ResizePointer(edge: edge, isResizing: resizeStart != nil))
            .gesture(resizeGesture(maxTile: maxTile, tile: tile, edge: edge))
            .appKitContextMenu(edge: edge) { dividerMenu() }
            .accessibilityLabel("Dock separator")
    }

    /// Divider right-click, in the native Dock's order.
    private func dividerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(dockModel.autoHide ? "Turn Hiding Off" : "Turn Hiding On") {
            dockModel.setAutoHide(!dockModel.autoHide)
        })
        menu.addItem(ClosureMenuItem(dockModel.magnificationEnabled ? "Turn Magnification Off" : "Turn Magnification On") {
            dockModel.setMagnificationEnabled(!dockModel.magnificationEnabled)
        })
        let position = NSMenuItem(title: "Position on Screen", action: nil, keyEquivalent: "")
        let positions = NSMenu()
        positions.autoenablesItems = false
        for choice in DockEdge.allCases {
            let item = ClosureMenuItem(choice.title) { dockModel.setEdge(choice) }
            item.state = choice == dockModel.edge ? .on : .off
            positions.addItem(item)
        }
        position.submenu = positions
        menu.addItem(position)
        menu.addItem(ClosureMenuItem("Dock Settings...") { interactions.onOpenSettings?() })
        return menu
    }

    private func resizeGesture(maxTile: CGFloat, tile: CGFloat, edge: DockEdge) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in
                // Screen coordinates on purpose: the panel moves and resizes
                // as the tiles change, so view coordinates would drift.
                let mouse = NSEvent.mouseLocation
                if resizeStart == nil {
                    resizeStart = (mouse, tile)
                    interactions.onResizingChanged?(true)
                    stripLogger.info("resize started at \(tile, format: .fixed(precision: 0))pt")
                }
                guard let start = resizeStart else { return }
                let delta: CGFloat
                switch edge {
                case .bottom: delta = mouse.y - start.mouse.y
                case .left: delta = mouse.x - start.mouse.x
                case .right: delta = start.mouse.x - mouse.x
                }
                dockModel.setIconSize(min(start.tile + delta, maxTile), persist: false)
                ResizeCursor.show(edge)
            }
            .onEnded { _ in
                resizeStart = nil
                ResizeCursor.show(nil)
                dockModel.setIconSize(dockModel.iconSize, persist: true)
                interactions.onResizingChanged?(false)
                stripLogger.info("resize ended at \(dockModel.iconSize, format: .fixed(precision: 0))pt")
            }
    }

    // MARK: - Reorder and drag out

    /// Live reorder: the dragged tile jumps to whichever slot the cursor is
    /// over. Order is saved once, on release. Clearly outside the dock the
    /// tile goes back to its starting slot and a release removes it, like
    /// "Remove from Dock" in its menu. Escape puts it back.
    private func reorderGesture(for entry: DockEntry, tile: CGFloat, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockStrip.space))
            .onChanged { value in
                if dragToken == nil {
                    let start = dockModel.entries.firstIndex { $0.id == entry.id } ?? 0
                    dragging = entry.id
                    dragStartIndex = start
                    dragOutside = false
                    stripLogger.info("reorder started: \(entry.id, privacy: .public)")
                    dragToken = dragOut.begin(itemID: entry.id, source: .strip, label: "Remove",
                                              preview: preview(for: entry, tile: tile), size: tile) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            dockModel.move(entryID: entry.id, toIndex: start, persist: false)
                        }
                        dragging = nil
                        dragOutside = false
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                let outside = dragOut.update(token)
                if outside != dragOutside { dragOutside = outside }
                let slot: Int
                if outside || tileFrames.contains(where: {
                    $0.id == TrashController.hoverID && $0.frame.contains(value.location)
                }) {
                    // Internal tile drags onto Trash cancel the reorder.
                    slot = dragStartIndex
                } else {
                    let position = vertical ? value.location.y : value.location.x
                    slot = Int((position / (tile + spacing)).rounded(.down))
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    dockModel.move(entryID: entry.id, toIndex: slot, persist: false)
                }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                let canceled = dragOut.isCanceled(token)
                var deferred = false
                if case .group(let group) = entry, GroupRemoval.needsConfirmation(group) { deferred = true }
                let remove = dragOut.end(token, deferResolution: deferred)
                dragging = nil
                dragOutside = false
                if remove, case .group(let group) = entry, deferred {
                    // Alert after this gesture callback returns. The tile is
                    // already back in its slot, so Cancel has nothing to undo.
                    DispatchQueue.main.async { removeGroupAfterConfirming(group, fromDrag: true) }
                    return
                }
                if remove {
                    withAnimation(removalAnimation) {
                        switch entry {
                        case .app(let app): dockModel.unpin(app)
                        case .group(let group): dockModel.removeGroup(groupID: group.id)
                        }
                    }
                    stripLogger.info("removed by dragging out: \(entry.id, privacy: .public)")
                    return
                }
                if canceled {
                    // Already back in its slot; the saved order never changed.
                    stripLogger.info("reorder canceled: \(entry.id, privacy: .public)")
                    return
                }
                dockModel.saveOrder()
                let index = dockModel.entries.firstIndex { $0.id == entry.id } ?? -1
                stripLogger.info("reorder ended: \(entry.id, privacy: .public) at slot \(index)")
            }
    }

    /// Widgets do not reorder in the strip, but one dragged clearly out and
    /// released is turned off, like "Remove Widget" in its menu.
    private func widgetDragGesture(for host: WidgetHost, tile: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockStrip.space))
            .onChanged { _ in
                if dragToken == nil {
                    dragging = host.id
                    dragOutside = false
                    let preview = host.view
                        .environment(\.dockTileSize, tile)
                        .environment(\.dockEdge, .bottom)
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    dragToken = dragOut.begin(itemID: host.id, source: .strip, label: "Remove",
                                              preview: AnyView(preview), size: tile + 8) {
                        dragging = nil
                        dragOutside = false
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                let outside = dragOut.update(token)
                if outside != dragOutside { dragOutside = outside }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                dragging = nil
                dragOutside = false
                guard dragOut.end(token) else { return }
                withAnimation(removalAnimation) {
                    dockModel.setWidget(host.id, enabled: false)
                }
                stripLogger.info("widget removed by dragging out: \(host.id, privacy: .public)")
            }
    }

    /// Both group removal paths. Non-empty groups ask first; empty ones go
    /// at once. `fromDrag`: the drag overlay is waiting to poof or vanish.
    private func removeGroupAfterConfirming(_ group: FolderGroup, fromDrag: Bool) {
        let choice: GroupRemovalChoice
        if GroupRemoval.needsConfirmation(group) {
            DispatchQueue.main.async {
                let picked = interactions.confirmRemoveGroup?(group) ?? GroupRemoval.confirm(group)
                finishGroupRemoval(group, picked, fromDrag: fromDrag)
            }
            return
        }
        choice = .remove
        finishGroupRemoval(group, choice, fromDrag: fromDrag)
    }

    private func finishGroupRemoval(_ group: FolderGroup, _ choice: GroupRemovalChoice, fromDrag: Bool) {
        if fromDrag { dragOut.resolve(remove: choice != .cancel) }
        withAnimation(removalAnimation) {
            switch choice {
            case .ungroup: dockModel.ungroup(groupID: group.id)
            case .remove: dockModel.removeGroup(groupID: group.id)
            case .cancel: break
            }
        }
        stripLogger.info("group \(group.id, privacy: .public): \(String(describing: choice), privacy: .public)")
    }

    private var removalAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)
    }

    /// What floats under the cursor while an entry is outside the dock.
    private func preview(for entry: DockEntry, tile: CGFloat) -> AnyView {
        switch entry {
        case .app(let app):
            return AnyView(Image(nsImage: IconCache.shared.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: tile, height: tile))
        case .group(let group):
            return AnyView(GroupTileView(group: group, size: tile, isExpanded: false, anyRunning: false,
                                         onToggle: {}, onRename: {}, onRemove: {}, dockModel: dockModel)
                .environment(\.dockEdge, .left)
                .frame(height: tile))
        }
    }
}

/// Resize cursor while hovering the separator: up-down on the bottom dock,
/// left-right on side docks. Set by hand on every hover move rather than
/// with `pointerStyle`: AppKit's cursor rects only run for the active app,
/// and Portside never is. Works while another app is frontmost only when
/// `BackgroundCursor` is enabled. During a drag the cursor can leave the
/// separator, so the gesture also sets it on every step.
private struct ResizePointer: ViewModifier {
    let edge: DockEdge
    let isResizing: Bool

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            guard !isResizing else { return }
            switch phase {
            case .active: ResizeCursor.show(edge)
            case .ended: ResizeCursor.show(nil)
            }
        }
    }
}

enum ResizeCursor {
    static func show(_ edge: DockEdge?) {
        guard let edge else {
            NSCursor.arrow.set()
            return
        }
        (edge.isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }
}

/// File drops on the strip (see `FileDropSession` for the rules):
/// `.app` bundles pin at the slot under the cursor; other files open in the
/// app tile under the cursor if that app can open them, else the drop is
/// rejected (no plus cursor, nothing happens). Anything over the Trash tile
/// goes to the Trash if every item can, else it is rejected.
private struct FileDropDelegate: DropDelegate {
    let dockModel: DockModel
    let interactions: DockInteractions
    let session: FileDropSession
    @Binding var targetID: String?
    let tileFrames: [HoverTarget]
    let apps: [String: (app: PinnedApp, isPinned: Bool)]
    /// Nil while the Trash tile is hidden.
    let trash: TrashController?
    let runningApps: RunningApps
    let bouncer: LaunchBouncer
    let tile: CGFloat
    let slotLength: CGFloat
    let leadingInset: CGFloat
    let vertical: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        session.begin()
        interactions.onDragOverStrip?(true, "entered")
        _ = dropUpdated(info: info)
    }

    func dropExited(info: DropInfo) {
        setTarget(nil)
        session.end()
        interactions.onDragOverGroupTile?(nil)
        interactions.onDragOverStrip?(false, "exited")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let trash, isOverTrash(info) {
            interactions.onDragOverGroupTile?(nil)
            let ok = session.canTrash(using: trash)
            setTarget(ok ? TrashController.hoverID : nil)
            return DropProposal(operation: ok ? .move : .forbidden)
        }
        switch session.mode {
        case .pin:
            setTarget(nil)
            return DropProposal(operation: .copy)
        case .open:
            return DropProposal(operation: updateTarget(info) == nil ? .forbidden : .copy)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        interactions.onDragOverStrip?(false, "dropped")
        defer {
            setTarget(nil)
            session.end()
            interactions.onDragOverGroupTile?(nil)
        }
        if let trash, isOverTrash(info) {
            guard session.canTrash(using: trash) else {
                stripLogger.info("file drop rejected: can't move it to the Trash")
                return false
            }
            trash.moveToTrash(session.urls)
            return true
        }
        switch session.mode {
        case .pin:
            return pin(info)
        case .open:
            guard let id = updateTarget(info), let entry = apps[id] else {
                stripLogger.info("file drop rejected: no app here can open it")
                return false
            }
            open(session.urls, with: entry.app, isPinned: entry.isPinned)
            return true
        }
    }

    /// The cursor is over the Trash tile (same slop as hover labels).
    private func isOverTrash(_ info: DropInfo) -> Bool {
        let slop = -DockMetrics.spacing / 2
        return tileFrames.contains {
            $0.id == TrashController.hoverID
                && $0.frame.insetBy(dx: vertical ? 0 : slop, dy: vertical ? slop : 0).contains(info.location)
        }
    }

    /// The app tile under the cursor that can open the dragged items, now
    /// also the highlighted one.
    @discardableResult
    private func updateTarget(_ info: DropInfo) -> String? {
        guard session.mode == .open else {
            setTarget(nil)
            interactions.onDragOverGroupTile?(nil)
            return nil
        }
        // Same slop as hover labels: no gap between neighbors.
        let slop = -DockMetrics.spacing / 2
        let hit = tileFrames.first {
            $0.frame.insetBy(dx: vertical ? 0 : slop, dy: vertical ? slop : 0).contains(info.location)
        }
        // Group tiles never take the drop, but resting on one springs it open.
        let groupPrefix = "group:"
        interactions.onDragOverGroupTile?(hit.flatMap { $0.id.hasPrefix(groupPrefix) ? String($0.id.dropFirst(groupPrefix.count)) : nil })
        let id = hit.flatMap { hit in apps[hit.id].flatMap { session.canOpen(with: $0.app) ? hit.id : nil } }
        setTarget(id)
        return id
    }

    private func setTarget(_ id: String?) {
        guard targetID != id else { return }
        targetID = id
        stripLogger.info("drop target: \(id ?? "none", privacy: .public)")
    }

    private func open(_ urls: [URL], with app: PinnedApp, isPinned: Bool) {
        let running = runningApps.runningInstance(of: app)
        stripLogger.info("file drop: opening \(urls.count) item(s) with \(app.displayName, privacy: .public)")
        if running == nil && isPinned {
            bouncer.launch(app, size: tile, documents: urls)
        } else {
            AppLauncher.open(app, running: running, documents: urls)
        }
    }

    private func pin(_ info: DropInfo) -> Bool {
        let position = vertical ? info.location.y : info.location.x
        let slot = Int(((position - leadingInset) / slotLength).rounded())
        let index = min(max(slot, 0), dockModel.entries.count)
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let app = PinnedApp(appURL: url) else { return }
                DispatchQueue.main.async {
                    dockModel.pin(app, at: index)
                    stripLogger.info("pinned from Finder drop: \(app.displayName, privacy: .public)")
                }
            }
        }
        return !providers.isEmpty
    }
}
