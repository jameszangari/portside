import AppKit

/// Which Portside icon to show everywhere Portside draws its own icon
/// (`appIcon` in dock.json). System is Light in light mode and Dark in dark
/// mode; the others pin one look. Portside.app's file in Finder keeps its
/// own icon.
enum AppIconChoice: String, Codable, CaseIterable, Identifiable {
    case system, navy, dark, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .navy: "Navy"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    /// The artwork drawn for this choice: System resolves to Dark or Light.
    func artwork(dark: Bool) -> AppIconChoice {
        self == .system ? (dark ? .dark : .light) : self
    }
}

/// Portside's app icon, in three artworks.
///
/// Navy is `Support/AppIcon-<px>.png` (actool's flat render of
/// design/icon-composer/AppIcon.icon). Each size is its own representation,
/// so small renders are not a scaled-down large bitmap. Dark and Light are
/// drawn from the sail artwork (`Support/AppIconSail*.svg`) on a graphite or
/// cream body, at whatever size they are drawn. If the resources are
/// missing, Navy and then the generic app icon stand in.
///
/// Portside draws its own Dock tile for every choice, so the native Dock
/// tile matches Portside's tile rather than the bundle's compiled icon.
enum AppIcon {
    /// Set from `DockModel.appIcon` through `IconCache.setAppIcon`.
    static var choice = AppIconChoice.system

    private static var drawn: [AppIconChoice: NSImage] = [:]
    /// Dark and Light rendered to bitmaps, by artwork and point size. The
    /// drawn variant redraws its SVG on every display, and a copy of it
    /// starts with no cache, so views and the Dock tile use these instead.
    private static var rendered: [String: NSImage] = [:]
    private static let pixelSizes = [16, 32, 128, 256]

    /// The app's appearance right now. Read at each call; `IconCache` redraws
    /// when it changes. Never creates the app (tests have none): light then.
    private static var isDark: Bool {
        guard let app = NSApp else { return false }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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

    /// The chosen icon. Used for the app and Dock tile icons.
    static var image: NSImage {
        let artwork = choice.artwork(dark: isDark)
        return artwork == .navy ? flatImage : variant(artwork) ?? flatImage
    }

    /// The chosen icon for the Dock tile: a bitmap at the tile's largest
    /// size (128 pt, 2x), so showing it never redraws the artwork.
    static var tileImage: NSImage {
        let artwork = choice.artwork(dark: isDark)
        return artwork == .navy ? flatImage : bitmap(artwork, points: 128) ?? flatImage
    }

    /// The chosen icon at a fixed point size.
    static func image(points: CGFloat) -> NSImage {
        image(for: choice, points: points)
    }

    static func image(for choice: AppIconChoice, points: CGFloat) -> NSImage {
        let artwork = choice.artwork(dark: isDark)
        guard artwork != .navy, let image = bitmap(artwork, points: points) else { return navy(points: points) }
        return image
    }

    /// `artwork` rendered once at 1x and 2x for `points`, then reused.
    private static func bitmap(_ artwork: AppIconChoice, points: CGFloat) -> NSImage? {
        let key = "\(artwork)-\(points)"
        if let image = rendered[key] { return image }
        guard let drawn = variant(artwork) else { return nil }
        let size = NSSize(width: points, height: points)
        let image = NSImage(size: size)
        for scale in [1.0, 2.0] {
            let px = max(1, Int((points * scale).rounded(.up)))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            drawn.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = size
            image.addRepresentation(rep)
        }
        if rendered.count > 24 { rendered.removeAll() }
        rendered[key] = image
        return image
    }

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

    /// Navy for a fixed point size: only the smallest PNGs that cover 1x
    /// and 2x at that size, so SwiftUI's `Image(nsImage:)` and NSAlert
    /// cannot pick an oversized bitmap and downsample it.
    private static func navy(points: CGFloat) -> NSImage {
        let size = NSSize(width: points, height: points)
        guard !reps.isEmpty else {
            let sized = (fallback.copy() as? NSImage) ?? fallback
            sized.size = size
            return sized
        }
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

    /// Dark or Light, drawn fresh at each size. Nil when the artwork is missing.
    private static func variant(_ artwork: AppIconChoice) -> NSImage? {
        if let image = drawn[artwork] { return image }
        let light = artwork == .light
        guard let url = BrandAssets.bundle?.url(forResource: light ? "AppIconSail-Light" : "AppIconSail", withExtension: "svg"),
              let sail = NSImage(contentsOf: url) else {
            BrandAssets.logger.error("sail artwork missing, using the navy icon")
            return nil
        }
        let top = light ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(srgbRed: 0.204, green: 0.216, blue: 0.239, alpha: 1)
        let bottom = light ? NSColor(srgbRed: 0.925, green: 0.898, blue: 0.847, alpha: 1) : NSColor(srgbRed: 0.086, green: 0.090, blue: 0.102, alpha: 1)
        let rim = light ? NSColor.black.withAlphaComponent(0.1) : NSColor.white.withAlphaComponent(0.12)
        let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            // The macOS icon grid: an 824 body in a 1024 canvas. No drop
            // shadow: drawn into a small image it showed as a square box.
            let k = rect.width / 1024
            let body = NSRect(x: rect.minX + 100 * k, y: rect.minY + 100 * k, width: 824 * k, height: 824 * k)
            let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            sail.draw(in: body)
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: body.insetBy(dx: k, dy: k), xRadius: 184 * k, yRadius: 184 * k)
            edge.lineWidth = 2 * k
            rim.setStroke()
            edge.stroke()
            return true
        }
        drawn[artwork] = image
        return image
    }

    private static func rep(_ cg: CGImage, size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        return rep
    }

    /// The Dock keeps showing an executable's generic icon, or a bundle's
    /// compiled one, even after `applicationIconImage` is set, so the tile
    /// also draws the icon itself. Called again when the choice or the
    /// appearance changes.
    static func applyToDockTile() {
        let image = tileImage
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
        flatImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
