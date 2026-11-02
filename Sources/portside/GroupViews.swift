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
    @ObservedObject var badges: DockBadges
    @ObservedObject private var icons = IconCache.shared
    @ObservedObject private var activity = AppActivity.shared
    @State private var hold = MenuHold()
    @Environment(\.dockEdge) private var edge

    var body: some View {
        tile
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityAddTraits(.isButton)
            .dockHoverTarget(id: DockEntry.group(group).id, title: group.name)
            // AppKit menu like app tiles: right-click and press-and-hold
            // work on the whole magnified tile, and the menu opens above it.
            .appKitContextMenu(edge: edge, hold: hold, magnifyID: DockEntry.group(group).id) {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(ClosureMenuItem("Rename", onRename))
                menu.addItem(ClosureMenuItem("Change Icon...", onRename))
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Ungroup") { dockModel.ungroup(groupID: group.id) })
                menu.addItem(ClosureMenuItem("Remove from Dock", onRemove))
                return menu
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
        Group {
            if let custom = group.icon {
                let drawn = size * (1 - 2 * IconMetrics.margin)
                // Open: a ring just outside the squircle, so the artwork
                // itself stays untouched like a native app icon.
                GroupIconArtwork(icon: custom, size: drawn)
                    .background(
                        RoundedRectangle(cornerRadius: drawn * 0.225 + 3, style: .continuous)
                            .strokeBorder(Color.white.opacity(isExpanded ? 0.28 : 0), lineWidth: 1)
                            .padding(-3)
                            .animation(GroupPopoverMotion.present, value: isExpanded)
                    )
                    .frame(width: size, height: size)
            } else {
                appGrid
            }
        }
        .dockBadge(dockModel.showBadges ? badges.badge(forGroup: group) : nil, iconSize: size, style: dockModel.badgeStyle)
        .activityChip(activity.activity(forGroup: group), iconSize: size)
        .contentShape(Rectangle())
        .menuHold(hold, onTap: onToggle)
        .magnifiedIcon(id: DockEntry.group(group).id)
    }

    /// Default tile: up to nine member icons in a mini grid.
    private var appGrid: some View {
        let shown = Array(group.apps.prefix(9))
        let columns = shown.count > 4 ? 3 : 2
        // Drawn at an app icon's visible size so spacing matches the icons.
        let drawn = size * (1 - 2 * IconMetrics.margin)
        let inset = drawn * 0.12
        let gap = drawn * 0.05
        let cell = (drawn - inset * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let grid = Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns)
        return RoundedRectangle(cornerRadius: drawn * 0.22, style: .continuous)
            .fill(Color.white.opacity(isExpanded ? 0.32 : 0.18))
            .animation(GroupPopoverMotion.present, value: isExpanded)
            .overlay(
                RoundedRectangle(cornerRadius: drawn * 0.22, style: .continuous)
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
            .frame(width: drawn, height: drawn)
            .frame(width: size, height: size)
    }

    private var indicator: some View {
        RunningIndicator(isOn: anyRunning && dockModel.showIndicators)
            .magnifiedIndicator(id: DockEntry.group(group).id)
    }

    private var accessibilityTitle: String {
        if let badge = badges.badge(forGroup: group) {
            return "\(group.name), \(badge)"
        }
        return group.name
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
    @ObservedObject var badges: DockBadges
    let onLaunch: (PinnedApp, ((NSRunningApplication?) -> Void)?) -> Void
    /// A file drop on a member that can open it.
    let onOpenDocuments: ([URL], PinnedApp) -> Void
    /// `.app` drops into the open grid are added at the given member index.
    let onAddApps: ([PinnedApp], Int) -> Void
    /// A file drag entered (true) or left (false, with a reason) the grid.
    let onDragOverGrid: (Bool, String) -> Void

    @State private var appeared = false
    /// The file drag over the grid right now (same rules as the strip).
    @State private var fileDrop = FileDropSession()
    /// Member a file drag is over that can open the dragged items.
    @State private var dropTargetID: String?
    /// Slot where a pinApps drop would land (dashed gap).
    @State private var insertIndex: Int?
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
                .onPreferenceChange(GroupCellContentFramesKey.self) { groups.setMemberContentFrames($0) }
                .onDrop(of: [.fileURL], delegate: GroupFileDropDelegate(
                    session: fileDrop, targetID: $dropTargetID, insertIndex: $insertIndex,
                    cellFrames: cellFrames, itemCount: group.apps.count,
                    apps: Dictionary(group.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                    onOpen: onOpenDocuments, onAddApps: onAddApps, onDragOverGrid: onDragOverGrid))
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

    private enum GridSlot: Identifiable {
        case app(PinnedApp)
        case gap(String)
        var id: String {
            switch self {
            case .app(let app): app.id
            case .gap(let id): id
            }
        }
    }

    private func content(_ group: FolderGroup) -> some View {
        let slots = gridSlots(
            apps: group.apps,
            insertAt: effectiveInsertIndex,
            hiding: groups.draggingMemberID
        )
        let columns = Self.columns(for: max(slots.count, 1))
        return VStack(spacing: 10) {
            if groups.editingID == group.id {
                GroupNameField(
                    text: $groups.draftName,
                    onCommit: { groups.endRename(commit: true) },
                    onCancel: { groups.endRename(commit: false) }
                )
                // Icon choice, shown while naming (so right after creating
                // a group too). Picks apply at once.
                GroupIconPicker(icon: group.icon) { dockModel.setGroupIcon(groupID: group.id, to: $0, persist: $1) }
                    .onExitCommand { groups.endRename(commit: false) }
                // Saves the name and returns to the title with the pencil.
                Button("Done") { groups.endRename(commit: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Divider()
            } else {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        groups.beginRename(group.id, reason: "title clicked")
                    }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Click to rename")
                    // Pencil beside the (still centered) title: opens the
                    // name field with the icon picker under it.
                    .overlay(alignment: .trailing) {
                        Button {
                            groups.beginRename(group.id, reason: "pencil clicked")
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 24)
                        .help("Edit name and icon")
                        .accessibilityLabel("Edit name and icon")
                    }
            }
            // One flat grid, so a cell keeps its identity (and its drag)
            // when a reorder moves it to another row.
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 4), count: columns),
                alignment: .leading, spacing: 6
            ) {
                ForEach(slots) { slot in
                    switch slot {
                    case .app(let app):
                        GroupAppCell(
                            app: app,
                            groupID: group.id,
                            running: runningApps.runningInstance(of: app),
                            isHidden: runningApps.isHidden(runningApps.runningInstance(of: app)),
                            iconSize: Self.iconSize,
                            width: Self.cellWidth,
                            dockModel: dockModel,
                            groups: groups,
                            bouncer: groups.bouncer,
                            badges: badges,
                            isDropTarget: dropTargetID == app.id,
                            onLaunch: onLaunch
                        )
                    case .gap(let id):
                        groupGridInsertionGap(id: id)
                    }
                }
            }
        }
        .padding(12)
        .overlay {
            if effectiveInsertIndex != nil {
                RoundedRectangle(cornerRadius: dockModel.cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
            }
        }
        .dockBackground(dockModel.look, shadow: true)
    }

    /// Finder drop, strip app drop, or in-grid reorder.
    private var effectiveInsertIndex: Int? { insertIndex ?? groups.memberInsertIndex }

    private func gridSlots(apps: [PinnedApp], insertAt: Int?, hiding: String?) -> [GridSlot] {
        var slots = apps.filter { $0.id != hiding }.map { GridSlot.app($0) }
        if let insertAt {
            slots.insert(.gap("group-insert-gap"), at: min(max(insertAt, 0), slots.count))
        }
        return slots
    }

    private func groupGridInsertionGap(id: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .frame(width: Self.cellWidth, height: Self.iconSize + 28)
            .accessibilityHidden(true)
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: GroupCellFramesKey.self,
                                value: [id: proxy.frame(in: .named(Self.dropSpace))])
                    .preference(key: GroupCellContentFramesKey.self,
                                value: [id: proxy.frame(in: .global)])
            })
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
    var isHidden = false
    let iconSize: CGFloat
    let width: CGFloat
    @ObservedObject var dockModel: DockModel
    let groups: GroupController
    @ObservedObject var bouncer: LaunchBouncer
    @ObservedObject var badges: DockBadges
    var isDropTarget = false
    let onLaunch: (PinnedApp, ((NSRunningApplication?) -> Void)?) -> Void
    @ObservedObject private var icons = IconCache.shared
    @ObservedObject private var activity = AppActivity.shared
    @State private var hovered = false
    /// Token of this cell's drag (see `DragOutController`), nil when idle.
    @State private var dragToken: Int?
    @State private var dragging = false
    /// Where the member sat when its drag began.
    @State private var dragStartIndex = 0
    /// True while the cursor is clearly outside the grid (release removes).
    @State private var dragOutsideGrid = false
    @State private var hold = MenuHold()

    private var bounceKey: String { LaunchBouncer.gridKey(groupID: groupID, appID: app.id) }

    private var accessibilityTitle: String {
        if let badge = badges.badge(for: app) {
            return "\(app.displayName), \(badge)"
        }
        return app.displayName
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: icons.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                // While launching, the bounce window draws the icon.
                .opacity(bouncer.bouncingID == bounceKey ? 0 : (isHidden && dockModel.dimHiddenApps ? RunningIndicator.hiddenOpacity : 1))
                // Same drop highlight as a dock tile.
                .background(
                    RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                        .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                        .padding(-3)
                )
                .dockBadge(dockModel.showBadges ? badges.badge(for: app) : nil, iconSize: iconSize, style: dockModel.badgeStyle)
                .activityChip(running == nil ? nil : activity.activity(for: app), iconSize: iconSize)
                // Where the bounce window goes (the hosting view fills the
                // overlay, so global is overlay content space).
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    groups.cellIconFrameChanged(groupID: groupID, appID: app.id, frame: frame)
                }
                .onDisappear {
                    groups.cellIconFrameChanged(groupID: groupID, appID: app.id, frame: nil)
                }
            RunningIndicator(isOn: running != nil && dockModel.showIndicators)
            Text(app.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width - 8)
        }
        .padding(.vertical, 6)
        .frame(width: width)
        .background(GeometryReader { proxy in
            Color.clear
                .preference(key: GroupCellFramesKey.self,
                            value: [app.id: proxy.frame(in: .named(GroupPopoverView.dropSpace))])
                .preference(key: GroupCellContentFramesKey.self,
                            value: [app.id: proxy.frame(in: .global)])
        })
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.12 : 0))
        )
        .opacity(dragging || groups.draggingMemberID == app.id ? 0 : 1)
        // The dragged member stays in the grid as the dashed slot it will
        // land in, so the layout (and this view's gesture) never changes.
        .overlay {
            if dragging {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .menuHold(hold) {
            TileClick.perform(app, running: running, flags: NSEvent.modifierFlags) { afterOpen in onLaunch(app, afterOpen) }
        }
        .gesture(dragOutGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
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
    private var groupAppIDs: [String] {
        dockModel.groups.first { $0.id == groupID }?.apps.map(\.id) ?? []
    }

    /// Moves this member in the group (saved on release, not here).
    private func moveMember(to index: Int) {
        guard groupAppIDs.firstIndex(of: app.id) != index else { return }
        withAnimation(GroupPopoverMotion.shouldAnimate ? .easeOut(duration: 0.12) : nil) {
            dockModel.moveInGroup(appID: app.id, groupID: groupID, toIndex: index, persist: false)
        }
    }

    /// Drag within the grid reorders live (the dragged cell shows a dashed
    /// slot, like the strip). Drag clearly out asks Remove from Group or
    /// Remove from Dock; out and back leaves the order as it started.
    private var dragOutGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let dragOut = groups.dragOut
                if dragToken == nil {
                    dragging = true
                    dragOutsideGrid = false
                    dragStartIndex = groupAppIDs.firstIndex(of: app.id) ?? 0
                    let start = dragStartIndex
                    let icon = icons.icon(for: app.url)
                    dragToken = dragOut.begin(
                        itemID: app.id, source: .grid, label: "Remove",
                        preview: AnyView(Image(nsImage: icon).resizable().interpolation(.high).frame(width: iconSize, height: iconSize)),
                        size: iconSize
                    ) {
                        // Escape: back where it started.
                        moveMember(to: start)
                        dragging = false
                        dragOutsideGrid = false
                        groups.clearMemberInsert()
                    }
                }
                guard let dragToken else { return }
                let outside = dragOut.update(dragToken)
                dragOutsideGrid = outside
                if outside {
                    moveMember(to: dragStartIndex)
                } else {
                    moveMember(to: groups.reorderSlot(ids: groupAppIDs, dragged: app.id, at: value.location))
                }
            }
            .onEnded { _ in
                guard let token = dragToken else { return }
                dragToken = nil
                dragging = false
                let outside = dragOutsideGrid
                dragOutsideGrid = false
                groups.clearMemberInsert()
                if !outside {
                    // Inside: keep the new order. Never ask to remove.
                    _ = groups.dragOut.end(token, deferResolution: false)
                    dockModel.saveOrder()
                    return
                }
                // Outside: keep the overlay up until the alert returns.
                guard groups.dragOut.end(token, deferResolution: true) else { return }
                DispatchQueue.main.async { finishMemberDragOut() }
            }
    }

    private func finishMemberDragOut() {
        let choice = GroupRemoval.confirmMember(app)
        let remove: Bool
        switch choice {
        case .removeFromGroup:
            withAnimation(GroupPopoverMotion.shouldAnimate ? .easeOut(duration: 0.15) : nil) {
                dockModel.removeFromGroup(app, groupID: groupID)
            }
            remove = true
        case .removeFromDock:
            withAnimation(GroupPopoverMotion.shouldAnimate ? .easeOut(duration: 0.15) : nil) {
                dockModel.unpin(app)
            }
            remove = true
        case .cancel:
            remove = false
        }
        groups.dragOut.resolve(remove: remove)
    }
}

