import AppKit
import SwiftUI
import os.log

private let appearanceLogger = Logger(subsystem: "com.james.portside", category: "Appearance")

/// How app icons are drawn in the dock.
enum IconStyle: String, Codable, CaseIterable, Identifiable {
    /// The system rendering: follows System Settings > Appearance > Icon and
    /// widget style (Default, Dark, Clear, Tinted), like the native Dock.
    case matchSystem
    /// Each app's own icon file (`CFBundleIconFile`), ignoring the system
    /// style. Apps without one fall back to the system rendering.
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchSystem: "Match macOS"
        case .original: "Original"
        }
    }
}

/// The dock's background.
enum DockBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    /// Liquid Glass, like the native Dock on macOS 26 and later.
    case glass
    /// The pre-macOS 26 translucent material.
    case frosted
    /// An opaque-ish dark fill.
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .frosted: "Frosted"
        case .solid: "Solid"
        }
    }

    static var isGlassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Matches the native Dock of the running macOS.
    static var systemDefault: DockBackgroundStyle { isGlassAvailable ? .glass : .frosted }

    /// Glass falls back to frosted before macOS 26.
    var effective: DockBackgroundStyle {
        self == .glass && !Self.isGlassAvailable ? .frosted : self
    }
}

/// sRGB color with alpha, stored in dock.json as four numbers.
struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// Everything about the dock's look, applied to the strip and to open
/// group grids. Equatable so SwiftUI skips redraws when nothing changed.
struct DockLook: Equatable {
    var style: DockBackgroundStyle
    /// 0 to 1. Glass: 0 is clear glass, 1 is fully frosted. Frosted: the
    /// material's opacity. Solid: the fill's opacity.
    var frost: Double
    var tint: RGBAColor?
    var cornerRadius: CGFloat
}

extension View {
    /// The dock background in `look`, clipped to its rounded rectangle.
    /// `shadow` is for floating surfaces (group grids); glass draws its own.
    func dockBackground(_ look: DockLook, shadow: Bool = false) -> some View {
        dockBackground(look, in: RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous), shadow: shadow)
    }

    /// The same background in another shape (the hover label's bubble), so
    /// it always matches the dock.
    func dockBackground<S: InsettableShape>(_ look: DockLook, in shape: S, shadow: Bool = false) -> some View {
        modifier(DockBackgroundModifier(look: look, shape: shape, shadow: shadow))
    }
}

private struct DockBackgroundModifier<S: InsettableShape>: ViewModifier {
    let look: DockLook
    let shape: S
    let shadow: Bool

    func body(content: Content) -> some View {
        switch look.style.effective {
        case .glass:
            if #available(macOS 26, *) {
                // Clear glass with a material blended in on top: frost 0
                // shows the refraction, frost 1 is a frosted pane. The tint
                // goes into the glass itself so it keeps its highlights.
                content
                    .background { shape.fill(.regularMaterial).opacity(look.frost) }
                    .glassEffect(look.tint.map { Glass.clear.tint($0.color) } ?? .clear, in: shape)
            } else {
                frosted(content, shape: shape)
            }
        case .frosted:
            frosted(content, shape: shape)
        case .solid:
            content
                .background {
                    shape.fill(Color(white: 0.12).opacity(0.4 + 0.6 * look.frost))
                        .overlay { if let tint = look.tint { shape.fill(tint.color) } }
                        .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: 12, y: 5)
                }
                .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }

    private func frosted(_ content: Content, shape: S) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial).opacity(0.3 + 0.7 * look.frost)
                    .overlay { if let tint = look.tint { shape.fill(tint.color) } }
                    .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: 12, y: 5)
            }
            .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

/// Reports changes to the system icon style (System Settings > Appearance >
/// Icon and widget style, global default `AppleIconAppearanceTheme`) and to
/// light/dark mode, which the "automatic" icon styles follow. Event driven:
/// KVO on the global defaults and on `NSApp.effectiveAppearance`.
final class IconThemeObserver: NSObject {
    private static let themeKey = "AppleIconAppearanceTheme"
    private var appearanceObservation: NSKeyValueObservation?
    private let onChange: () -> Void
    private var lastTheme: String?
    private var lastDark: Bool?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        lastTheme = Self.currentTheme
        UserDefaults.standard.addObserver(self, forKeyPath: Self.themeKey, options: [.new], context: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            DispatchQueue.main.async { self?.appearanceChanged(dark: dark) }
        }
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.themeKey)
    }

    static var currentTheme: String? {
        UserDefaults.standard.string(forKey: themeKey)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let theme = Self.currentTheme
            guard theme != lastTheme else { return }
            appearanceLogger.info("icon style \(self.lastTheme ?? "default", privacy: .public) -> \(theme ?? "default", privacy: .public)")
            lastTheme = theme
            onChange()
        }
    }

    private func appearanceChanged(dark: Bool) {
        defer { lastDark = dark }
        guard let lastDark, lastDark != dark else { return }
        appearanceLogger.info("appearance changed, dark: \(dark)")
        onChange()
    }
}
