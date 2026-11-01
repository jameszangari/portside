import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

/// Folder stack tile in the right section: mini grid of folder contents,
/// or the folder icon when empty / unreadable.
struct StackTileView: View {
    let stack: FolderStack
    let size: CGFloat
    let isExpanded: Bool
    var isDropTarget = false
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    @ObservedObject var contents: StackContents
    /// Nil in drag previews, which have no menu.
    var dockModel: DockModel?
    @ObservedObject private var icons = IconCache.shared
    @State private var hold = MenuHold()
    @Environment(\.dockEdge) private var edge

    private var preview: [StackItem] {
        stack.showAsFolder ? [] : Array(contents.items(for: stack).prefix(9))
    }

    var body: some View {
        tile
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stack.displayName)
            .accessibilityAddTraits(.isButton)
            .dockHoverTarget(id: stack.hoverID, title: stack.displayName)
            .appKitContextMenu(edge: edge, hold: hold, magnifyID: stack.hoverID) {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(ClosureMenuItem("Open") { onOpen() })
                menu.addItem(ClosureMenuItem("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([stack.url])
                })
                if let dockModel {
                    menu.addItem(.separator())
                    StackOptionsMenu.items(for: stack, dockModel: dockModel).forEach(menu.addItem)
                }
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Remove from Dock", onRemove))
                return menu
            }
    }

    @ViewBuilder private var tile: some View {
        switch edge {
        case .bottom: VStack(spacing: 2) { icon; indicator }
        case .left: HStack(spacing: 2) { indicator; icon }
        case .right: HStack(spacing: 2) { icon; indicator }
        }
    }

    @ViewBuilder private var icon: some View {
        if preview.isEmpty { folderIcon } else { gridIcon }
    }

    /// Just the folder's own icon (Downloads, Documents and so on keep their
    /// native artwork), the same size as an app icon, with no card behind it.
    private var folderIcon: some View {
        Image(nsImage: icons.icon(for: stack.url))
            .resizable()
            .interpolation(.high)
            .frame(width: size * IconMetrics.fullBleedScale, height: size * IconMetrics.fullBleedScale)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                    .padding(-3)
            )
            .contentShape(Rectangle())
            .menuHold(hold, onTap: onToggle)
            .magnifiedIcon(id: stack.hoverID)
    }

    private var gridIcon: some View {
        let shown = preview
        let columns = shown.count > 4 ? 3 : max(shown.isEmpty ? 1 : 2, shown.count > 1 ? 2 : 1)
        // Drawn at an app icon's visible size so spacing matches the icons.
        let drawn = size * (1 - 2 * IconMetrics.margin)
        let inset = drawn * 0.12
        let gap = drawn * 0.05
        let cell = (drawn - inset * 2 - gap * CGFloat(max(columns - 1, 0))) / CGFloat(max(columns, 1))
        let grid = Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns)
        return RoundedRectangle(cornerRadius: drawn * 0.22, style: .continuous)
            .fill(Color.white.opacity(isExpanded ? 0.32 : 0.18))
            .animation(GroupPopoverMotion.present, value: isExpanded)
            .overlay(
                RoundedRectangle(cornerRadius: drawn * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay {
                LazyVGrid(columns: grid, alignment: .leading, spacing: gap) {
                    ForEach(shown) { item in
                        Image(nsImage: icons.icon(for: item.url))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: cell, height: cell)
                    }
                }
                .padding(inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                    .padding(-3)
            )
            .frame(width: drawn, height: drawn)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .menuHold(hold, onTap: onToggle)
            .magnifiedIcon(id: stack.hoverID)
    }

    private var indicator: some View {
        Color.clear
            .frame(width: 4, height: 4)
            .magnifiedIndicator(id: stack.hoverID)
    }
}

/// View, sort and filter choices for a stack. Shared by the tile right-click
/// menu and the open stack's `...` button (both AppKit, so checkbox items
/// fire on the first click in the non-activating overlay).
enum StackOptionsMenu {
    static func items(for stack: FolderStack, dockModel: DockModel) -> [NSMenuItem] {
        let id = stack.id
        // The tile may be older than the last change; read the live values.
        let stack = dockModel.stacks.first { $0.id == id } ?? stack

        func submenu<Option: Identifiable & Equatable>(
            _ title: String, _ options: [Option], current: Option, label: (Option) -> String,
            apply: @escaping (inout FolderStack, Option) -> Void
        ) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu()
            menu.autoenablesItems = false
            for option in options {
                let item = ClosureMenuItem(label(option)) {
                    dockModel.updateStack(id: id) { apply(&$0, option) }
                }
                item.state = option == current ? .on : .off
                menu.addItem(item)
            }
            parent.submenu = menu
            return parent
        }
        func toggle(_ title: String, _ isOn: Bool, _ apply: @escaping (inout FolderStack) -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title) { dockModel.updateStack(id: id, apply) }
            item.state = isOn ? .on : .off
            return item
        }

        return [
            submenu("View as", StackViewMode.allCases, current: stack.view, label: \.title) { $0.view = $1 },
            submenu("Sort by", StackSortMode.allCases, current: stack.sort, label: \.title) { $0.sort = $1 },
            toggle("Folders First", stack.foldersFirst) { $0.foldersFirst.toggle() },
            toggle("Show Hidden Files", stack.showHidden) { $0.showHidden.toggle() },
            toggle("Display as Folder", stack.showAsFolder) { $0.showAsFolder.toggle() },
        ]
    }
}