/// Member cell frames in the grid's drop space, by app id.
private struct GroupCellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Member cell frames in overlay content space (SwiftUI global), for strip drops.
private struct GroupCellContentFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// File drops on an open group grid. `.app` drags show an insertion gap and
/// add at that slot; other files open with a member that can handle them.
private struct GroupFileDropDelegate: DropDelegate {
    let session: FileDropSession
    @Binding var targetID: String?
    @Binding var insertIndex: Int?
    let cellFrames: [String: CGRect]
    let itemCount: Int
    let apps: [String: PinnedApp]
    let onOpen: ([URL], PinnedApp) -> Void
    let onAddApps: ([PinnedApp], Int) -> Void
    let onDragOverGrid: (Bool, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        session.begin()
        onDragOverGrid(true, "entered")
        _ = dropUpdated(info: info)
    }

    func dropExited(info: DropInfo) {
        setTarget(nil)
        clearInsert()
        session.end()
        onDragOverGrid(false, "exited")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if session.mode == .pinApps {
            setTarget(nil)
            let index = slotIndex(at: info.location)
            if insertIndex != index {
                withAnimation(.easeOut(duration: 0.12)) { insertIndex = index }
            }
            return DropProposal(operation: .copy)
        }
        clearInsert()
        return DropProposal(operation: updateTarget(info) == nil ? .forbidden : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let urls = session.urls
        let mode = session.mode
        let at = insertIndex ?? itemCount
        let id = mode == .pinApps ? nil : updateTarget(info)
        setTarget(nil)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { insertIndex = nil }
        session.end()
        onDragOverGrid(false, "dropped")
        if mode == .pinApps {
            let apps = urls.compactMap { PinnedApp(appURL: $0) }
            guard !apps.isEmpty else { return false }
            onAddApps(apps, at)
            gridDropLogger.info("grid app drop: added \(apps.count) app(s) at \(at)")
            return true
        }
        guard let id, let app = apps[id] else {
            gridDropLogger.info("grid file drop rejected: no member here can open it")
            return false
        }
        gridDropLogger.info("grid file drop: opening \(urls.count) item(s) with \(app.displayName, privacy: .public)")
        onOpen(urls, app)
        return true
    }

    private func clearInsert() {
        guard insertIndex != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { insertIndex = nil }
    }

    /// Reading-order index 0...itemCount from cell midpoints.
    private func slotIndex(at point: CGPoint) -> Int {
        let ordered = cellFrames
            .filter { !$0.key.hasPrefix("group-insert") }
            .map(\.value)
            .sorted { a, b in
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
