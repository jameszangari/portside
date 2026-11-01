import AppKit
import SwiftUI
import os.log

private let itemLogger = Logger(subsystem: "com.james.portside", category: "DockItem")

/// macOS app icons leave a transparent margin around the visible shape
/// (100pt of the 1024pt grid on each side). Tiles that fill their whole
/// frame (widgets, groups, folders) inset by this much so every item keeps
/// the same visible spacing, and icon gap 0 is the tightest the icons sit.
enum IconMetrics {
    static let margin: CGFloat = 100.0 / 1024
    /// The folder and Trash images fill nearly their whole frame (about 2 to
    /// 4% margin against an app icon's 10%). Drawn at this scale inside the
    /// tile they match an app icon's visible size and edge spacing.
    static let fullBleedScale: CGFloat = 0.86
}

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

    /// Bumped when every icon was dropped (icon style setting or the system
    /// icon style changed). Published so tiles redraw.
    @Published private(set) var generation = 0

    /// Set from `DockModel.iconStyle`.
    private(set) var style: IconStyle = .matchSystem
    private var themeObserver: IconThemeObserver?

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
        let center = NotificationCenter.default
        observer = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screenChanged() }
        // Also when the dock moves to another display (different Retina scale).
        center.addObserver(
            forName: .dockScreenDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.screenChanged() }
    }

    /// Starts following the system icon style. Needs NSApp, so it is called
    /// at launch rather than from `init`.
    func startObservingTheme() {
        guard themeObserver == nil else { return }
        themeObserver = IconThemeObserver { [weak self] in self?.dropAll(reason: "system icon style changed") }
    }

    func setStyle(_ newStyle: IconStyle) {
        guard newStyle != style else { return }
        style = newStyle
        dropAll(reason: "icon style \(newStyle.rawValue)")
    }

    private func dropAll(reason: String) {
        itemLogger.info("\(reason, privacy: .public), dropping \(self.cache.count) icons")
        cache.removeAll()
        AppIcon.invalidateSystemIcon()
        generation += 1
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
        let source = (style == .original ? Self.originalIcon(url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
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

    /// The app's own icon file, which the system style does not touch.
    /// Nil when the app only has a compiled asset catalog icon.
    private static func originalIcon(_ url: URL) -> NSImage? {
        guard let bundle = Bundle(url: url),
              var name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, !name.isEmpty else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".icns" }
        guard let file = bundle.resourceURL?.appendingPathComponent(name) else { return nil }
        return NSImage(contentsOf: file)
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
    /// `completion` runs on the main queue with Launch Services' result.
    /// With `documents`, the app opens them (a file dropped on its tile).
    static func open(_ app: PinnedApp, running: NSRunningApplication?, documents: [URL] = [],
                     completion: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        let url = running?.bundleURL ?? app.url
        let started = CACurrentMediaTime()
        let action = running == nil ? "launching" : "activating"
        let opening = documents.isEmpty ? "" : " to open \(documents.count) item(s)"
        itemLogger.info("\(action, privacy: .public) \(app.displayName, privacy: .public)\(opening, privacy: .public)")

        running?.unhide()
        // openApplication goes through Launch Services, which may activate
        // another app even though Portside itself is never active. For a running
        // app it also sends the reopen event, so an app with no windows opens
        // one, matching the native Dock.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let handler: (NSRunningApplication?, Error?) -> Void = { result, error in
            let ms = (CACurrentMediaTime() - started) * 1000
            if let error {
                itemLogger.error("open failed for \(app.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                itemLogger.info("opened \(result?.localizedName ?? "?", privacy: .public) in \(ms, format: .fixed(precision: 1))ms")
            }
            if let completion {
                DispatchQueue.main.async { completion(result, error) }
            }
        }
        if documents.isEmpty {
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: handler)
        } else {
            NSWorkspace.shared.open(documents, withApplicationAt: url, configuration: config, completionHandler: handler)
        }
    }
}

/// Portside's own tile, shown with the running apps while Settings is open
/// (Portside is a regular app then). Clicking it brings Settings forward.
struct PortsideTileView: View {
    let size: CGFloat
    /// Redraws when the icon style or the system icon style changes.
    @ObservedObject private var icons = IconCache.shared
    let onOpenSettings: () -> Void
    @State private var hold = MenuHold()
    @Environment(\.dockEdge) private var edge

    static let hoverID = "portside.self"

    var body: some View {
        tile
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Portside")
            .accessibilityAddTraits(.isButton)
            .dockHoverTarget(id: Self.hoverID, title: "Portside")
            // Same AppKit menu path as app tiles (whole magnified tile).
            .appKitContextMenu(edge: edge, hold: hold, magnifyID: Self.hoverID) {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(ClosureMenuItem("Settings...", onOpenSettings))
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Quit") { NSApp.terminate(nil) })
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
        Image(nsImage: AppIcon.image(points: size, matchSystem: icons.style == .matchSystem))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .menuHold(hold, onTap: onOpenSettings)
            .magnifiedIcon(id: Self.hoverID)
    }

    private var indicator: some View {
        Circle()
            .fill(Color.primary.opacity(0.75))
            .frame(width: 4, height: 4)
            .magnifiedIndicator(id: Self.hoverID)
    }
}

/// One app tile: icon, running indicator, click and context menu.
struct DockItemView: View {
    let app: PinnedApp
    let running: NSRunningApplication?
    let isPinned: Bool
    let size: CGFloat
    @ObservedObject var dockModel: DockModel
    @ObservedObject var bouncer: LaunchBouncer
    @ObservedObject var badges: DockBadges
    /// A file drag is over this tile and the app can open it.
    var isDropTarget = false
    @ObservedObject private var icons = IconCache.shared
    @State private var hold = MenuHold()
    @Environment(\.dockEdge) private var edge

    var body: some View {
        tile
            .accessibilityLabel(accessibilityTitle)
        .dockHoverTarget(id: app.id, title: app.displayName)
        .appKitContextMenu(edge: edge, hold: hold, magnifyID: app.id) {
            AppTileMenu.build(.init(app: app, running: running, isPinned: isPinned, dockModel: dockModel))
        }
    }

    private var accessibilityTitle: String {
        if let badge = badges.badge(for: app) {
            return "\(app.displayName), \(badge)"
        }
        return app.displayName
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
            // While launching, the bounce window draws the icon. Hidden here
            // only visually: the slot and its click target stay put.
            .opacity(bouncer.bouncingID == app.id ? 0 : 1)
            // Native-Dock-style drop highlight. Negative padding inside the
            // background, so it never changes the tile's layout.
            .background(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.primary.opacity(isDropTarget ? 0.22 : 0))
                    .padding(-3)
            )
            .dockBadge(dockModel.showBadges ? badges.badge(for: app) : nil, iconSize: size, style: dockModel.badgeStyle)
            .contentShape(Rectangle())
            .menuHold(hold) {
                // Modifier state at click time; a tap gesture has no event.
                TileClick.perform(app, running: running, flags: NSEvent.modifierFlags) { afterOpen in
                    if running == nil && isPinned {
                        bouncer.launch(app, size: size, afterOpen: afterOpen)
                    } else {
                        AppLauncher.open(app, running: running) { result, error in
                            if error == nil { afterOpen?(result) }
                        }
                    }
                }
            }
            // Outside the gestures, so clicks follow the magnified icon.
            .magnifiedIcon(id: app.id)
    }

    private var indicator: some View {
        Circle()
            .fill(Color.primary.opacity(running == nil ? 0 : 0.75))
            .frame(width: 4, height: 4)
            .magnifiedIndicator(id: app.id)
    }
}