/// Borderless ellipsis that pops an AppKit menu under itself. Uses the same
/// `MenuKeyFocus` path as tile menus so Escape and arrows work.
private struct StackOptionsMenuButton: NSViewRepresentable {
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> StackOptionsMenuNSButton {
        let button = StackOptionsMenuNSButton()
        button.menuProvider = menu
        return button
    }

    func updateNSView(_ button: StackOptionsMenuNSButton, context: Context) {
        button.menuProvider = menu
    }
}

private final class StackOptionsMenuNSButton: NSButton {
    var menuProvider: (() -> NSMenu)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        target = self
        action = #selector(showOptions)
        setButtonType(.momentaryChange)
        toolTip = "View and sort options"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    @objc private func showOptions() {
        guard let menu = menuProvider?(), let window else { return }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        // popUp wants the menu's top-left; place it just under the button.
        let origin = NSPoint(x: frame.minX, y: frame.minY)
        MenuKeyFocus.shared.popUp(menu, at: origin)
    }
}

/// Expanded folder stack grid in the overlay panel.
struct StackPopoverView: View {
    let stackID: String
    let edge: DockEdge
    @ObservedObject var dockModel: DockModel
    @ObservedObject var stacks: StackController
    let onOpen: (StackItem) -> Void
    /// Deposit at a display index in the grid (0...count).
    let onDeposit: ([URL], Int) -> Void
    let onDragOverGrid: (Bool, String) -> Void

    @State private var appeared = false
    @State private var insertIndex: Int?
    @State private var cellFrames: [String: CGRect] = [:]

    static let iconSize: CGFloat = 52
    private static let cellWidth: CGFloat = 76
    static let shadowPadding: CGFloat = 18
    private static let maxGridHeight: CGFloat = 320
    private static let listWidth: CGFloat = 280
    static let dropSpace = "stack-grid-drop"

    static func hitInsets(for edge: DockEdge) -> NSEdgeInsets {
        let p = shadowPadding
        switch edge {
        case .bottom: return NSEdgeInsets(top: p, left: p, bottom: 0, right: p)
        case .left: return NSEdgeInsets(top: p, left: 0, bottom: p, right: p)
        case .right: return NSEdgeInsets(top: p, left: p, bottom: p, right: 0)
        }
    }

