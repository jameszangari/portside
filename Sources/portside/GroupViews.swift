import SwiftUI

/// A group's tile in the strip: up to nine member icons in a mini grid,
/// with a running dot if any member is running.
struct GroupTileView: View {
    let group: FolderGroup
    let size: CGFloat
    let isExpanded: Bool
    let anyRunning: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
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
                Button("Remove from Dock") { dockModel.removeGroup(groupID: group.id) }
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
    }

    private var indicator: some View {
        Circle()
            .fill(Color.primary.opacity(anyRunning ? 0.75 : 0))
            .frame(width: 4, height: 4)
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
    let onLaunch: (PinnedApp) -> Void

    @State private var appeared = false

    private static let iconSize: CGFloat = 52
    private static let cellWidth: CGFloat = 76

    var body: some View {
        if let group = dockModel.groups.first(where: { $0.id == groupID }) {
            content(group)
                .scaleEffect(appeared ? 1 : 0.92, anchor: edge.growthAnchor)
                .opacity(appeared ? 1 : 0)
                .onAppear {
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        appeared = true
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) { appeared = true }
                    }
                }
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
                                onLaunch: onLaunch
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
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

/// One app in the expanded group: click to open, right-click for actions.
private struct GroupAppCell: View {
    let app: PinnedApp
    let groupID: String
    let running: NSRunningApplication?
    let iconSize: CGFloat
    let width: CGFloat
    @ObservedObject var dockModel: DockModel
    let onLaunch: (PinnedApp) -> Void
    @ObservedObject private var icons = IconCache.shared
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: icons.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onLaunch(app) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Remove from Group") { dockModel.removeFromGroup(app, groupID: groupID) }
            Button("Remove from Dock") { dockModel.unpin(app) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            if let running {
                Divider()
                Button("Quit") { running.terminate() }
            }
        }
    }
}
