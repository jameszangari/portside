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
}

/// The see-through glass as a SwiftUI background with rounded corners.
/// Never takes clicks or drags: the strip and grids handle those.
struct SeeThroughGlassView: NSViewRepresentable {
    var cornerRadius: CGFloat

    final class PassThroughGlass: NSGlassEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
