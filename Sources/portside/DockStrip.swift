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
    private var observers: [NSObjectProtocol] = []

    /// Room left for the panel's own insets and a small margin at each end.
    private let reservedLength: CGFloat = 40

    init() {
        update()
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification, .dockScreenDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
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
    /// A folder stack tile was clicked.
    var onStackTapped: ((String) -> Void)?
    /// "Rename" from a group tile's context menu.
    var onRenameGroup: ((String) -> Void)?
    /// "Settings..." from the separator's context menu.
    var onOpenSettings: (() -> Void)?
    /// Asks whether to remove a group tile (alert, hide held off meanwhile).
    var confirmRemoveGroup: ((FolderGroup) -> GroupRemovalChoice)?
    /// Dropped a dock tile on the Trash: Remove / Move to Trash / Cancel.
    var confirmTrashDrop: ((DockTrashDropTarget) -> DockTrashDropChoice)?
    /// A file drag entered the strip (true) or left it, dropped or not
    /// (false, with a reason for the log).
    var onDragOverStrip: ((Bool, String) -> Void)?
    /// The group tile under a file drag that would open files (nil: none,
    /// or the drag left or dropped). Drives spring-loading.
    var onDragOverGroupTile: ((String?) -> Void)?
    /// Folder stack tile under a file drag (opens grid immediately / deposit).
    var onDragOverStackTile: ((String?) -> Void)?
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
    @ObservedObject var stacks: StackController
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
    /// Notification badges mirrored from the native Dock.
    @ObservedObject var badges: DockBadges

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
    /// While pinning folders from Finder: index in `stacks` where the drop
    /// would land (a gap opens there, like the native Dock).
    @State private var stackInsertIndex: Int?
    /// While pinning apps from Finder: index in `entries` for the gap.
    @State private var entryInsertIndex: Int?
    /// An internal tile drag is over the Trash right now.
    @State private var dragOverTrash = false
    /// The file drag over the strip right now (URLs and per-app verdicts).
    @State private var fileDrop = FileDropSession()
    /// Brings a running app forward when a file drag rests on its tile.
    @State private var appSpringLoad = AppSpringLoad()
    /// Tile frames in the strip's root space, for hit-testing drops.
    @State private var tileFrames: [HoverTarget] = []
    /// Every layout slot's frame (apps, widgets, separators, ...) in the
    /// strip's root space, for placing a dragged item.
    @State private var layoutFrames: [String: CGRect] = [:]

    private var spacing: CGFloat { dockModel.iconGap }
    private let alongPadding: CGFloat = 8
    /// Air on each side of a separator hairline: a base plus the icon
    /// gap, so it tracks the gap setting. The HStack already
    /// inserts `spacing`, so the separator pads itself by the rest.
    private static let separatorAirBase: CGFloat = 5
    private var separatorAir: CGFloat { Self.separatorAirBase + spacing }
    private var separatorPad: CGFloat { max(0, separatorAir - spacing) }
    private var separatorLength: CGFloat { 1 + separatorPad * 2 }
    private static let space = "strip"
    /// Minimum hit size along the dock for the separator (points).
    private static let separatorHitAlong: CGFloat = 9

    /// Largest tile that still fits everything on screen, ignoring `iconSize`.
    private func maxTileSize(extrasCount: Int, showsTrash: Bool, stackCount: Int, separators: Int, edge: DockEdge) -> CGFloat {
        let apps = dockModel.entries.count + extrasCount + (showsTrash ? 1 : 0) + stackCount
        let items = apps + widgets.hosts.count + separators
        // Horizontal: widgets are N tiles wide with gaps inside them.
        // Vertical: every item is one tile tall.
        let units = widgets.hosts.reduce(0) { $0 + shownSize($1, edge: edge).rawValue }
        let innerWidgetGaps = units - widgets.hosts.count
        let fixed = alongPadding * 2 + separatorLength * CGFloat(separators)
            + spacing * CGFloat(max(items - 1, 0) + innerWidgetGaps)
        // Widgets sit in full-tile slots (chrome inset like groups), so they
        // count as `units` tiles with no extra margin in the fit math.
        let tileUnits = max(CGFloat(apps + units), 1)
        let fit = ((layout.maxStripLength(for: edge) - fixed) / tileUnits).rounded(.down)
        return max(DockModel.iconSizeRange.lowerBound, fit)
    }

    private var unpinnedRunning: [(PinnedApp, NSRunningApplication?)] {
        runningApps.apps.compactMap { running in
            guard let app = PinnedApp(runningApp: running), !dockModel.isPinned(app) else { return nil }
            if dockModel.allPinnedApps.contains(where: { runningApps.runningInstance(of: $0) == running }) { return nil }
            return (app, running)
        }
    }

    /// Native "Show suggested and recent apps": recently quit apps that are
    /// neither pinned nor running, after the running apps.
    private func recents(after running: [(PinnedApp, NSRunningApplication?)]) -> [(PinnedApp, NSRunningApplication?)] {
        guard dockModel.showRecents else { return [] }
        let shown = Set(running.map(\.0.id))
        return dockModel.recentApps.compactMap { app in
            guard !shown.contains(app.id), !dockModel.allPinnedApps.contains(where: { $0.id == app.id }),
                  FileManager.default.fileExists(atPath: app.url.path) else { return nil }
            return (app, nil)
        }
    }

    var body: some View {
        let edge = dockModel.edge
        let running = unpinnedRunning
        let extras = running + recents(after: running)
        let showsSelf = runningApps.includesSelf
        let showsTrash = dockModel.showTrash
        let folderStacks = dockModel.stacks
        let insertingStack = stackInsertIndex != nil
        let insertingEntry = entryInsertIndex != nil
        let runningVisible = !extras.isEmpty || showsSelf
        let widgetByID = Dictionary(widgets.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Everything on the dock, in the order the user arranged it.
        let items = dockModel.resolvedLayout().filter { id in
            if id == DockModel.runningID { return runningVisible }
            if id.hasPrefix("widget:") { return widgetByID[String(id.dropFirst("widget:".count))] != nil }
            return true
        }
        let separatorCount = items.filter { $0.hasPrefix(DockModel.separatorPrefix) }.count + (runningVisible && items.contains(DockModel.runningID) ? 1 : 0)
        let maxTile = maxTileSize(
            extrasCount: extras.count + (showsSelf ? 1 : 0) + (insertingEntry ? 1 : 0),
            showsTrash: showsTrash,
            stackCount: folderStacks.count + (insertingStack ? 1 : 0),
            separators: separatorCount,
            edge: edge
        )
        let tile = min(dockModel.iconSize, maxTile)
        let spacing = self.spacing
        let entryByID = Dictionary(dockModel.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stackByID = Dictionary(folderStacks.map { ($0.hoverID, $0) }, uniquingKeysWith: { a, _ in a })
        let gaps = insertionGaps(items: items)
        // Items align to the far side so icons line up with widgets.
        let stack = edge.isVertical
            ? AnyLayout(VStackLayout(alignment: edge == .left ? .trailing : .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))

        stack {
            if gaps.leading { insertionGap(tile: tile) }
            ForEach(items, id: \.self) { id in
                if gaps.before == id { insertionGap(tile: tile) }
                slot(id, tile: tile, maxTile: maxTile, edge: edge, extras: extras, showsSelf: showsSelf,
                     entryByID: entryByID, stackByID: stackByID, widgetByID: widgetByID)
                    .layoutSlot(id)
                if gaps.after == id { insertionGap(tile: tile) }
            }
            if gaps.trailing { insertionGap(tile: tile) }
        }
        .environment(\.dockTileSize, tile)
        .environment(\.dockIconGap, spacing)
        .environment(\.dockEdge, edge)
        .coordinateSpace(name: DockStrip.space)
        .padding(edge.isVertical ? .vertical : .horizontal, alongPadding)
        .padding(edge.farSide, 6)
        .padding(edge.nearSide, 3)
        .magnifiedShelf(dockModel.look)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(
            dockModel: dockModel, interactions: interactions, session: fileDrop, targetID: $dropTargetID,
            stackInsertIndex: $stackInsertIndex, entryInsertIndex: $entryInsertIndex,
            tileFrames: tileFrames, apps: dropApps(extras: extras), trash: showsTrash ? trash : nil,
            stackController: stacks,
            runningApps: runningApps, bouncer: bouncer, appSpringLoad: appSpringLoad,
            tile: tile, spacing: spacing, vertical: edge.isVertical))
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
            // Widgets get hover labels but never grow.
            magnifier.updateTiles(targets.filter { !$0.id.hasPrefix("widget:") })
            hover.updateTargets(targets)
            tileFrames = targets
        }
        .onPreferenceChange(LayoutFramesKey.self) { layoutFrames = $0 }
        // Fills the hosting view, which is bigger than the strip only while
        // magnified tiles need room. The strip stays against the screen edge
        // and centered along it, so adding room never moves it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.stripAlignment)
        .environment(\.magnifier, magnifier)
    }

    /// App tiles that take file drops, by hover id: pinned apps and running
    /// apps that are not pinned. Groups, Portside's own tile, widgets and
    /// separators are not in here, so they reject non-app drops.
    private func dropApps(extras: [(PinnedApp, NSRunningApplication?)]) -> [String: (app: PinnedApp, isPinned: Bool)] {
        var apps: [String: (app: PinnedApp, isPinned: Bool)] = [:]
        for case .app(let app) in dockModel.entries { apps[app.id] = (app, true) }
        for (app, _) in extras { apps[app.id] = (app, false) }
        return apps
    }

    /// Where the Finder-drop insertion gap shows, among the layout's ids.
    /// A new app lands right after the entry before the gap (or before the
    /// first entry), a new folder the same way among folders.
    private func insertionGaps(items: [String]) -> (leading: Bool, before: String?, after: String?, trailing: Bool) {
        if let k = entryInsertIndex {
            let ids = dockModel.entries.map(\.id).filter { items.contains($0) }
            if ids.isEmpty { return (true, nil, nil, false) }
            return k == 0 ? (false, ids[0], nil, false) : (false, nil, ids[min(k, ids.count) - 1], false)
        }
        if let k = stackInsertIndex {
            let ids = dockModel.stacks.map(\.hoverID).filter { items.contains($0) }
            if k == 0 {
                if let first = ids.first { return (false, first, nil, false) }
                if items.contains(DockModel.trashID) { return (false, DockModel.trashID, nil, false) }
                return (false, nil, nil, true)
            }
            return (false, nil, ids[min(k, ids.count) - 1], false)
        }
        return (false, nil, nil, false)
    }

    /// One item of the layout.
    @ViewBuilder private func slot(
        _ id: String, tile: CGFloat, maxTile: CGFloat, edge: DockEdge,
        extras: [(PinnedApp, NSRunningApplication?)], showsSelf: Bool,
        entryByID: [String: DockEntry], stackByID: [String: FolderStack], widgetByID: [String: WidgetHost]
    ) -> some View {
        if let entry = entryByID[id] {
            pinnedSlot(entry, tile: tile, vertical: edge.isVertical)
        } else if id == DockModel.runningID {
            // The unpinned running apps and, while Settings is open, Portside
            // itself, behind their own separator, moving as one block.
            let block = edge.isVertical
                ? AnyLayout(VStackLayout(alignment: edge == .left ? .trailing : .leading, spacing: spacing))
                : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
            block {
                separator(tile: tile, maxTile: maxTile, edge: edge, id: nil)
                    .magnifiedShift()
                ForEach(extras.filter { $0.1 != nil }, id: \.0.id) { app, running in
                    unpinnedTile(app, running: running, tile: tile)
                }
                if showsSelf {
                    PortsideTileView(size: tile, showsIndicator: dockModel.showIndicators) { interactions.onOpenSettings?() }
                }
                // Recents (not running) after everything running, like the
                // native Dock's recents section.
                ForEach(extras.filter { $0.1 == nil }, id: \.0.id) { app, _ in
                    unpinnedTile(app, running: nil, tile: tile)
                }
            }
        } else if id.hasPrefix(DockModel.separatorPrefix) {
            separator(tile: tile, maxTile: maxTile, edge: edge, id: id)
                .magnifiedShift()
        } else if id.hasPrefix("widget:"), let host = widgetByID[String(id.dropFirst("widget:".count))] {
            host.view
                .environment(\.widgetSize, shownSize(host, edge: edge))
                .magnifiedShift()
                .opacity(dragging == host.id ? 0 : 1)
                .gesture(widgetDragGesture(for: host, tile: tile))
                .appKitContextMenu(edge: edge) { widgetMenu(host, edge: edge) }
        } else if let folder = stackByID[id] {
            StackTileView(
                stack: folder,
                size: tile,
                isExpanded: stacks.expandedID == folder.id,
                isDropTarget: dropTargetID == folder.hoverID,
                onToggle: { interactions.onStackTapped?(folder.id) },
                onOpen: { stacks.openFolder(folder.id) },
                onRemove: { dockModel.removeStack(id: folder.id) },
                contents: stacks.contents,
                dockModel: dockModel
            )
            .opacity(dragging == folder.hoverID ? 0 : 1)
            .gesture(stackDragGesture(for: folder, tile: tile, vertical: edge.isVertical))
        } else if id == DockModel.trashID {
            TrashTileView(
                trash: trash,
                size: tile,
                isDropTarget: dropTargetID == TrashController.hoverID || dragOverTrash
            )
            .opacity(dragging == DockModel.trashID ? 0 : 1)
            .gesture(trashDragGesture(tile: tile, vertical: edge.isVertical))
        }
    }

    /// The size a widget shows at here: always Small on a side dock, the
    /// user's pick on the bottom.
    private func shownSize(_ host: WidgetHost, edge: DockEdge) -> WidgetSize {
        dockModel.widgetSize(for: host.id, natural: host.size, edge: edge)
    }

    /// Widget right-click, laid out like the iOS widget menu: actions, then
    /// the size row (bottom dock only; side docks are always Small).
    private func widgetMenu(_ host: WidgetHost, edge: DockEdge) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let remove = ClosureMenuItem("Remove Widget") {
            withAnimation(removalAnimation) { dockModel.setWidget(host.id, enabled: false) }
        }
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
        menu.addItem(remove)
        let edit = ClosureMenuItem("Edit Widgets...") { interactions.onOpenSettings?() }
        edit.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        menu.addItem(edit)
        let sizes = WidgetSize.choices(upTo: host.size)
        if !edge.isVertical, sizes.count > 1 {
            menu.addItem(.separator())
            let item = NSMenuItem()
            let picker = WidgetSizePicker(sizes: sizes, selection: shownSize(host, edge: edge)) { [weak menu] size in
                menu?.cancelTracking()
                withAnimation(.easeOut(duration: 0.15)) { dockModel.setWidgetSize(host.id, size) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            let view = NSHostingView(rootView: picker)
            view.frame.size = view.fittingSize
            item.view = view
            menu.addItem(item)
        }
        return menu
    }

    /// Pinned entry with reorder; spacers also shift under magnification.
    @ViewBuilder private func pinnedSlot(_ entry: DockEntry, tile: CGFloat, vertical: Bool) -> some View {
        let body = entryView(entry, tile: tile)
            // Gap while dragging: the floating DragOut preview follows the
            // cursor; the strip slot stays empty so neighbors shift.
            .opacity(dragging == entry.id ? 0 : 1)
            .gesture(reorderGesture(for: entry, tile: tile, vertical: vertical))
        if entry.spacer != nil {
            body.magnifiedShift()
        } else {
            body
        }
    }

    /// A running app that is not pinned, or a recent app.
    private func unpinnedTile(_ app: PinnedApp, running: NSRunningApplication?, tile: CGFloat) -> some View {
        DockItemView(app: app, running: running, isPinned: false, size: tile, dockModel: dockModel, bouncer: bouncer,
                     badges: badges, isDropTarget: dropTargetID == app.id, isHidden: runningApps.isHidden(running))
            .opacity(dragging == app.id ? 0 : 1)
            .gesture(unpinnedGroupDropGesture(for: app, tile: tile))
    }

    @ViewBuilder private func entryView(_ entry: DockEntry, tile: CGFloat) -> some View {
        switch entry {
        case .app(let app):
            let running = runningApps.runningInstance(of: app)
            DockItemView(app: app, running: running, isPinned: true, size: tile, dockModel: dockModel, bouncer: bouncer,
                         badges: badges, isDropTarget: dropTargetID == app.id, isHidden: runningApps.isHidden(running))
        case .group(let group):
            GroupTileView(
                group: group,
                size: tile,
                isExpanded: groups.expandedID == group.id,
                anyRunning: group.apps.contains { runningApps.isRunning($0) },
                onToggle: { interactions.onGroupTapped?(group.id) },
                onRename: { interactions.onRenameGroup?(group.id) },
                onRemove: { removeGroupAfterConfirming(group, fromDrag: false) },
                dockModel: dockModel,
                badges: badges
            )
        case .spacer(let spacer):
            SpacerTileView(spacer: spacer, tile: tile) {
                dockModel.removeSpacer(id: spacer.id)
            }
        }
    }

    // MARK: - Separator (drag to resize)

    /// A thin line between sections. Nearly invisible like the native Dock;
    /// spacing around it grows slightly with icon gap, and the hit
    /// area stays wide so resize and the menu always work.
    private func separator(tile: CGFloat, maxTile: CGFloat, edge: DockEdge, id: String?) -> some View {
        let vertical = edge.isVertical
        let hitExtra = max(0, (Self.separatorHitAlong - 1) / 2)
        return Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: vertical ? tile * 0.8 : 1, height: vertical ? 1 : tile * 0.8)
            .padding(edge.farSide, tile * 0.1)
            .padding(vertical ? .vertical : .horizontal, separatorPad)
            // Invisible hit slop only; negative padding restores layout size.
            .padding(vertical ? .vertical : .horizontal, hitExtra)
            .contentShape(Rectangle())
            .padding(vertical ? .vertical : .horizontal, -hitExtra)
            .modifier(ResizePointer(edge: edge, isResizing: resizeStart != nil))
            .gesture(resizeGesture(maxTile: maxTile, tile: tile, edge: edge))
            .appKitContextMenu(edge: edge) { dividerMenu(separatorID: id) }
            .accessibilityLabel("Dock separator")
    }

    /// Empty tile-sized gap that opens where a Finder pin drop would land
    /// (apps among entries, folders among stacks).
    private func insertionGap(tile: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: tile * 0.22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(
                RoundedRectangle(cornerRadius: tile * 0.22, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .frame(width: tile, height: tile)
            .accessibilityHidden(true)
            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: dockModel.edge.growthAnchor)))
    }

    /// Divider right-click, in the native Dock's order.
    private func dividerMenu(separatorID: String?) -> NSMenu {
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
        let spacers = NSMenuItem(title: "Add Spacer", action: nil, keyEquivalent: "")
        let spacerMenu = NSMenu()
        spacerMenu.autoenablesItems = false
        for size in DockSpacer.Size.allCases {
            spacerMenu.addItem(ClosureMenuItem(size.title) { dockModel.addSpacer(size) })
        }
        spacers.submenu = spacerMenu
        menu.addItem(spacers)
        menu.addItem(ClosureMenuItem("Add Separator") { withAnimation(.easeOut(duration: 0.15)) { dockModel.addSeparator() } })
        if let separatorID {
            let vertical = dockModel.edge.isVertical
            menu.addItem(ClosureMenuItem(vertical ? "Move Separator Up" : "Move Separator Left") {
                moveSeparator(separatorID, by: -1)
            })
            menu.addItem(ClosureMenuItem(vertical ? "Move Separator Down" : "Move Separator Right") {
                moveSeparator(separatorID, by: 1)
            })
            menu.addItem(ClosureMenuItem("Remove Separator") {
                withAnimation(.easeOut(duration: 0.15)) { dockModel.removeSeparator(id: separatorID) }
            })
        }
        menu.addItem(ClosureMenuItem("Reset Layout") { withAnimation(.easeOut(duration: 0.15)) { dockModel.resetLayout() } })
        menu.addItem(ClosureMenuItem("Dock Settings...") { interactions.onOpenSettings?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Portside") { NSApp.terminate(nil) })
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
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockHover.space))
            .onChanged { value in
                if dragToken == nil {
                    let start = dockModel.layoutIndex(of: entry.id) ?? 0
                    dragging = entry.id
                    dragStartIndex = start
                    dragOutside = false
                    stripLogger.info("reorder started: \(entry.id, privacy: .public)")
                    dragToken = dragOut.begin(itemID: entry.id, source: .strip, label: "Remove",
                                              preview: preview(for: entry, tile: tile), size: tile) {
                        returnToStart(entry.id)
                        dragging = nil
                        dragOutside = false
                        interactions.onDragOverGroupTile?(nil)
                        groups.clearMemberInsert()
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                let outside = dragOut.update(token)
                if outside != dragOutside { dragOutside = outside }
                let overTrash = isPointOverTrash(value.location)
                if overTrash != dragOverTrash { dragOverTrash = overTrash }

                // App tiles can be dropped into a group (tile or open grid).
                let dropGroup = stripDropGroup(at: value.location, entry: entry)
                if case .app = entry {
                    interactions.onDragOverGroupTile?(dropGroup.tileID)
                    if dropGroup.overGrid {
                        groups.updateMemberInsert(atScreen: NSEvent.mouseLocation, hidingAppID: nil)
                    } else if dropGroup.tileID == nil {
                        groups.clearMemberInsert()
                    }
                }

                if outside || overTrash || dropGroup.targetsGroup {
                    // Outside, Trash, or aiming at a group: hold the start slot.
                    returnToStart(entry.id)
                } else {
                    followCursor(entry.id, at: value.location, vertical: vertical)
                }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                let canceled = dragOut.isCanceled(token)
                let overTrash = dragOverTrash
                dragOverTrash = false
                interactions.onDragOverGroupTile?(nil)

                // Drop on Trash always asks; never remove or trash silently.
                if overTrash {
                    groups.clearMemberInsert()
                    _ = dragOut.end(token, deferResolution: false)
                    dragging = nil
                    dragOutside = false
                    switch entry {
                    case .app(let app):
                        DispatchQueue.main.async { finishTrashDrop(.app(app)) }
                    case .group(let group):
                        DispatchQueue.main.async { finishTrashDrop(.group(group)) }
                    case .spacer(let spacer):
                        // Spacers just disappear; nothing on disk to trash.
                        withAnimation(removalAnimation) { dockModel.removeSpacer(id: spacer.id) }
                    }
                    return
                }

                // App dropped on a group tile or into an open group grid.
                if case .app(let app) = entry, groups.finishStripAppDrop(app) {
                    _ = dragOut.end(token, deferResolution: false)
                    dragging = nil
                    dragOutside = false
                    // addToGroup already removed it from the strip and saved.
                    withAnimation(.easeOut(duration: 0.12)) {
                        // Snap any live-reorder ghost slot closed.
                        dockModel.saveOrder()
                    }
                    stripLogger.info("added to group by dragging: \(app.displayName, privacy: .public)")
                    return
                }
                groups.clearMemberInsert()

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
                        case .spacer(let spacer): dockModel.removeSpacer(id: spacer.id)
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

    /// Whether a strip drag is over a group tile and/or the open group grid.
    private func stripDropGroup(at point: CGPoint, entry: DockEntry) -> (tileID: String?, overGrid: Bool, targetsGroup: Bool) {
        guard case .app = entry else { return (nil, false, false) }
        return stripDropGroup(at: point)
    }

    private func stripDropGroup(at point: CGPoint) -> (tileID: String?, overGrid: Bool, targetsGroup: Bool) {
        let tileID = tileFrames.first {
            $0.id.hasPrefix("group:") && $0.frame.contains(point)
        }.map { String($0.id.dropFirst("group:".count)) }
        let overGrid = groups.containsScreenPoint(NSEvent.mouseLocation)
        return (tileID, overGrid, tileID != nil || overGrid)
    }

    /// Unpinned running apps: drag onto a group (or into its open grid) to
    /// add them. Dragging elsewhere does nothing (they are not on the dock).
    private func unpinnedGroupDropGesture(for app: PinnedApp, tile: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockHover.space))
            .onChanged { value in
                if dragToken == nil {
                    dragging = app.id
                    dragToken = dragOut.begin(
                        itemID: app.id, source: .strip, label: "Add to Group",
                        preview: preview(for: .app(app), tile: tile), size: tile
                    ) {
                        dragging = nil
                        interactions.onDragOverGroupTile?(nil)
                        groups.clearMemberInsert()
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                _ = dragOut.update(token)
                let dropGroup = stripDropGroup(at: value.location)
                interactions.onDragOverGroupTile?(dropGroup.tileID)
                if dropGroup.overGrid {
                    groups.updateMemberInsert(atScreen: NSEvent.mouseLocation, hidingAppID: nil)
                } else if dropGroup.tileID == nil {
                    groups.clearMemberInsert()
                }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                interactions.onDragOverGroupTile?(nil)
                dragging = nil
                if groups.finishStripAppDrop(app) {
                    _ = dragOut.end(token, deferResolution: false)
                    stripLogger.info("unpinned app added to group: \(app.displayName, privacy: .public)")
                    return
                }
                groups.clearMemberInsert()
                _ = dragOut.end(token, deferResolution: false)
            }
    }

    /// Widgets do not reorder in the strip, but one dragged clearly out and
    /// released is turned off, like "Remove Widget" in its menu.
    private func widgetDragGesture(for host: WidgetHost, tile: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockHover.space))
            .onChanged { value in
                let layoutID = "widget:" + host.id
                if dragToken == nil {
                    dragging = host.id
                    dragStartIndex = dockModel.layoutIndex(of: layoutID) ?? 0
                    dragOutside = false
                    let preview = host.view
                        .environment(\.widgetSize, shownSize(host, edge: dockModel.edge))
                        .environment(\.dockTileSize, tile)
                        .environment(\.dockIconGap, spacing)
                        .environment(\.dockEdge, .bottom)
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    dragToken = dragOut.begin(itemID: host.id, source: .strip, label: "Remove",
                                              preview: AnyView(preview), size: tile + 8) {
                        returnToStart(layoutID)
                        dragging = nil
                        dragOutside = false
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                let outside = dragOut.update(token)
                if outside != dragOutside { dragOutside = outside }
                let overTrash = isScreenPointOverTrash(NSEvent.mouseLocation)
                if overTrash != dragOverTrash { dragOverTrash = overTrash }
                if outside || overTrash {
                    returnToStart(layoutID)
                } else {
                    followCursor(layoutID, at: value.location, vertical: dockModel.edge.isVertical)
                }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                let overTrash = dragOverTrash
                dragOverTrash = false
                dragging = nil
                dragOutside = false
                if overTrash {
                    _ = dragOut.end(token)
                    DispatchQueue.main.async {
                        finishTrashDrop(.widget(id: host.id, title: host.widget.name))
                    }
                    return
                }
                guard dragOut.end(token) else {
                    dockModel.saveOrder()
                    return
                }
                withAnimation(removalAnimation) {
                    dockModel.setWidget(host.id, enabled: false)
                }
                stripLogger.info("widget removed by dragging out: \(host.id, privacy: .public)")
            }
    }

    /// Trash moves anywhere on the dock. It can't be dragged out or removed
    /// here (Settings > Show Trash does that); outside the dock it just goes
    /// back.
    private func trashDragGesture(tile: CGFloat, vertical: Bool) -> some Gesture {
        let id = DockModel.trashID
        return DragGesture(minimumDistance: 4, coordinateSpace: .named(DockHover.space))
            .onChanged { value in
                if dragToken == nil {
                    dragging = id
                    dragStartIndex = dockModel.layoutIndex(of: id) ?? 0
                    dragOutside = false
                    let preview = Image(nsImage: trash.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: tile * IconMetrics.fullBleedScale, height: tile * IconMetrics.fullBleedScale)
                    dragToken = dragOut.begin(itemID: id, source: .strip, label: "", preview: AnyView(preview), size: tile,
                                              removable: false) {
                        returnToStart(id)
                        dragging = nil
                        dragOutside = false
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                _ = dragOut.update(token)
                followCursor(id, at: value.location, vertical: vertical)
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                dragging = nil
                dragOutside = false
                _ = dragOut.end(token, deferResolution: false)
                dockModel.saveOrder()
            }
    }

    /// Reorder folder stacks among themselves, or drag out to remove.
    private func stackDragGesture(for stack: FolderStack, tile: CGFloat, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockHover.space))
            .onChanged { value in
                if dragToken == nil {
                    let start = dockModel.layoutIndex(of: stack.hoverID) ?? 0
                    dragging = stack.hoverID
                    dragStartIndex = start
                    dragOutside = false
                    let preview = StackTileView(
                        stack: stack, size: tile, isExpanded: false,
                        onToggle: {}, onOpen: {}, onRemove: {}, contents: stacks.contents
                    )
                    .environment(\.dockEdge, .bottom)
                    dragToken = dragOut.begin(itemID: stack.hoverID, source: .strip, label: "Remove",
                                              preview: AnyView(preview), size: tile) {
                        returnToStart(stack.hoverID)
                        dragging = nil
                        dragOutside = false
                    }
                }
                guard let token = dragToken, !dragOut.isCanceled(token) else { return }
                let outside = dragOut.update(token)
                if outside != dragOutside { dragOutside = outside }
                let overTrash = isPointOverTrash(value.location)
                if overTrash != dragOverTrash { dragOverTrash = overTrash }
                if outside || overTrash {
                    returnToStart(stack.hoverID)
                    return
                }
                followCursor(stack.hoverID, at: value.location, vertical: vertical)
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                let overTrash = dragOverTrash
                dragOverTrash = false
                dragging = nil
                dragOutside = false
                if overTrash {
                    _ = dragOut.end(token)
                    DispatchQueue.main.async { finishTrashDrop(.stack(stack)) }
                    return
                }
                let remove = dragOut.end(token)
                if remove {
                    withAnimation(removalAnimation) {
                        dockModel.removeStack(id: stack.id)
                    }
                    stripLogger.info("stack removed by dragging out: \(stack.displayName, privacy: .public)")
                } else {
                    dockModel.saveOrder()
                }
            }
    }

    /// The item whose slot a dragged item should take: it steps past a
    /// neighbor only once the cursor crosses that neighbor's midpoint, using
    /// the slots' real frames (`DockHover.space`, the same space as the drag
    /// location). Spacers, separators, widgets and tiles of different widths
    /// all count correctly, a cursor in a gap or off the strip's cross axis
    /// changes nothing, and a neighbor still sliding aside can never pull
    /// the item back.
    private func steppedTarget(dragged: String, position: CGFloat, vertical: Bool) -> String {
        let ids = dockModel.resolvedLayout().filter { layoutFrames[$0] != nil }
        guard let from = ids.firstIndex(of: dragged) else { return dragged }
        func mid(_ id: String) -> CGFloat? {
            layoutFrames[id].map { vertical ? $0.midY : $0.midX }
        }
        var slot = from
        while slot > 0, let m = mid(ids[slot - 1]), position < m { slot -= 1 }
        while slot < ids.count - 1, let m = mid(ids[slot + 1]), position > m { slot += 1 }
        return ids[slot]
    }

    /// Moves a dragged item with the cursor (saved on release).
    private func followCursor(_ id: String, at location: CGPoint, vertical: Bool) {
        let target = steppedTarget(dragged: id, position: vertical ? location.y : location.x, vertical: vertical)
        withAnimation(.easeOut(duration: 0.12)) {
            _ = dockModel.moveLayoutItem(id, toSlotOf: target, persist: false)
        }
    }

    /// Back to where the drag began.
    private func returnToStart(_ id: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            _ = dockModel.moveLayoutItem(id, toIndex: dragStartIndex, persist: false)
        }
    }

    /// Separator menu: step past the next visible neighbor.
    private func moveSeparator(_ id: String, by step: Int) {
        let visible = dockModel.resolvedLayout().filter { layoutFrames[$0] != nil }
        guard let i = visible.firstIndex(of: id), visible.indices.contains(i + step) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            _ = dockModel.moveLayoutItem(id, toSlotOf: visible[i + step])
        }
    }

    private func isPointOverTrash(_ point: CGPoint) -> Bool {
        tileFrames.contains {
            $0.id == TrashController.hoverID && $0.frame.contains(point)
        }
    }

    /// Widget drag tracks the cursor in screen space via DragOut.
    private func isScreenPointOverTrash(_ screen: NSPoint) -> Bool {
        hover.screenFrame(forTargetID: TrashController.hoverID)?.contains(screen) ?? false
    }

    private func finishTrashDrop(_ target: DockTrashDropTarget) {
        let choice = interactions.confirmTrashDrop?(target) ?? DockTrashDrop.confirm(target)
        switch choice {
        case .cancel:
            stripLogger.info("trash drop canceled: \(target.displayName, privacy: .public)")
        case .removeFromDock:
            withAnimation(removalAnimation) { applyRemoveFromDock(target) }
            stripLogger.info("trash drop removed from dock: \(target.displayName, privacy: .public)")
        case .moveToTrash:
            if let error = applyMoveToTrash(target) {
                trash.reportNotice(error)
                stripLogger.error("trash drop move failed: \(error, privacy: .public)")
                return
            }
            withAnimation(removalAnimation) { applyRemoveFromDock(target) }
            stripLogger.info("trash drop moved to Trash: \(target.displayName, privacy: .public)")
        }
    }

    private func applyRemoveFromDock(_ target: DockTrashDropTarget) {
        switch target {
        case .app(let app): dockModel.unpin(app)
        case .group(let group): dockModel.removeGroup(groupID: group.id)
        case .stack(let stack): dockModel.removeStack(id: stack.id)
        case .widget(let id, _): dockModel.setWidget(id, enabled: false)
        }
    }

    private func applyMoveToTrash(_ target: DockTrashDropTarget) -> String? {
        switch target {
        case .app(let app):
            return DockTrashDrop.moveToTrash(app.url)
        case .stack(let stack):
            return DockTrashDrop.moveToTrash(stack.url)
        case .group, .widget:
            return nil
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
                                         onToggle: {}, onRename: {}, onRemove: {}, dockModel: dockModel, badges: badges)
                .environment(\.dockEdge, .left)
                .frame(height: tile))
        case .spacer(let spacer):
            return AnyView(SpacerTileView(spacer: spacer, tile: tile, onRemove: {}))
        }
    }
}