    var body: some View {
        if let stack = dockModel.stacks.first(where: { $0.id == stackID }) {
            content(stack)
                .scaleEffect(appeared ? 1 : GroupPopoverMotion.collapsedScale, anchor: edge.growthAnchor)
                .opacity(appeared ? 1 : 0)
                .padding(edge.nearSide, DockHover.labelGap)
                .background(Color.black.opacity(0.01))
                .coordinateSpace(name: Self.dropSpace)
                .onPreferenceChange(StackCellFramesKey.self) { cellFrames = $0 }
                .onDrop(of: [.fileURL], delegate: StackGridDropDelegate(
                    insertIndex: $insertIndex,
                    cellFrames: cellFrames,
                    itemCount: stacks.contents.items(for: stack).count,
                    appendOnly: stack.view == .fan || stack.sort != .manual,
                    isList: stack.view == .list,
                    onDeposit: onDeposit,
                    onDragOverGrid: onDragOverGrid
                ))
                .padding(Edge.Set.all.subtracting(edge.nearSide), Self.shadowPadding)
                .onAppear { setAppeared(true, animation: GroupPopoverMotion.present) }
                .onChange(of: stacks.isClosing) { _, closing in
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

    private func content(_ stack: FolderStack) -> some View {
        let items = stacks.contents.items(for: stack)
        // Fan and sorted stacks pick each item's position themselves, so a
        // drop only needs to land in the folder.
        let positioned = stack.view != .fan && stack.sort == .manual
        let gapAt = positioned ? insertIndex : nil
        let slotCount = items.count + (gapAt != nil ? 1 : 0)
        let columns = GroupPopoverView.columns(for: max(slotCount, 1))
        return VStack(spacing: 10) {
            header(stack)
            if items.isEmpty && insertIndex == nil {
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 160, minHeight: 48)
            } else {
                switch stack.view {
                case .grid: gridBody(items: items, gapAt: gapAt, columns: columns)
                case .list: listBody(items: items, gapAt: gapAt, sort: stack.sort)
                case .fan: fanBody(stack: stack, items: items)
                }
            }
        }
        .padding(12)
        .overlay {
            if insertIndex != nil {
                RoundedRectangle(cornerRadius: dockModel.cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
            }
        }
        .dockBackground(dockModel.look, shadow: true)
    }

    private func header(_ stack: FolderStack) -> some View {
        HStack(spacing: 6) {
            Text(stack.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            // AppKit menu, not SwiftUI Menu+Toggle: Toggles in a SwiftUI Menu
            // on the non-key overlay need a wake-up click before they fire.
            StackOptionsMenuButton {
                let menu = NSMenu()
                menu.autoenablesItems = false
                StackOptionsMenu.items(for: stack, dockModel: dockModel).forEach(menu.addItem)
                return menu
            }
            .frame(width: 18, height: 18)
            .accessibilityLabel("View and sort options")
        }
    }

    private func gridBody(items: [StackItem], gapAt: Int?, columns: Int) -> some View {
        ScrollView {
            let slots = gridSlots(items: items, insertAt: gapAt)
            let rows = stride(from: 0, to: slots.count, by: columns).map {
                Array(slots[$0..<min($0 + columns, slots.count)])
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(rows[row]) { slot in
                            switch slot {
                            case .item(let item):
                                StackItemCell(item: item, iconSize: Self.iconSize, width: Self.cellWidth, onOpen: onOpen)
                            case .gap(let id):
                                stackGridInsertionGap(id: id)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: Self.maxGridHeight)
    }

    private func listBody(items: [StackItem], gapAt: Int?, sort: StackSortMode) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(gridSlots(items: items, insertAt: gapAt)) { slot in
                    switch slot {
                    case .item(let item):
                        StackListRow(item: item, sort: sort, width: Self.listWidth, onOpen: onOpen)
                    case .gap(let id):
                        stackGridInsertionGap(id: id)
                            .frame(width: Self.listWidth, height: StackListRow.height)
                    }
                }
            }
        }
        .frame(maxHeight: Self.maxGridHeight)
    }

    private func fanBody(stack: FolderStack, items: [StackItem]) -> some View {
        StackFanView(
            items: Array(items.prefix(StackFanView.limit)),
            extra: max(items.count - StackFanView.limit, 0),
            folderURL: stack.url,
            edge: edge,
            onOpen: onOpen,
            onOpenFolder: { stacks.openFolder(stackID) }
        )
    }

    private enum GridSlot: Identifiable {
        case item(StackItem)
        case gap(String)
        var id: String {
            switch self {
            case .item(let item): item.id
            case .gap(let id): id
            }
        }
    }

    private func gridSlots(items: [StackItem], insertAt: Int?) -> [GridSlot] {
        var slots = items.map { GridSlot.item($0) }
        if let insertAt {
            slots.insert(.gap("stack-insert-gap"), at: min(max(insertAt, 0), slots.count))
        }
        return slots
    }

    private func stackGridInsertionGap(id: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .frame(width: Self.cellWidth, height: Self.iconSize + 28)
            .accessibilityHidden(true)
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: StackCellFramesKey.self,
                    value: [id: proxy.frame(in: .named(Self.dropSpace))]
                )
            })
    }
}

private struct StackCellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, n in n })
    }
}

/// Finder drops on the open stack grid: insertion gap at the slot under the cursor.
private struct StackGridDropDelegate: DropDelegate {
    @Binding var insertIndex: Int?
    let cellFrames: [String: CGRect]
    let itemCount: Int
    /// Fan and sorted stacks: the drop lands in the folder, no chosen slot.
    let appendOnly: Bool
    /// Rows stack vertically, so the slot is decided by height alone.
    let isList: Bool
    let onDeposit: ([URL], Int) -> Void
    let onDragOverGrid: (Bool, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        onDragOverGrid(true, "entered")
        _ = dropUpdated(info: info)
    }

    func dropExited(info: DropInfo) {
        clearInsert()
        onDragOverGrid(false, "exited")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let index = appendOnly ? itemCount : slotIndex(at: info.location)
        if insertIndex != index {
            withAnimation(.easeOut(duration: 0.12)) {
                insertIndex = index
            }
        }
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let at = insertIndex ?? itemCount
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { insertIndex = nil }
        onDragOverGrid(false, "dropped")
        loadURLs(info.itemProviders(for: [.fileURL])) { urls in
            guard !urls.isEmpty else { return }
            onDeposit(urls, at)
        }
        return true
    }

    private func clearInsert() {
        guard insertIndex != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { insertIndex = nil }
    }

