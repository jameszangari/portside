import SwiftUI
import os.log

/// Present and dismiss motion for the group grid overlay (Dock-stack feel).
enum GroupPopoverMotion {
    /// How long the close plays before the overlay is removed.
    static let dismissDuration: TimeInterval = 0.14
    static let collapsedScale: CGFloat = 0.9

    static var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A quick, lightly damped spring: settles in about 250ms with a hint of
    /// overshoot, like a native stack or popover.
    static var present: Animation {
        .spring(duration: 0.26, bounce: 0.14)
    }

    /// Accelerates away, a little quicker than the open.
    static var dismiss: Animation {
        .easeIn(duration: dismissDuration)
    }
}

/// A group's tile in the strip: up to nine member icons in a mini grid,
/// with a running dot if any member is running.
struct GroupTileView: View {
    let group: FolderGroup
    let size: CGFloat
    let isExpanded: Bool
    let anyRunning: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    /// "Remove from Dock": the strip asks for confirmation first.
    let onRemove: () -> Void
    @ObservedObject var dockModel: DockModel
    @ObservedObject private var icons = IconCache.shared
    @Environment(\.dockEdge) private var edge

    var body: some View {
        tile
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.name)
            .accessibilityAddTraits(.isButton)
            .dockHoverTarget(id: DockEntry.group(group).id, title: group.name)
            .contextMenu {
                Button("Rename", action: onRename)
                Divider()
                Button("Ungroup") { dockModel.ungroup(groupID: group.id) }
                Button("Remove from Dock", action: onRemove)
            }
    }

    /// Same arrangement as an app tile so dots line up across the strip.
    @ViewBuilder private var tile: some View {
        switch edge {
        case .bottom: VStack(spacing: 2) { icon; indicator }
        case .left: HStack(spacing: 2) { indicator; icon }
        case .right: HStack(spacing: 2) { icon; indicator }
        }
    }

    private var icon: some View {
        let shown = Array(group.apps.prefix(9))
        let columns = shown.count > 4 ? 3 : 2
        let inset = size * 0.12
        let gap = size * 0.05
        let cell = (size - inset * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let grid = Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns)
        return RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color.white.opacity(isExpanded ? 0.32 : 0.18))
            .animation(GroupPopoverMotion.present, value: isExpanded)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                LazyVGrid(columns: grid, alignment: .leading, spacing: gap) {
                    ForEach(shown) { app in
                        Image(nsImage: icons.icon(for: app.url))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: cell, height: cell)
                    }
                }
                .padding(inset)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .magnifiedIcon(id: DockEntry.group(group).id)
    }

    private var indicator: some View {
        Circle()
            .fill(Color.primary.opacity(anyRunning ? 0.75 : 0))
            .frame(width: 4, height: 4)
            .magnifiedIndicator(id: DockEntry.group(group).id)
    }
}

/// The expanded group, shown in the overlay panel next to its tile: the
/// group's name and a grid of its apps with names under the icons.
/// Reads the group from the model by id so it updates live while open.
struct GroupPopoverView: View {
    let groupID: String
    let edge: DockEdge
    @ObservedObject var dockModel: DockModel
    @ObservedObject var runningApps: RunningApps
    @ObservedObject var groups: GroupController
    let onLaunch: (PinnedApp, ((NSRunningApplication?) -> Void)?) -> Void
    /// A file drop on a member that can open it.
    let onOpenDocuments: ([URL], PinnedApp) -> Void
    /// A file drag entered (true) or left (false, with a reason) the grid.
    let onDragOverGrid: (Bool, String) -> Void

    @State private var appeared = false
    /// The file drag over the grid right now (same rules as the strip).
    @State private var fileDrop = FileDropSession()
    /// Member a file drag is over that can open the dragged items.
    @State private var dropTargetID: String?
    /// Member cell frames in the grid's space, for hit-testing drops.
    @State private var cellFrames: [String: CGRect] = [:]

    static let iconSize: CGFloat = 52
    private static let cellWidth: CGFloat = 76
    /// Room around the card for its shadow, on every side except the tile's.
    static let shadowPadding: CGFloat = 18
    fileprivate static let dropSpace = "groupGrid"

    /// The parts of the overlay that are not hoverable: the shadow padding.
    /// Everything else (the card and the bridge to the tile) counts as the grid.
    static func hitInsets(for edge: DockEdge) -> NSEdgeInsets {
        let p = shadowPadding
        switch edge {
        case .bottom: return NSEdgeInsets(top: p, left: p, bottom: 0, right: p)
        case .left: return NSEdgeInsets(top: p, left: 0, bottom: p, right: p)
        case .right: return NSEdgeInsets(top: p, left: p, bottom: p, right: 0)
        }
    }

