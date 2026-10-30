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
    /// widgets, edge). The panel sizes its window from this.
    var onContentSizeChanged: ((CGSize) -> Void)?
    /// A group tile was clicked (expand or collapse it).
    var onGroupTapped: ((String) -> Void)?
    /// "Rename" from a group tile's context menu.
    var onRenameGroup: ((String) -> Void)?
    /// "Settings..." from the separator's context menu.
    var onOpenSettings: (() -> Void)?
    /// A file drag entered the strip (true) or left it, dropped or not
    /// (false, with a reason for the log).
    var onDragOverStrip: ((Bool, String) -> Void)?
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
/// active app, and .onDrag has no "ended" callback anyway.
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

    /// Id of the pinned entry (app or group) being dragged, if any.
    @State private var dragging: String?
    /// Cursor (screen coordinates) and tile size when a separator drag began.
    @State private var resizeStart: (mouse: CGPoint, tile: CGFloat)?

    private let spacing = DockMetrics.spacing
    private let alongPadding: CGFloat = 8
    private let separatorPadding: CGFloat = 4
    private var separatorLength: CGFloat { 1 + separatorPadding * 2 }
    private static let space = "strip"

    /// Largest tile that still fits everything on screen, ignoring `iconSize`.
    private func maxTileSize(extrasCount: Int, edge: DockEdge) -> CGFloat {
        let apps = dockModel.entries.count + extrasCount
        let separators = (extrasCount > 0 ? 1 : 0) + (widgets.hosts.isEmpty ? 0 : 1)
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
        let maxTile = maxTileSize(extrasCount: extras.count + (showsSelf ? 1 : 0), edge: edge)
        let tile = min(dockModel.iconSize, maxTile)
        // Items align to the far side so icons line up with widgets.
        let stack = edge.isVertical
            ? AnyLayout(VStackLayout(alignment: edge == .left ? .trailing : .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))

        stack {
            ForEach(dockModel.entries) { entry in
                entryView(entry, tile: tile)
                    .opacity(dragging == entry.id ? 0.5 : 1)
                    .scaleEffect(dragging == entry.id ? 1.08 : 1, anchor: edge.growthAnchor)
                    .gesture(reorderGesture(for: entry, tile: tile, vertical: edge.isVertical))
            }

            if !extras.isEmpty || showsSelf {
                separator(tile: tile, maxTile: maxTile, edge: edge)
                ForEach(extras, id: \.0.id) { app, running in
                    DockItemView(app: app, running: running, isPinned: false, size: tile, dockModel: dockModel, bouncer: bouncer)
                }
                if showsSelf {
                    PortsideTileView(size: tile) { interactions.onOpenSettings?() }
                }
            }

            if !widgets.hosts.isEmpty {
                separator(tile: tile, maxTile: maxTile, edge: edge)
                ForEach(widgets.hosts) { host in
                    host.view
                        .contextMenu {
                            Button("Remove Widget") { dockModel.setWidget(host.id, enabled: false) }
                        }
                }
            }
        }
        .environment(\.dockTileSize, tile)
        .environment(\.dockEdge, edge)
        .coordinateSpace(name: DockStrip.space)
        .padding(edge.isVertical ? .vertical : .horizontal, alongPadding)
        .padding(edge.farSide, 6)
        .padding(edge.nearSide, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .onDrop(of: [.fileURL], delegate: AppFileDropDelegate(dockModel: dockModel, interactions: interactions, slotLength: tile + spacing, leadingInset: alongPadding, vertical: edge.isVertical))
        .onChange(of: maxTile, initial: true) { _, fit in layout.reportFitTileSize(fit) }
        .onChange(of: tile) { _, size in bouncer.tileSizeChanged(size) }
        .fixedSize()
        // NSHostingView does not report intrinsic size changes to AppKit
        // here, so the strip reports its own size.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            interactions.onContentSizeChanged?(size)
        }
        // Root space = the hosting view's bounds, so DockPanel can convert
        // hover target frames to screen coordinates.
        .coordinateSpace(name: DockHover.space)
        .onPreferenceChange(HoverTargetsKey.self) { targets in
            hover.updateTargets(targets)
        }
    }

    @ViewBuilder private func entryView(_ entry: DockEntry, tile: CGFloat) -> some View {
        switch entry {
        case .app(let app):
            DockItemView(app: app, running: runningApps.runningInstance(of: app), isPinned: true, size: tile, dockModel: dockModel, bouncer: bouncer)
        case .group(let group):
            GroupTileView(
                group: group,
                size: tile,
                isExpanded: groups.expandedID == group.id,
                anyRunning: group.apps.contains { runningApps.isRunning($0) },
                onToggle: { interactions.onGroupTapped?(group.id) },
                onRename: { interactions.onRenameGroup?(group.id) },
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
            .contextMenu {
                Button(dockModel.autoHide ? "Turn Hiding Off" : "Turn Hiding On") {
                    dockModel.setAutoHide(!dockModel.autoHide)
                }
                Divider()
                Button("Settings...") { interactions.onOpenSettings?() }
            }
            .accessibilityLabel("Dock separator")
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

    // MARK: - Reorder

    /// Live reorder: the dragged tile jumps to whichever slot the cursor is
    /// over. Order is saved once, on release.
    private func reorderGesture(for entry: DockEntry, tile: CGFloat, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockStrip.space))
            .onChanged { value in
                if dragging == nil {
                    dragging = entry.id
                    stripLogger.info("reorder started: \(entry.id, privacy: .public)")
                }
                let position = vertical ? value.location.y : value.location.x
                let slot = Int((position / (tile + spacing)).rounded(.down))
                withAnimation(.easeOut(duration: 0.12)) {
                    dockModel.move(entryID: entry.id, toIndex: slot, persist: false)
                }
            }
            .onEnded { _ in
                dragging = nil
                dockModel.saveOrder()
                let index = dockModel.entries.firstIndex { $0.id == entry.id } ?? -1
                stripLogger.info("reorder ended: \(entry.id, privacy: .public) at slot \(index)")
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

/// Adds .app bundles dragged from Finder, inserted at the slot under the cursor.
private struct AppFileDropDelegate: DropDelegate {
    let dockModel: DockModel
    let interactions: DockInteractions
    let slotLength: CGFloat
    let leadingInset: CGFloat
    let vertical: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        interactions.onDragOverStrip?(true, "entered")
    }

    func dropExited(info: DropInfo) {
        interactions.onDragOverStrip?(false, "exited")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        interactions.onDragOverStrip?(false, "dropped")
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
