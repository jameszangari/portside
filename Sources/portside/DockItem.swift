import AppKit
import SwiftUI
import os.log

private let itemLogger = Logger(subsystem: "com.james.portside", category: "DockItem")

/// App icons, rendered once per app into a single bitmap that every tile
/// size scales. NSWorkspace icons hold many representations (16 to 1024pt)
/// and the system icon style is not applied to all of them alike, so letting
/// AppKit pick one per tile size made some apps (Splice) swap artwork as the
/// dock was resized.
final class IconCache: ObservableObject {
    static let shared = IconCache()

    /// Screen scale the cached bitmaps were rendered for. Published so tiles
    /// redraw when it changes.
    @Published private(set) var scale: CGFloat

    private struct Entry {
        let image: NSImage
        let stamp: Date?
        var checkedAt: CFTimeInterval
    }

    private var cache: [String: Entry] = [:]
    private var observer: NSObjectProtocol?
    /// How often an entry re-reads its app's modification date. Keeps disk
    /// access out of per-frame redraws during a resize drag.
    private let revalidateInterval: CFTimeInterval = 5

    private init() {
        scale = DockScreen.backingScale
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screenChanged() }
    }

    func icon(for url: URL) -> NSImage {
        let now = CACurrentMediaTime()
        if var entry = cache[url.path] {
            if now - entry.checkedAt < revalidateInterval { return entry.image }
            if Self.stamp(for: url) == entry.stamp {
                entry.checkedAt = now
                cache[url.path] = entry
                return entry.image
            }
            itemLogger.info("icon invalidated, app changed on disk: \(url.lastPathComponent, privacy: .public)")
        }
        let image = render(url)
        cache[url.path] = Entry(image: image, stamp: Self.stamp(for: url), checkedAt: now)
        return image
    }

    private func screenChanged() {
        let newScale = DockScreen.backingScale
        guard newScale != scale else { return }
        itemLogger.info("screen scale \(self.scale, format: .fixed(precision: 1)) -> \(newScale, format: .fixed(precision: 1)), dropping \(self.cache.count) icons")
        cache.removeAll()
        scale = newScale
    }

    /// Draws the icon at the largest dock size, which makes AppKit use one
    /// high resolution representation, and keeps only that bitmap.
    private func render(_ url: URL) -> NSImage {
        let started = CACurrentMediaTime()
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let points = DockModel.iconSizeRange.upperBound
        let pixels = Int((points * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return source
        }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        graphics.imageInterpolation = .high
        NSGraphicsContext.current = graphics
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let bitmap = context.makeImage() else { return source }
        let ms = (CACurrentMediaTime() - started) * 1000
        itemLogger.debug("icon rendered \(url.lastPathComponent, privacy: .public) \(pixels)px in \(ms, format: .fixed(precision: 2))ms")
        return NSImage(cgImage: bitmap, size: NSSize(width: points, height: points))
    }

    /// Changes when the app is updated or replaced.
    private static func stamp(for url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let plist = url.appendingPathComponent("Contents/Info.plist")
        let values = (try? plist.resourceValues(forKeys: keys)) ?? (try? url.resourceValues(forKeys: keys))
        return values?.contentModificationDate
    }
}

/// Launch or activate an app, like clicking it in the native Dock.
enum AppLauncher {
    static func open(_ app: PinnedApp, running: NSRunningApplication?) {
        let url = running?.bundleURL ?? app.url
        let started = CACurrentMediaTime()
        let action = running == nil ? "launching" : "activating"
        itemLogger.info("\(action, privacy: .public) \(app.displayName, privacy: .public)")

        running?.unhide()
        // openApplication goes through Launch Services, which may activate
        // another app even though Portside itself is never active. For a running
        // app it also sends the reopen event, so an app with no windows opens
        // one, matching the native Dock.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { result, error in
            let ms = (CACurrentMediaTime() - started) * 1000
            if let error {
                itemLogger.error("open failed for \(app.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                itemLogger.info("opened \(result?.localizedName ?? "?", privacy: .public) in \(ms, format: .fixed(precision: 1))ms")
            }
        }
    }
}

/// One app tile: icon, running indicator, click and context menu.
struct DockItemView: View {
    let app: PinnedApp
    let running: NSRunningApplication?
    let isPinned: Bool
    let size: CGFloat
    @ObservedObject var dockModel: DockModel
    @ObservedObject private var icons = IconCache.shared
    @Environment(\.dockEdge) private var edge

    var body: some View {
        tile
            .accessibilityLabel(app.displayName)
        .dockHoverTarget(id: app.id, title: app.displayName)
        .contextMenu {
            if isPinned {
                Button("Remove from Dock") { dockModel.unpin(app) }
            } else {
                Button("Keep in Dock") { dockModel.pin(app) }
            }
            Menu("Add to Group") {
                ForEach(dockModel.groups) { group in
                    Button(group.name) { dockModel.addToGroup(app, groupID: group.id) }
                }
                if !dockModel.groups.isEmpty { Divider() }
                Button("New Group") { dockModel.createGroup(with: app) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            if let running {
                Divider()
                Button("Quit") { running.terminate() }
            }
        }
    }

    /// Icon plus running dot. The dot sits between the icon and the screen
    /// edge, like the native Dock.
    @ViewBuilder private var tile: some View {
        switch edge {
        case .bottom: VStack(spacing: 2) { icon; indicator }
        case .left: HStack(spacing: 2) { indicator; icon }
        case .right: HStack(spacing: 2) { icon; indicator }
        }
    }

    private var icon: some View {
        // A tap gesture rather than a Button so the strip's drag gesture
        // can take over once the cursor moves.
        Image(nsImage: icons.icon(for: app.url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture {
                AppLauncher.open(app, running: running)
            }
    }

    private var indicator: some View {
        Circle()
            .fill(Color.primary.opacity(running == nil ? 0 : 0.75))
            .frame(width: 4, height: 4)
    }
}