    var body: some View {
        if let group = dockModel.groups.first(where: { $0.id == groupID }) {
            content(group)
                .scaleEffect(appeared ? 1 : GroupPopoverMotion.collapsedScale, anchor: edge.growthAnchor)
                .opacity(appeared ? 1 : 0)
                // The bridge spans the gap to the tile, so the cursor never
                // crosses dead space between tile and grid. The near-clear
                // fill sits outside the animation: the whole region takes
                // the mouse from the first frame, even while fading in.
                .padding(edge.nearSide, DockHover.labelGap)
                .background(Color.black.opacity(0.01))
                // Card plus bridge take file drags; the shadow does not.
                .coordinateSpace(name: Self.dropSpace)
                .onPreferenceChange(GroupCellFramesKey.self) { cellFrames = $0 }
                .onDrop(of: [.fileURL], delegate: GroupFileDropDelegate(
                    session: fileDrop, targetID: $dropTargetID, cellFrames: cellFrames,
                    apps: Dictionary(group.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                    onOpen: onOpenDocuments, onDragOverGrid: onDragOverGrid))
                .padding(Edge.Set.all.subtracting(edge.nearSide), Self.shadowPadding)
                .onAppear { setAppeared(true, animation: GroupPopoverMotion.present) }
                .onChange(of: groups.isClosing) { _, closing in
                    setAppeared(!closing, animation: closing ? GroupPopoverMotion.dismiss : GroupPopoverMotion.present)
                }
        }
    }

    private func setAppeared(_ value: Bool, animation: Animation) {
        if GroupPopoverMotion.shouldAnimate {
            withAnimation(animation) { appeared = value }
        } else {
            appeared = value
        }
    }

    private func content(_ group: FolderGroup) -> some View {
        let columns = Self.columns(for: group.apps.count)
        let rows = stride(from: 0, to: group.apps.count, by: columns).map {
            Array(group.apps[$0..<min($0 + columns, group.apps.count)])
        }
        return VStack(spacing: 10) {
            if groups.editingID == group.id {
                GroupNameField(
                    text: $groups.draftName,
                    onCommit: { groups.endRename(commit: true) },
                    onCancel: { groups.endRename(commit: false) }
                )
            } else {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(rows[row]) { app in
                            GroupAppCell(
                                app: app,
                                groupID: group.id,
                                running: runningApps.runningInstance(of: app),
                                iconSize: Self.iconSize,
                                width: Self.cellWidth,
                                dockModel: dockModel,
                                groups: groups,
                                bouncer: groups.bouncer,
                                isDropTarget: dropTargetID == app.id,
                                onLaunch: onLaunch
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .dockBackground(dockModel.look, shadow: true)
    }

    /// Roughly square grid, at most five wide.
    static func columns(for count: Int) -> Int {
        switch count {
        case ...3: max(count, 1)
        case 4: 2
        case ...9: 3
        case ...16: 4
        default: 5
        }
    }
}

/// The grid's title while renaming. Focused as soon as it appears (the
/// overlay panel is key by then); the field selects its text on focus, so
/// typing replaces "Group N".
private struct GroupNameField: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Group name", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center)
            .frame(width: 180)
            .focused($focused)
            .onSubmit(onCommit)
            .onExitCommand(perform: onCancel)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel("Group name")
    }
}

/// One app in the expanded group: click to open, right-click for actions,
/// drag it out of the grid to take it out of the group.
private struct GroupAppCell: View {
    let app: PinnedApp
    let groupID: String
    let running: NSRunningApplication?
    let iconSize: CGFloat
    let width: CGFloat
    @ObservedObject var dockModel: DockModel
    let groups: GroupController
    @ObservedObject var bouncer: LaunchBouncer
    var isDropTarget = false
    let onLaunch: (PinnedApp, ((NSRunningApplication?) -> Void)?) -> Void
    @ObservedObject private var icons = IconCache.shared
    @State private var hovered = false
    /// Token of this cell's drag (see `DragOutController`), nil when idle.
    @State private var dragToken: Int?
    @State private var dragging = false
    @State private var hold = MenuHold()

    private var bounceKey: String { LaunchBouncer.gridKey(groupID: groupID, appID: app.id) }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: icons.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                // While launching, the bounce window draws the icon.
                .opacity(bouncer.bouncingID == bounceKey ? 0 : 1)
                // Same drop highlight as a dock tile.
                .background(
                    RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                        .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                        .padding(-3)
                )
                // Where the bounce window goes (the hosting view fills the
                // overlay, so global is overlay content space).
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    groups.cellIconFrameChanged(groupID: groupID, appID: app.id, frame: frame)
                }
                .onDisappear {
                    groups.cellIconFrameChanged(groupID: groupID, appID: app.id, frame: nil)
                }
            Circle()
                .fill(Color.primary.opacity(running == nil ? 0 : 0.75))
                .frame(width: 4, height: 4)
            Text(app.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width - 8)
        }
        .padding(.vertical, 6)
        .frame(width: width)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: GroupCellFramesKey.self,
                                   value: [app.id: proxy.frame(in: .named(GroupPopoverView.dropSpace))])
        })
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.12 : 0))
        )
        .opacity(dragging ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .menuHold(hold) {
            TileClick.perform(app, running: running, flags: NSEvent.modifierFlags) { afterOpen in onLaunch(app, afterOpen) }
        }
        .gesture(dragOutGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(.isButton)
        .appKitContextMenu(hold: hold) {
            AppTileMenu.build(.init(
                app: app, running: running, isPinned: true, dockModel: dockModel,
                leading: [("Remove from Group", { dockModel.removeFromGroup(app, groupID: groupID) })],
                offersDockItems: false))
        }
    }
}

