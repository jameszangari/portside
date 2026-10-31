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
    @ObservedObject private var icons = IconCache.shared
    @State private var hold = MenuHold()
    @Environment(\.dockEdge) private var edge

    private var preview: [StackItem] { Array(contents.items(for: stack).prefix(9)) }

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

    private var icon: some View {
        let shown = preview
        let columns = shown.count > 4 ? 3 : max(shown.isEmpty ? 1 : 2, shown.count > 1 ? 2 : 1)
        let inset = size * 0.12
        let gap = size * 0.05
        let cell = (size - inset * 2 - gap * CGFloat(max(columns - 1, 0))) / CGFloat(max(columns, 1))
        let grid = Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns)
        return RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color.white.opacity(isExpanded ? 0.32 : 0.18))
            .animation(GroupPopoverMotion.present, value: isExpanded)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay {
                if shown.isEmpty {
                    Image(nsImage: icons.icon(for: stack.url))
                        .resizable()
                        .interpolation(.high)
                        .padding(size * 0.14)
                } else {
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
            }
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                    .padding(-3)
            )
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
        let slotCount = items.count + (insertIndex != nil ? 1 : 0)
        let columns = GroupPopoverView.columns(for: max(slotCount, 1))
        return VStack(spacing: 10) {
            Text(stack.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if items.isEmpty && insertIndex == nil {
                Text("Empty folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 160, minHeight: 48)
            } else {
                ScrollView {
                    let slots = gridSlots(items: items, insertAt: insertIndex)
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
        let index = slotIndex(at: info.location)
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