/// Invisible gap between pinned apps. Hover / right-click to grab or remove.
private struct SpacerTileView: View {
    let spacer: DockSpacer
    let tile: CGFloat
    let onRemove: () -> Void
    @State private var hovered = false
    @Environment(\.dockEdge) private var edge

    private var length: CGFloat { max(8, tile * spacer.size.widthFactor) }

    var body: some View {
        RoundedRectangle(cornerRadius: tile * 0.22, style: .continuous)
            .fill(Color.primary.opacity(hovered ? 0.2 : 0))
            .frame(
                width: edge.isVertical ? tile : length,
                height: edge.isVertical ? length : tile
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .dockHoverTarget(id: "spacer:" + spacer.id, title: spacer.size.title)
            .appKitContextMenu(edge: edge) {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(ClosureMenuItem("Remove Spacer", onRemove))
                return menu
            }
            .accessibilityLabel(spacer.size.title)
            .accessibilityAddTraits(.isButton)
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

/// File drops on the strip (see `FileDropSession` for the rules).
private struct FileDropDelegate: DropDelegate {
    let dockModel: DockModel
    let interactions: DockInteractions
    let session: FileDropSession
    @Binding var targetID: String?
    @Binding var stackInsertIndex: Int?
    @Binding var entryInsertIndex: Int?
    let tileFrames: [HoverTarget]
    let apps: [String: (app: PinnedApp, isPinned: Bool)]
    /// Nil while the Trash tile is hidden.
    let trash: TrashController?
    let stackController: StackController
    let runningApps: RunningApps
    let bouncer: LaunchBouncer
    let appSpringLoad: AppSpringLoad
    let tile: CGFloat
    let spacing: CGFloat
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
        setStackInsert(nil)
        setEntryInsert(nil)
        appSpringLoad.cancel()
        session.end()
        interactions.onDragOverGroupTile?(nil)
        interactions.onDragOverStackTile?(nil)
        interactions.onDragOverStrip?(false, "exited")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Trash wins when the cursor is on it (folders can be trashed too).
        if let trash, isOverTrash(info) {
            interactions.onDragOverGroupTile?(nil)
            interactions.onDragOverStackTile?(nil)
            appSpringLoad.cancel()
            setStackInsert(nil)
            setEntryInsert(nil)
            let ok = session.canTrash(using: trash)
            setTarget(ok ? TrashController.hoverID : nil)
            return DropProposal(operation: ok ? .move : .forbidden)
        }
        switch session.mode {
        case .pinApps:
            setStackInsert(nil)
            appSpringLoad.cancel()
            // Folder stack or app group under the cursor: open immediately
            // and deposit/add instead of showing a pin gap beside it.
            if let stackID = stackUnderCursor(info), session.canDeposit() {
                setEntryInsert(nil)
                setTarget("stack:" + stackID)
                interactions.onDragOverGroupTile?(nil)
                interactions.onDragOverStackTile?(stackID)
                return DropProposal(operation: .copy)
            }
            if let groupID = groupUnderCursor(info) {
                setEntryInsert(nil)
                setTarget("group:" + groupID)
                interactions.onDragOverStackTile?(nil)
                interactions.onDragOverGroupTile?(groupID)
                return DropProposal(operation: .copy)
            }
            setTarget(nil)
            interactions.onDragOverStackTile?(nil)
            interactions.onDragOverGroupTile?(nil)
            setEntryInsert(appInsertIndex(info))
            return DropProposal(operation: .copy)
        case .pinFolders:
            setTarget(nil)
            setEntryInsert(nil)
            appSpringLoad.cancel()
            interactions.onDragOverGroupTile?(nil)
            interactions.onDragOverStackTile?(nil)
            setStackInsert(folderInsertIndex(info))
            return DropProposal(operation: .copy)
        case .open:
            setStackInsert(nil)
            setEntryInsert(nil)
            let id = updateOpenTarget(info)
            updateAppSpringLoad(id)
            return DropProposal(operation: id == nil ? .forbidden : .copy)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        interactions.onDragOverStrip?(false, "dropped")
        let stackAt = stackInsertIndex
        let entryAt = entryInsertIndex
        let depositStackID = stackUnderCursor(info)
        let dropGroupID = groupUnderCursor(info)
        appSpringLoad.cancel()
        // Clear the insertion gap without animation, then pin in the same
        // turn so the real tile replaces the gap (no scale-out jitter).
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            targetID = nil
            stackInsertIndex = nil
            entryInsertIndex = nil
        }
        defer {
            session.end()
            interactions.onDragOverGroupTile?(nil)
            interactions.onDragOverStackTile?(nil)
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
        case .pinApps:
            if let stackID = depositStackID, session.canDeposit() {
                stackController.deposit(session.urls, into: stackID)
                return true
            }
            if let groupID = dropGroupID {
                return addAppsToGroup(groupID)
            }
            var pinTx = Transaction()
            pinTx.disablesAnimations = true
            return withTransaction(pinTx) {
                pinApps(at: entryAt ?? dockModel.entries.count)
            }
        case .pinFolders:
            var pinTx = Transaction()
            pinTx.disablesAnimations = true
            return withTransaction(pinTx) {
                pinFolders(at: stackAt ?? dockModel.stacks.count)
            }
        case .open:
            if let stackID = depositStackID, session.canDeposit() {
                stackController.deposit(session.urls, into: stackID)
                return true
            }
            guard let id = updateOpenTarget(info), let entry = apps[id] else {
                stripLogger.info("file drop rejected: no app or stack here can take it")
                return false
            }
            open(session.urls, with: entry.app, isPinned: entry.isPinned)
            return true
        }
    }

    private func isOverTrash(_ info: DropInfo) -> Bool {
        let slop = -spacing / 2
        return tileFrames.contains {
            $0.id == TrashController.hoverID
                && $0.frame.insetBy(dx: vertical ? 0 : slop, dy: vertical ? slop : 0).contains(info.location)
        }
    }

    private func stackUnderCursor(_ info: DropInfo) -> String? {
        guard let id = tileUnderCursor(info), id.hasPrefix("stack:") else { return nil }
        return String(id.dropFirst("stack:".count))
    }

    private func groupUnderCursor(_ info: DropInfo) -> String? {
        guard let id = tileUnderCursor(info), id.hasPrefix("group:") else { return nil }
        return String(id.dropFirst("group:".count))
    }

    private func tileUnderCursor(_ info: DropInfo) -> String? {
        let slop = -spacing / 2
        return tileFrames.first {
            $0.frame.insetBy(dx: vertical ? 0 : slop, dy: vertical ? slop : 0).contains(info.location)
        }?.id
    }

    private func addAppsToGroup(_ groupID: String) -> Bool {
        var added = 0
        for url in session.urls {
            guard let app = PinnedApp(appURL: url) else { continue }
            dockModel.addToGroup(app, groupID: groupID)
            added += 1
            stripLogger.info("added to group from Finder drop: \(app.displayName, privacy: .public)")
        }
        return added > 0
    }

    @discardableResult
    private func updateOpenTarget(_ info: DropInfo) -> String? {
        let slop = -spacing / 2
        let hit = tileFrames.first {
            $0.frame.insetBy(dx: vertical ? 0 : slop, dy: vertical ? slop : 0).contains(info.location)
        }
        interactions.onDragOverGroupTile?(hit.flatMap {
            $0.id.hasPrefix("group:") ? String($0.id.dropFirst("group:".count)) : nil
        })
        let stackID = hit.flatMap {
            $0.id.hasPrefix("stack:") ? String($0.id.dropFirst("stack:".count)) : nil
        }
        interactions.onDragOverStackTile?(stackID)
        if let stackID, session.canDeposit() {
            setTarget("stack:" + stackID)
            return "stack:" + stackID
        }
        let id = hit.flatMap { hit in apps[hit.id].flatMap { session.canOpen(with: $0.app) ? hit.id : nil } }
        setTarget(id)
        return id
    }

    private func setTarget(_ id: String?) {
        guard targetID != id else { return }
        targetID = id
        stripLogger.info("drop target: \(id ?? "none", privacy: .public)")
    }

    private func updateAppSpringLoad(_ targetID: String?) {
        guard let targetID, let entry = apps[targetID] else {
            appSpringLoad.cancel()
            return
        }
        appSpringLoad.update(app: entry.app, running: runningApps.runningInstance(of: entry.app))
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

    private func pinApps(at index: Int) -> Bool {
        var at = index
        var pinned = 0
        for url in session.urls {
            guard let app = PinnedApp(appURL: url) else { continue }
            dockModel.pin(app, at: at)
            pinned += 1
            at += 1
            stripLogger.info("pinned from Finder drop: \(app.displayName, privacy: .public) at \(at - 1)")
        }
        return pinned > 0
    }

    private func pinFolders(at index: Int) -> Bool {
        var pinned = 0
        var at = index
        for url in session.urls {
            if dockModel.addStack(folderURL: url, at: at) != nil {
                pinned += 1
                at += 1
                stripLogger.info("pinned folder stack: \(url.lastPathComponent, privacy: .public) at \(at - 1)")
            }
        }
        return pinned > 0
    }

    /// Slot in the stacks list under the cursor (0...count), using stack tile
    /// midpoints so the gap jumps like the native Dock. Falls back to append
    /// when there are no stack tiles yet.
    private func folderInsertIndex(_ info: DropInfo) -> Int {
        insertIndex(info, among: tileFrames.filter { $0.id.hasPrefix("stack:") })
    }

    /// Slot in the pinned entries list (0...count) under the cursor.
    private func appInsertIndex(_ info: DropInfo) -> Int {
        let ids = Set(dockModel.entries.map(\.id))
        return insertIndex(info, among: tileFrames.filter { ids.contains($0.id) })
    }

    private func insertIndex(_ info: DropInfo, among hits: [HoverTarget]) -> Int {
        let position = vertical ? info.location.y : info.location.x
        let ordered = hits.sorted {
            vertical ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        if ordered.isEmpty { return 0 }
        for (i, hit) in ordered.enumerated() {
            let mid = vertical ? hit.frame.midY : hit.frame.midX
            if position < mid { return i }
        }
        return ordered.count
    }

    private func setStackInsert(_ index: Int?) {
        guard stackInsertIndex != index else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            stackInsertIndex = index
        }
    }

    private func setEntryInsert(_ index: Int?) {
        guard entryInsertIndex != index else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            entryInsertIndex = index
        }
    }
}

/// Each layout slot's frame, by layout id.
private struct LayoutFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func layoutSlot(_ id: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(
                key: LayoutFramesKey.self,
                value: [id: geo.frame(in: .named(DockHover.space))]
            )
        })
    }
}
