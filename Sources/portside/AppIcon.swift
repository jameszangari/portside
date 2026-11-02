import AppKit

/// Portside's app icon.
///
/// Portside.app built from design/icon-composer/AppIcon.icon has an
/// Assets.car and `CFBundleIconName`. Then the icon comes from the system
/// (`NSWorkspace.icon(forFile:)`), so it gets the same Liquid Glass
/// rendering, icon style (light, dark, tinted), and size as every other app
/// in Portside's dock, and the native Dock tile is left to macOS.
///
/// `swift run` has no bundle icon. It borrows the system rendering from a
/// built Portside.app if there is one, otherwise it uses
/// `Support/AppIcon-<px>.png` (actool's flat render of the same .icon:
/// light style only, with a lighter rim than the system rendering). Each
/// size is its own representation, so small renders are not a scaled-down
/// large bitmap. If the PNGs are missing, the generic app icon is used.
enum AppIcon {
    private static let pixelSizes = [16, 32, 128, 256]

    private static let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    /// The system-rendered icon (Liquid Glass, current icon style), or nil.
    /// Portside.app: its own icon, when built with a compiled `.icon`.
    /// `swift run`: borrowed from a Portside.app that LaunchServices knows
    /// (for example build/Portside.app), when that one has a compiled icon.
    /// Dropped when the system icon style changes, so the next read
    /// renders the new style.
    private static var systemIcon: NSImage? {
        if let cachedSystemIcon { return cachedSystemIcon }
        cachedSystemIcon = loadSystemIcon()
        return cachedSystemIcon
    }

    private static var cachedSystemIcon: NSImage?

    static func invalidateSystemIcon() {
        cachedSystemIcon = nil
    }

    private static func loadSystemIcon() -> NSImage? {
        func hasCompiledIcon(_ bundle: Bundle?) -> Bool {
            bundle?.object(forInfoDictionaryKey: "CFBundleIconName") != nil
        }
        if isAppBundle {
            return hasCompiledIcon(.main) ? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) : nil
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.james.portside"),
              hasCompiledIcon(Bundle(url: url)) else { return nil }
        BrandAssets.logger.info("unbundled: using the system icon of \(url.path, privacy: .public)")
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Brand PNGs keyed by pixel size. Empty when the resources are missing.
    /// Kept as CGImages so every NSImage built below shares the pixels.
    private static let reps: [Int: CGImage] = {
        var found: [Int: CGImage] = [:]
        for px in pixelSizes {
            if let cg = BrandAssets.bitmap(named: "AppIcon-\(px)")?.cgImage {
                found[px] = cg
            }
        }
        if found.isEmpty {
            BrandAssets.logger.error("app icon PNGs missing, using the generic app icon")
        }
        return found
    }()

    private static let fallback: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    /// The system-rendered icon when there is one, else the flat PNGs.
    /// Used for the app and Dock tile icons.
    static var image: NSImage { systemIcon ?? flatImage }

    /// All PNG sizes in one 512pt image. NSImage picks the closest
    /// representation for each draw.
    private static let flatImage: NSImage = {
        guard !reps.isEmpty else { return fallback }
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for px in pixelSizes {
            guard let cg = reps[px] else { continue }
            image.addRepresentation(rep(cg, size: image.size))
        }
        return image
    }()

    /// The icon for a fixed point size: only the smallest PNGs that cover
    /// 1x and 2x at that size, so SwiftUI's `Image(nsImage:)` and NSAlert
    /// cannot pick an oversized bitmap and downsample it.
    /// `matchSystem` false: the flat PNGs (Portside's tile with the
    /// "Original" icon style), ignoring the system icon style.
    static func image(points: CGFloat, matchSystem: Bool = true) -> NSImage {
        let size = NSSize(width: points, height: points)
        if matchSystem, let systemIcon, let sized = systemIcon.copy() as? NSImage {
            // IconServices renders this image fresh at each draw size.
            sized.size = size
            return sized
        }
        guard !reps.isEmpty else { return fallback }
        let image = NSImage(size: size)
        var added = Set<Int>()
        for scale in [1.0, 2.0] {
            let needed = Int((points * scale).rounded(.up))
            let px = pixelSizes.first { $0 >= needed && reps[$0] != nil }
                ?? pixelSizes.last { reps[$0] != nil }!
            guard added.insert(px).inserted, let cg = reps[px] else { continue }
            image.addRepresentation(rep(cg, size: size))
        }
        return image
    }

    private static func rep(_ cg: CGImage, size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        return rep
    }

    /// Unbundled only: the Dock keeps showing an executable's generic icon
    /// even after `applicationIconImage` is set, so the tile also draws the
    /// icon itself. Portside.app leaves its tile to macOS, which keeps the
    /// live Liquid Glass rendering.
    static func applyToDockTile() {
        guard !isAppBundle else { return }
        NSApp.applicationIconImage = image
        let tile = NSApp.dockTile
        tile.contentView = NSImageView(image: image)
        tile.display()
    }

    /// Saves the icon as a PNG of exactly `pixels` px. Used by
    /// `portside --export-icon`, the fallback when scripts/build-app.sh
    /// cannot compile AppIcon.icon or find the brand .icns. Writes the
    /// bundled PNG's pixels when one matches the size.
    static func writePNG(to url: URL, pixels: Int) throws {
        if let cg = reps[pixels], let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try data.write(to: url)
            return
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let size = CGFloat(pixels)
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
