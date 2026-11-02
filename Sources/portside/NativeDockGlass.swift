import AppKit
import SwiftUI
import os.log

private let nativeGlassLogger = Logger(subsystem: "com.james.portside", category: "Appearance")

/// The macOS Dock's glass, rebuilt from measurements. The Dock draws with a
/// private `GlassMaterialProvider.Configuration.dock` that apps cannot reach,
/// and none of the public or `NSGlassEffectView` variants match it.
///
/// Captured against the real Dock in dark mode on macOS 27.0.1, over white,
/// black, and text backdrops: the System Settings > Appearance > Liquid Glass
/// slider changes only how blurred the Dock is. Its color stays the same, so
/// the recipe is a see-through lens, a fixed gray, and a variable blur.
///
/// Private API, guarded: `CABackdropLayer` and `CAFilter` are looked up at
/// runtime. If either is missing, or the lens is, callers use the public glass.
enum NativeDockGlass {
    /// Where macOS stores the slider, 0 (clear) to 1 (tinted).
    static let tintKey = "NSGlassTintAmount"

    /// Fixed gray over the lens. With the lens, white reads 178 and black 16,
    /// like the Dock.
    static let fill = PaletteColor(
        base: RGBAColor(red: 28.0 / 255, green: 28.0 / 255, blue: 28.0 / 255, alpha: 1), opacity: 0.339
    )

    /// Backdrop color curve, fitted to the Dock over colored text. Clipped
    /// contrast lifts the midtones without moving white or black.
    static let saturation = 1.4
    static let brightness = 0.05
    static let contrast = 1.4

    /// What the backdrop layer does to the desktop behind it.
    struct Recipe: Equatable {
        var radius: CGFloat
        var saturation = NativeDockGlass.saturation
        var brightness = NativeDockGlass.brightness
        var contrast = NativeDockGlass.contrast
    }

    private static let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
    private static let filterClass = NSClassFromString("CAFilter") as? NSObject.Type
    private static let filterSelector = NSSelectorFromString("filterWithType:")

    static let isAvailable: Bool = {
        let ok = SeeThroughGlass.isAvailable
            && backdropClass?.instancesRespond(to: NSSelectorFromString("setWindowServerAware:")) == true
            && filterClass?.responds(to: filterSelector) == true
        nativeGlassLogger.info("native dock glass \(ok ? "available" : "unavailable", privacy: .public)")
        return ok
    }()

    static var systemTint: Double {
        min(max(UserDefaults.standard.double(forKey: tintKey), 0), 1)
    }

    /// Points of blur for a slider value, fitted to how sharp text behind the
    /// Dock stays at 0, 0.5, and 0.83.
    static func blurRadius(forTint tint: Double) -> CGFloat {
        CGFloat(1 + 8 * tint * tint)
    }

    /// Call only when `isAvailable`.
    fileprivate static func makeBackdropLayer() -> CALayer {
        let layer = backdropClass!.init()
        layer.setValue(true, forKey: "windowServerAware")
        return layer
    }

    /// Call only when `isAvailable`.
    fileprivate static func filters(_ recipe: Recipe) -> [Any] {
        func filter(_ type: String, _ key: String, _ value: CGFloat) -> NSObject? {
            let made = filterClass?.perform(filterSelector, with: type)?.takeUnretainedValue() as? NSObject
            made?.setValue(value, forKey: key)
            return made
        }
        let blur = filter("gaussianBlur", "inputRadius", recipe.radius)
        // Without this the blur fades out toward the layer's edges, and sharp
        // text shows through once the radius nears the strip's height.
        blur?.setValue(true, forKey: "inputNormalizeEdges")
        return [
            blur,
            filter("colorSaturate", "inputAmount", recipe.saturation),
            filter("colorBrightness", "inputAmount", recipe.brightness),
            filter("colorContrast", "inputAmount", recipe.contrast),
        ].compactMap { $0 }
    }
}

/// The Dock's blurred backdrop as a SwiftUI background. Never takes clicks or
/// drags: the strip and grids handle those.
struct NativeDockBackdropView: NSViewRepresentable {
    var recipe: NativeDockGlass.Recipe

    final class BackdropView: NSView {
        var recipe: NativeDockGlass.Recipe? {
            didSet {
                guard recipe != oldValue, let recipe else { return }
                layer?.filters = NativeDockGlass.filters(recipe)
            }
        }

        override func makeBackingLayer() -> CALayer { NativeDockGlass.makeBackdropLayer() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.wantsLayer = true
        view.recipe = recipe
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.recipe = recipe
    }
}

/// Reports the System Settings Liquid Glass slider. Event driven: KVO on the
/// global default, like `IconThemeObserver`.
final class SystemGlassTintObserver: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: NativeDockGlass.tintKey, options: [.new], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: NativeDockGlass.tintKey)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in self?.onChange() }
    }
}