extension GroupAppCell {
    /// Dragging a member clearly out of the grid and releasing it does what
    /// "Remove from Group" does. Released inside the grid, nothing changes
    /// (members are not reordered here).
    private var dragOutGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in
                let dragOut = groups.dragOut
                if dragToken == nil {
                    dragging = true
                    let icon = icons.icon(for: app.url)
                    dragToken = dragOut.begin(
                        itemID: app.id, source: .grid, label: "Remove from Group",
                        preview: AnyView(Image(nsImage: icon).resizable().interpolation(.high).frame(width: iconSize, height: iconSize)),
                        size: iconSize
                    ) { dragging = false }
                }
                if let dragToken { dragOut.update(dragToken) }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                dragging = false
                guard groups.dragOut.end(token) else { return }
                withAnimation(GroupPopoverMotion.shouldAnimate ? .easeOut(duration: 0.15) : nil) {
                    dockModel.removeFromGroup(app, groupID: groupID)
                }
            }
    }
}

/// Member cell frames in the grid's drop space, by app id.
private struct GroupCellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// File drops on an open group grid. Same rules as the strip's delegate
/// (`FileDropSession`): a member that can open every dragged item
/// highlights and takes the drop; anything else is rejected. `.app` drags
/// are rejected here too, as before (pinning happens on the strip).
private struct GroupFileDropDelegate: DropDelegate {
    let session: FileDropSession
    @Binding var targetID: String?
    let cellFrames: [String: CGRect]
    let apps: [String: PinnedApp]
    let onOpen: ([URL], PinnedApp) -> Void
    let onDragOverGrid: (Bool, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        session.begin()
        onDragOverGrid(true, "entered")
        updateTarget(info)
    }

    func dropExited(info: DropInfo) {
        setTarget(nil)
        session.end()
        onDragOverGrid(false, "exited")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: updateTarget(info) == nil ? .forbidden : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let id = updateTarget(info)
        let urls = session.urls
        setTarget(nil)
        session.end()
        onDragOverGrid(false, "dropped")
        guard let id, let app = apps[id] else {
            gridDropLogger.info("grid file drop rejected: no member here can open it")
            return false
        }
        gridDropLogger.info("grid file drop: opening \(urls.count) item(s) with \(app.displayName, privacy: .public)")
        onOpen(urls, app)
        return true
    }

    @discardableResult
    private func updateTarget(_ info: DropInfo) -> String? {
        guard session.mode == .open else {
            setTarget(nil)
            return nil
        }
        let hit = cellFrames.first { $0.value.contains(info.location) }?.key
        let id = hit.flatMap { id in apps[id].flatMap { session.canOpen(with: $0) ? id : nil } }
        setTarget(id)
        return id
    }

    private func setTarget(_ id: String?) {
        guard targetID != id else { return }
        targetID = id
        gridDropLogger.info("grid drop target: \(id ?? "none", privacy: .public)")
    }
}

private let gridDropLogger = Logger(subsystem: "com.james.portside", category: "Groups")
