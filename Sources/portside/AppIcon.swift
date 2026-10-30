import AppKit

/// Portside's app icon, drawn at runtime: the bird symbol on a rounded
/// blue gradient. `swift run` has no bundle (no asset catalog), so without
/// this the native Dock and Cmd+Tab would show a generic executable icon.
enum AppIcon {
    static let image: NSImage = draw(size: 512)

    /// `image` rendered once to a 512px bitmap. The drawing handler reruns
    /// at every display size and its shadow blur does not scale with it, so
    /// small renders (Settings header, alerts) show a clipped square shadow.
    static let bitmap: NSImage = {
        var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        return NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
    }()

    /// The Dock keeps showing an unbundled executable's generic icon even
    /// after `applicationIconImage` is set, so the tile also draws the icon
    /// itself.
    static func applyToDockTile() {
        NSApp.applicationIconImage = image
        let tile = NSApp.dockTile
        tile.contentView = NSImageView(image: image)
        tile.display()
    }

    /// Renders the icon into an exact pixel size (no screen scale) and saves
    /// it as PNG. Used by `portside --export-icon` to build AppIcon.icns.
    static func writePNG(to url: URL, pixels: Int) throws {
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
        draw(size: size).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    static func draw(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            // Same proportions as macOS app icons: artwork inset from the
            // canvas, continuous corners.
            let inset = bounds.width * 0.1
            let tile = bounds.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = bounds.width * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -bounds.width * 0.01)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGradient(colors: [
                NSColor(srgbRed: 0.18, green: 0.62, blue: 0.98, alpha: 1),
                NSColor(srgbRed: 0.05, green: 0.28, blue: 0.72, alpha: 1),
            ])?.draw(in: path, angle: -90)

            let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let bird = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Portside")?
                .withSymbolConfiguration(config) {
                let s = bird.size
                bird.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