    /// Reading-order index 0...itemCount from cell midpoints.
    private func slotIndex(at point: CGPoint) -> Int {
        let ordered = cellFrames
            .filter { !$0.key.hasPrefix("stack-insert") }
            .map(\.value)
            .sorted { a, b in
                if abs(a.minY - b.minY) < 4 { return a.minX < b.minX }
                return a.minY < b.minY
            }
        if ordered.isEmpty { return 0 }
        if isList {
            return ordered.firstIndex { point.y < $0.midY } ?? ordered.count
        }
        for (i, frame) in ordered.enumerated() {
            if point.y < frame.midY - frame.height * 0.45 { return i }
            if abs(point.y - frame.midY) <= frame.height * 0.55, point.x < frame.midX {
                return i
            }
        }
        return ordered.count
    }

    private func loadURLs(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else {
                    url = nil
                }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

private struct StackItemCell: View {
    let item: StackItem
    let iconSize: CGFloat
    let width: CGFloat
    let onOpen: (StackItem) -> Void
    @ObservedObject private var icons = IconCache.shared
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: icons.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: width)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.12 : 0))
        )
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: StackCellFramesKey.self,
                value: [item.id: proxy.frame(in: .named(StackPopoverView.dropSpace))]
            )
        })
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onOpen(item) }
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// One row of the list view: icon, name, and a detail that follows the sort.
private struct StackListRow: View {
    static let height: CGFloat = 30
    let item: StackItem
    let sort: StackSortMode
    let width: CGFloat
    let onOpen: (StackItem) -> Void
    @ObservedObject private var icons = IconCache.shared
    @State private var hovered = false

    private var detail: String {
        switch sort {
        case .dateAdded: item.dateAdded.formatted(date: .abbreviated, time: .omitted)
        case .dateModified: item.dateModified.formatted(date: .abbreviated, time: .omitted)
        default: item.kind
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icons.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.12 : 0))
        )
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: StackCellFramesKey.self,
                value: [item.id: proxy.frame(in: .named(StackPopoverView.dropSpace))]
            )
        })
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onOpen(item) }
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// The native Dock's fan: icons rise from the tile in a gentle curve, each
/// with its name beside it. The first item sits nearest the tile.
private struct StackFanView: View {
    static let limit = 10
    private static let iconSize: CGFloat = 40
    private static let step: CGFloat = 46
    private static let labelWidth: CGFloat = 150
    private static let arc: CGFloat = 56

    let items: [StackItem]
    /// Items past `limit`, summed into one "more in Finder" row.
    let extra: Int
    let folderURL: URL
    let edge: DockEdge
    let onOpen: (StackItem) -> Void
    let onOpenFolder: () -> Void
    @ObservedObject private var icons = IconCache.shared

    private var count: Int { items.count + (extra > 0 ? 1 : 0) }

    /// Sideways shift of row `index`: none at the tile, most at the top. The
    /// fan bends away from a side dock and toward the right on the bottom.
    private func shift(_ index: Int) -> CGFloat {
        let t = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
        let bend = Self.arc * pow(t, 1.6)
        return edge == .right ? Self.arc - bend : bend
    }

    var body: some View {
        let height = CGFloat(max(count - 1, 0)) * Self.step + Self.iconSize
        let rowWidth = Self.iconSize + 8 + Self.labelWidth
        // Names go on the side facing away from the screen edge.
        let labelsLeft = edge != .left
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(icon: icons.icon(for: item.url), title: item.name, labelsLeft: labelsLeft) { onOpen(item) }
                    .offset(x: shift(index), y: height - Self.iconSize - CGFloat(index) * Self.step)
            }
            if extra > 0 {
                row(icon: icons.icon(for: folderURL), title: "\(extra) more in Finder", labelsLeft: labelsLeft, action: onOpenFolder)
                    .offset(x: shift(items.count), y: height - Self.iconSize - CGFloat(items.count) * Self.step)
            }
        }
        .frame(width: rowWidth + Self.arc, height: height, alignment: .topLeading)
    }

    private func row(icon: NSImage, title: String, labelsLeft: Bool, action: @escaping () -> Void) -> some View {
        FanRow(icon: icon, title: title, iconSize: Self.iconSize, labelWidth: Self.labelWidth,
               labelsLeft: labelsLeft, action: action)
    }
}

private struct FanRow: View {
    let icon: NSImage
    let title: String
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let labelsLeft: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            if labelsLeft { label; image } else { image; label }
        }
        .frame(height: iconSize)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private var image: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: iconSize, height: iconSize)
            .scaleEffect(hovered ? 1.08 : 1)
            .animation(.easeOut(duration: 0.1), value: hovered)
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(white: 0.12, opacity: hovered ? 0.95 : 0.78), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: labelWidth, alignment: labelsLeft ? .trailing : .leading)
    }
}
