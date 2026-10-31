import AppKit
import os

/// Finds the brand images that SwiftPM copies from `Support/` into the
/// `portside_portside.bundle` resource bundle.
///
/// This deliberately avoids `Bundle.module`: its generated accessor calls
/// `fatalError` when the bundle is not where it expects. In Portside.app it
/// looks next to `Portside.app` itself, but scripts/build-app.sh puts the
/// bundle in `Contents/Resources` (the only place codesign accepts it).
/// Here a missing bundle or file only logs, and callers fall back.
enum BrandAssets {
    static let logger = Logger(subsystem: "com.james.portside", category: "Brand")

    private static let bundleName = "portside_portside.bundle"

    /// Portside.app: `Contents/Resources`. `swift run`: next to the
    /// executable in `.build/.../debug`. Nil when neither has it.
    static let bundle: Bundle? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(bundleName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        for url in candidates {
            if let bundle = Bundle(url: url) {
                logger.info("resource bundle: \(url.path, privacy: .public)")
                return bundle
            }
        }
        logger.error("resource bundle \(bundleName, privacy: .public) not found, using fallback icons")
        return nil
    }()

    /// One PNG from the resource bundle, or nil (logged) when missing.
    static func bitmap(named name: String) -> NSBitmapImageRep? {
        guard let url = bundle?.url(forResource: name, withExtension: "png") else {
            if bundle != nil {
                logger.error("missing resource \(name, privacy: .public).png")
            }
            return nil
        }
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            logger.error("unreadable resource \(name, privacy: .public).png")
            return nil
        }
        return rep
    }

    /// The menu bar mark from design/brand/menu-bar (black with alpha) as a
    /// template image, so macOS tints it for light, dark, and tinted menu
    /// bars. 22pt canvas with 1x and 2x pixels. Falls back to an SF Symbol.
    static let menuBarIcon: NSImage = {
        let points = NSSize(width: 22, height: 22)
        let reps = ["MenuBarIcon-22", "MenuBarIcon-44"].compactMap(bitmap(named:))
        let image: NSImage
        if reps.isEmpty {
            logger.error("menu bar icon missing, using the sailboat symbol")
            image = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: "Portside") ?? NSImage(size: points)
        } else {
            image = NSImage(size: points)
            for rep in reps {
                rep.size = points
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = "Portside"
        return image
    }()
}
