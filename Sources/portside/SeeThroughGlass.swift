import AppKit
import SwiftUI
import os.log

private let glassLogger = Logger(subsystem: "com.james.portside", category: "Appearance")

/// Truly see-through Liquid Glass, the lens in Match macOS and Custom.
///
/// The public `Glass.clear` (and `NSGlassEffectView.Style.clear`) still
/// blurs the backdrop heavily on macOS 27, so text behind it is unreadable.
/// `NSGlassEffectView` has a private integer `_variant`; variant 19 is the
/// clear lens: no blur, refraction only at the rim. Measured on macOS 27.0.1.
///
/// Private API, guarded: the setter is looked up at runtime and the value
/// read back. If either fails (an OS update renamed or renumbered it),
/// `isAvailable` is false and the dock falls back to the public clear glass.
enum SeeThroughGlass {
    static let variant = 19
    private static let setter = NSSelectorFromString("set_variant:")
    private static let getter = NSSelectorFromString("_variant")

    static let isAvailable: Bool = {
        guard NSGlassEffectView.instancesRespond(to: setter),
              NSGlassEffectView.instancesRespond(to: getter) else {
            glassLogger.info("see-through glass unavailable: no _variant on NSGlassEffectView")
            return false
        }
        let probe = NSGlassEffectView()
        probe.setValue(variant, forKey: "_variant")
        let readBack = (probe.value(forKey: "_variant") as? Int) == variant
        glassLogger.info("see-through glass \(readBack ? "available" : "unavailable (read-back mismatch)", privacy: .public)")
        return readBack
    }()

    /// Call only when `isAvailable`.
    static func apply(to view: NSGlassEffectView) {
        view.setValue(variant, forKey: "_variant")
    }

    /// The lens bends the rim through chromatic aberration only, which splits
    /// any dark edge behind it (text on a white page, a window corner) into
    /// red, yellow, and cyan specks. This moves the same bend to the filter's
    /// plain refraction, so it stays and the color goes.
    ///
    /// Private filter keys, guarded: `inputKeys` is checked before any key is
    /// touched. If an OS update renames them, the lens keeps its color fringe.
    /// Returns false until the lens has built its layers.
    @discardableResult
    static func removeDispersion(from view: NSView) -> Bool {
        guard let layer = view.layer, let foreground = foregroundLayer(in: layer) else { return false }
        let prefix = "filters.glassForeground."
        guard let amount = foreground.value(forKeyPath: prefix + "inputAberrationAmount") as? Double,
              amount != 0 else { return true }
        for part in ["Offset", "Angle"] {
            foreground.setValue(foreground.value(forKeyPath: prefix + "inputAberration" + part),
                                forKeyPath: prefix + "inputRefraction" + part)
        }
        foreground.setValue(amount, forKeyPath: prefix + "inputRefractionAmount")
        foreground.setValue(0, forKeyPath: prefix + "inputAberrationAmount")
        return true
    }

    /// The layer whose `glassForeground` filter has every key `removeDispersion` sets.
    private static func foregroundLayer(in layer: CALayer) -> CALayer? {
        let needed = ["Amount", "Offset", "Angle"].flatMap { ["inputAberration" + $0, "inputRefraction" + $0] }
        for case let filter as NSObject in layer.filters ?? [] {
            guard filter.responds(to: NSSelectorFromString("name")), filter.responds(to: NSSelectorFromString("inputKeys")),
                  filter.value(forKey: "name") as? String == "glassForeground",
                  let keys = filter.value(forKey: "inputKeys") as? [String],
                  needed.allSatisfy(keys.contains) else { continue }
            return layer
        }
        for sublayer in layer.sublayers ?? [] {
            if let found = foregroundLayer(in: sublayer) { return found }
        }
        return nil
    }
}

/// The see-through glass as a SwiftUI background with rounded corners.
/// Never takes clicks or drags: the strip and grids handle those.
struct SeeThroughGlassView: NSViewRepresentable {
    var cornerRadius: CGFloat

    final class PassThroughGlass: NSGlassEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Next turn: the lens builds and rewrites its layers during layout.
        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in
                if let self { SeeThroughGlass.removeDispersion(from: self) }
            }
        }
    }

    func makeNSView(context: Context) -> PassThroughGlass {
        let view = PassThroughGlass()
        SeeThroughGlass.apply(to: view)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: PassThroughGlass, context: Context) {
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
    }
}
