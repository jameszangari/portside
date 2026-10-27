import SwiftUI
import UniformTypeIdentifiers
import os.log

private let stripLogger = Logger(subsystem: "com.james.portside", category: "DockStrip")

/// Screen-derived limits for the strip. Updated when displays change.
final class DockLayout: ObservableObject {
    @Published private(set) var maxStripWidth: CGFloat = 0
    private var observer: NSObjectProtocol?

    /// Room left for the panel's own insets and a small margin at each side.
    private let reservedWidth: CGFloat = 40

    init() {
        update()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }
    }

    private func update() {
        let width = NSScreen.screens.first?.frame.width ?? 1440
        maxStripWidth = width - reservedWidth
    }
}

/// SwiftUI view that renders the dock strip: pinned apps, a divider, running
/// apps that are not pinned (like the native Dock), a divider, then widgets.
///
/// Like the native Dock, tiles shrink below `iconSize` when everything would
/// not fit on screen. Widgets are measured in tiles, so they shrink too.
///
/// Reorder uses a plain DragGesture inside the strip, not .onDrag: SwiftUI
/// never starts a drag session from this panel because Portside is never the
/// active app, and .onDrag has no "ended" callback anyway.
struct DockStrip: View {
    @ObservedObject var dockModel: DockModel
    @ObservedObject var runningApps: RunningApps
    @ObservedObject var widgets: WidgetStore
    @ObservedObject var layout: DockLayout

    /// The pinned app currently being dragged, if any.
    @State private var dragging: PinnedApp?

    private let spacing = DockMetrics.spacing
    private let horizontalPadding: CGFloat = 8
    private let dividerWidth: CGFloat = 5
    private static let space = "strip"

    /// Tile size after fitting everything into the screen width.
    private func fittedTileSize(extrasCount: Int) -> CGFloat {
        let apps = dockModel.pinnedApps.count + extrasCount
        let units = widgets.hosts.reduce(0) { $0 + $1.size.rawValue }
        let dividers = (extrasCount > 0 ? 1 : 0) + (widgets.hosts.isEmpty ? 0 : 1)
        let items = apps + widgets.hosts.count + dividers
        let innerWidgetGaps = units - widgets.hosts.count
        let fixed = horizontalPadding * 2 + dividerWidth * CGFloat(dividers)
            + spacing * CGFloat(max(items - 1, 0) + innerWidgetGaps)
        let tileUnits = CGFloat(max(apps + units, 1))
        let fit = ((layout.maxStripWidth - fixed) / tileUnits).rounded(.down)
        return max(16, min(dockModel.iconSize, fit))
    }

    private var unpinnedRunning: [(PinnedApp, NSRunningApplication)] {
        runningApps.apps.compactMap { running in
            guard let app = PinnedApp(runningApp: running), !dockModel.isPinned(app) else { return nil }
            if dockModel.pinnedApps.contains(where: { runningApps.runningInstance(of: $0) == running }) { return nil }
            return (app, running)
        }
    }

    var body: some View {
        let extras = unpinnedRunning
        let tile = fittedTileSize(extrasCount: extras.count)

        HStack(alignment: .top, spacing: spacing) {
            ForEach(dockModel.pinnedApps) { app in
                DockItemView(app: app, running: runningApps.runningInstance(of: app), isPinned: true, size: tile, dockModel: dockModel)
                    .opacity(dragging?.id == app.id ? 0.5 : 1)
                    .scaleEffect(dragging?.id == app.id ? 1.08 : 1)
                    .gesture(reorderGesture(for: app, tile: tile))
            }

            if !extras.isEmpty {
                divider(tile)
                ForEach(extras, id: \.0.id) { app, running in
                    DockItemView(app: app, running: running, isPinned: false, size: tile, dockModel: dockModel)
                }
            }

            if !widgets.hosts.isEmpty {
                divider(tile)
                ForEach(widgets.hosts) { host in
                    host.view
                        .contextMenu {
                            Button("Remove Widget") { dockModel.setWidget(host.id, enabled: false) }
                        }
                }
            }
        }
        .environment(\.dockTileSize, tile)
        .coordinateSpace(name: DockStrip.space)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .onDrop(of: [.fileURL], delegate: AppFileDropDelegate(dockModel: dockModel, slotWidth: tile + spacing, leadingInset: horizontalPadding))
        .fixedSize()
    }

    private func divider(_ tile: CGFloat) -> some View {
        Divider()
            .frame(width: 1, height: tile * 0.8)
            .padding(.horizontal, 2)
            .padding(.top, tile * 0.1)
    }

    /// Live reorder: the dragged tile jumps to whichever slot the cursor is
    /// over. Order is saved once, on release.
    private func reorderGesture(for app: PinnedApp, tile: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DockStrip.space))
            .onChanged { value in
                if dragging == nil {
                    dragging = app
                    stripLogger.info("reorder started: \(app.displayName, privacy: .public)")
                }
                let slot = Int((value.location.x / (tile + spacing)).rounded(.down))
                withAnimation(.easeOut(duration: 0.12)) {
                    dockModel.move(app, toIndex: slot, persist: false)
                }
            }
            .onEnded { _ in
                dragging = nil
                dockModel.saveOrder()
                let index = dockModel.pinnedApps.firstIndex { $0.id == app.id } ?? -1
                stripLogger.info("reorder ended: \(app.displayName, privacy: .public) at slot \(index)")
            }
    }
}

/// Adds .app bundles dragged from Finder, inserted at the slot under the cursor.
private struct AppFileDropDelegate: DropDelegate {
    let dockModel: DockModel
    let slotWidth: CGFloat
    let leadingInset: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let slot = Int(((info.location.x - leadingInset) / slotWidth).rounded())
        let index = min(max(slot, 0), dockModel.pinnedApps.count)
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
