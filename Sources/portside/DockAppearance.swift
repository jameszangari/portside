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

/// The dock's background. Each style keeps its own settings (see
/// `DockBackground`), so switching back and forth loses nothing.
enum DockBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    /// The system Liquid Glass, exactly like the native Dock.
    case glass
    /// A blur material with its own thickness, strength, tint, and border.
    case frosted
    /// A color or gradient the user picks, with opacity.
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
struct RGBAColor: Codable, Hashable {
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

/// A color picked from Portside's palette: a preset (or hex) base adjusted
/// with hue, saturation, tint (toward white), shade (toward black), and
/// opacity. One model for every color in Portside (dock background, tints,
/// badges, group icons), edited with `PaletteColorEditor`.
/// Stored as those parts so the editor reopens where the user left it.
/// Also reads a plain `RGBAColor` (older dock.json) as base plus opacity.
struct PaletteColor: Codable, Hashable {
    /// Alpha ignored; `opacity` is the alpha.
    var base: RGBAColor
    /// 0 to 1, a turn around the color wheel from the base's hue.
    var hue: Double = 0
    /// 0 to 1, a multiplier on the base's saturation.
    var saturation: Double = 1
    /// 0 to 1, mix toward white.
    var tint: Double = 0
    /// 0 to 1, mix toward black.
    var shade: Double = 0
    var opacity: Double = 1

    init(base: RGBAColor, hue: Double = 0, saturation: Double = 1, tint: Double = 0, shade: Double = 0, opacity: Double = 1) {
        self.base = RGBAColor(red: base.red, green: base.green, blue: base.blue, alpha: 1)
        self.hue = hue
        self.saturation = saturation
        self.tint = tint
        self.shade = shade
        self.opacity = opacity
    }

    /// A legacy color: its alpha becomes the opacity.
    init(_ rgba: RGBAColor) {
        self.init(base: rgba, opacity: rgba.alpha)
    }

    private enum CodingKeys: String, CodingKey { case base, hue, saturation, tint, shade, opacity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let base = try? c.decode(RGBAColor.self, forKey: .base) else {
            self.init(try RGBAColor(from: decoder))
            return
        }
        self.init(
            base: base,
            hue: unit(c.value(.hue, or: 0.0)),
            saturation: unit(c.value(.saturation, or: 1.0)),
            tint: unit(c.value(.tint, or: 0.0)),
            shade: unit(c.value(.shade, or: 0.0)),
            opacity: unit(c.value(.opacity, or: 1.0))
        )
    }

    /// The final color, with `opacity` as alpha.
    var resolved: RGBAColor {
        var r = base.red, g = base.green, b = base.blue
        if hue > 0, hue < 1 {
            (r, g, b) = Self.rotateHue(r, g, b, by: hue)
        }
        if saturation < 1 {
            // Toward the color's own luminance (gray of the same lightness).
            let gray = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = gray + (r - gray) * saturation
            g = gray + (g - gray) * saturation
            b = gray + (b - gray) * saturation
        }
        r += (1 - r) * tint; g += (1 - g) * tint; b += (1 - b) * tint
        r *= 1 - shade; g *= 1 - shade; b *= 1 - shade
        return RGBAColor(red: r, green: g, blue: b, alpha: opacity)
    }

    /// True when any slider other than opacity moved off its default.
    var isAdjusted: Bool { hue != 0 || saturation != 1 || tint != 0 || shade != 0 }

    /// Same base and opacity, adjustments back to their defaults.
    var unadjusted: PaletteColor { PaletteColor(base: base, opacity: opacity) }

    /// Rotates hue in HSB, keeping saturation and brightness.
    private static func rotateHue(_ r: Double, _ g: Double, _ b: Double, by turn: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0.0001 else { return (r, g, b) }
        var h: Double
        if maxC == r { h = (g - b) / delta } else if maxC == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
        h = (h / 6 + turn).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let sat = delta / maxC, v = maxC
        let sector = h * 6, i = floor(sector), f = sector - i
        let p = v * (1 - sat), q = v * (1 - sat * f), t = v * (1 - sat * (1 - f))
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    var color: Color { resolved.color }
    /// Same color, fully opaque (glass tints, badge fills).
    var opaqueColor: Color { resolved.withAlpha(1).color }

    /// Brand navy (design/brand tokens).
    static let brandNavy = PaletteColor(base: RGBAColor(red: 0x10 / 255, green: 0x28 / 255, blue: 0x3F / 255, alpha: 1))

    typealias Preset = (name: String, color: RGBAColor)

    /// The editor's swatches, in labeled sections, in display order.
    static let presetSections: [(title: String, presets: [Preset])] = [
        ("Brand", [
            ("Portside Navy", rgb(0x10, 0x28, 0x3F)),
            ("Portside Orange", rgb(0xF0, 0x6A, 0x42)),
        ]),
        ("Neutrals", [
            ("White", RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)),
            ("Silver", RGBAColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1)),
            ("Gray", RGBAColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1)),
            ("Graphite", RGBAColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1)),
            ("Charcoal", RGBAColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)),
            ("Black", RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)),
        ]),
        // The macOS system colors (light variants).
        ("macOS", [
            ("Red", RGBAColor(red: 0.92, green: 0.22, blue: 0.18, alpha: 1)),
            ("Orange", RGBAColor(red: 1, green: 0.58, blue: 0, alpha: 1)),
            ("Yellow", RGBAColor(red: 1, green: 0.80, blue: 0, alpha: 1)),
            ("Green", RGBAColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
            ("Mint", RGBAColor(red: 0, green: 0.78, blue: 0.75, alpha: 1)),
            ("Teal", RGBAColor(red: 0.19, green: 0.69, blue: 0.78, alpha: 1)),
            ("Cyan", RGBAColor(red: 0.20, green: 0.68, blue: 0.90, alpha: 1)),
            ("Blue", RGBAColor(red: 0, green: 0.48, blue: 1, alpha: 1)),
            ("Indigo", RGBAColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1)),
            ("Purple", RGBAColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
            ("Pink", RGBAColor(red: 1, green: 0.18, blue: 0.33, alpha: 1)),
            ("Brown", RGBAColor(red: 0.64, green: 0.52, blue: 0.37, alpha: 1)),
        ]),
        // The 12-step RGB color wheel: primaries, secondaries, tertiaries.
        ("RGB", [
            ("RGB Red", rgb(0xFF, 0x00, 0x00)),
            ("RGB Orange", rgb(0xFF, 0x80, 0x00)),
            ("RGB Yellow", rgb(0xFF, 0xFF, 0x00)),
            ("RGB Chartreuse", rgb(0x80, 0xFF, 0x00)),
            ("RGB Green", rgb(0x00, 0xFF, 0x00)),
            ("RGB Spring Green", rgb(0x00, 0xFF, 0x80)),
            ("RGB Cyan", rgb(0x00, 0xFF, 0xFF)),
            ("RGB Azure", rgb(0x00, 0x80, 0xFF)),
            ("RGB Blue", rgb(0x00, 0x00, 0xFF)),
            ("RGB Violet", rgb(0x80, 0x00, 0xFF)),
            ("RGB Magenta", rgb(0xFF, 0x00, 0xFF)),
            ("RGB Rose", rgb(0xFF, 0x00, 0x80)),
        ]),
    ]

    /// Every swatch, flattened (lookups by name).
    static let presets: [Preset] = presetSections.flatMap(\.presets)

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> RGBAColor {
        RGBAColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
    }
}

extension RGBAColor {
    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// "#RRGGBB" (alpha ignored).
    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Parses "#RGB" or "#RRGGBB" (the # is optional). Alpha is 1.
    init?(hex text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, alpha: 1)
    }

    /// Same RGB within rounding (dock.json round trips, preset matching).
    func sameRGB(as other: RGBAColor) -> Bool {
        abs(red - other.red) < 0.002 && abs(green - other.green) < 0.002 && abs(blue - other.blue) < 0.002
    }
}

extension KeyedDecodingContainer {
    /// Missing or unreadable keys fall back to a default, so a dock.json from
    /// an older (or newer) build never fails to load.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

private func unit(_ value: Double) -> Double { min(max(value, 0), 1) }

/// The two system glass variants (System Settings > Appearance > Liquid
/// Glass offers the same pair).
enum GlassVariant: String, Codable, CaseIterable, Identifiable {
    case regular, clear

    var id: String { rawValue }
    var title: String { self == .regular ? "Regular" : "Clear" }
}

/// SwiftUI's blur materials, thinnest to thickest.
enum FrostMaterial: String, Codable, CaseIterable, Identifiable {
    case ultraThin, thin, regular, thick, ultraThick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraThin: "Ultra Thin"
        case .thin: "Thin"
        case .regular: "Regular"
        case .thick: "Thick"
        case .ultraThick: "Ultra Thick"
        }
    }

    var material: Material {
        switch self {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        case .ultraThick: .ultraThickMaterial
        }
    }
}

/// How a solid background is filled.
enum SolidFill: String, Codable, CaseIterable, Identifiable {
    case color, linear, radial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: "Color"
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        }
    }

    var isGradient: Bool { self != .color }
}

/// Native Liquid Glass. Nothing is layered on it: strength and tint go into
/// the glass itself, so it keeps the system highlights and refraction.
struct GlassBackground: Codable, Equatable {
    var variant: GlassVariant = .regular
    /// 0 to 1. How strongly the glass is tinted (neutral, or `tint`). 0 is
    /// the plain system glass.
    var strength: Double = 0
    /// Tint color, used opaque. The strength sets how much of it shows.
    var tint: PaletteColor?
    /// The last tint while Tint is off, so turning it back on restores it.
    var savedTint: PaletteColor?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = c.value(.variant, or: GlassVariant.regular)
        strength = unit(c.value(.strength, or: 0.0))
        tint = c.value(.tint, or: PaletteColor?.none)
        savedTint = c.value(.savedTint, or: PaletteColor?.none)
    }
}

/// A blur material with full control over it.
struct FrostedBackground: Codable, Equatable {
    var material: FrostMaterial = .thin
    /// 0 to 1. The material's opacity.
    var strength: Double = 0.8
    /// Color laid over the material; its opacity sets how strong it is.
    var tint: PaletteColor?
    /// The last tint while Tint is off, so turning it back on restores it.
    var savedTint: PaletteColor?
    var border: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        material = c.value(.material, or: FrostMaterial.thin)
        strength = unit(c.value(.strength, or: 0.8))
        tint = c.value(.tint, or: PaletteColor?.none)
        savedTint = c.value(.savedTint, or: PaletteColor?.none)
        border = c.value(.border, or: true)
    }
}

/// A user-picked color or gradient.
struct SolidBackground: Codable, Equatable {
    var fill: SolidFill = .color
    var color = PaletteColor(base: RGBAColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
    /// Second gradient stop (outer stop for radial).
    var endColor = PaletteColor.brandNavy
    /// Linear gradient direction in degrees: 0 runs left to right, 90 top
    /// to bottom.
    var angle: Double = 90
    /// 0 to 1, applied on top of each color's own alpha.
    var opacity: Double = 0.85
    var border: Bool = true

    static let angleRange: ClosedRange<Double> = 0...359

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fill = c.value(.fill, or: SolidFill.color)
        color = c.value(.color, or: SolidBackground().color)
        endColor = c.value(.endColor, or: SolidBackground().endColor)
        angle = min(max(c.value(.angle, or: 90.0), Self.angleRange.lowerBound), Self.angleRange.upperBound)
        opacity = unit(c.value(.opacity, or: 0.85))
        border = c.value(.border, or: true)
    }

    /// Start and end points for `angle`, inside the unit square.
    var gradientPoints: (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// The selected style plus every style's settings, stored in dock.json as
/// `background`.
struct DockBackground: Codable, Equatable {
    var style: DockBackgroundStyle = .systemDefault
    var glass = GlassBackground()
    var frosted = FrostedBackground()
    var solid = SolidBackground()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, or: DockBackgroundStyle.systemDefault)
        glass = c.value(.glass, or: GlassBackground())
        frosted = c.value(.frosted, or: FrostedBackground())
        solid = c.value(.solid, or: SolidBackground())
    }

    /// Settings from builds before per-style backgrounds (one shared
    /// `backgroundFrost` and `backgroundTint`).
    init(legacyStyle: DockBackgroundStyle, frost: Double, tint: RGBAColor?) {
        style = legacyStyle
        frosted.strength = unit(0.3 + 0.7 * frost)
        frosted.tint = tint.map(PaletteColor.init)
        solid.opacity = unit(0.4 + 0.6 * frost)
        if let tint {
            glass.tint = PaletteColor(base: tint)
            glass.strength = unit(tint.alpha)
        }
    }
}

/// Everything about the dock's look, applied to the strip and to open
/// group grids. Equatable so SwiftUI skips redraws when nothing changed.
struct DockLook: Equatable {
    var background = DockBackground()
    var cornerRadius: CGFloat
    /// Snapshot of System Settings > Accessibility > Display > Reduce
    /// Transparency, so the strip redraws when that option flips.
    var reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    /// Style after Reduce Transparency: glass becomes frosted (native Dock
    /// also drops translucency when that Accessibility option is on).
    var displayStyle: DockBackgroundStyle {
        let base = background.style.effective
        if reduceTransparency && base == .glass { return .frosted }
        return base
    }

    /// Reduce Transparency keeps every style at least mostly opaque.
    func opaque(_ value: Double) -> Double {
        reduceTransparency ? max(value, 0.92) : value
    }

    /// Light or dark content (text, running dots) that stays readable on
    /// this background: a white solid dock gets black text, a dark tint
    /// gets white. Estimated from the colors the user picked, laid over a
    /// backdrop of the system's light or dark gray (what materials and
    /// glass show without a color). Picks whichever of black or white text
    /// has the higher WCAG contrast.
    var contentScheme: ColorScheme {
        let darkMode = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let backdrop = darkMode ? 0.12 : 0.88
        let luminance: Double
        switch displayStyle {
        case .solid:
            let solid = background.solid
            let stops = solid.fill.isGradient ? [solid.color, solid.endColor] : [solid.color]
            luminance = stops.map { stop in
                let rgba = stop.resolved
                return Self.over(rgba, alpha: rgba.alpha * opaque(solid.opacity), backdrop: backdrop)
            }.reduce(0, +) / Double(stops.count)
        case .frosted:
            let tint = background.style.effective == .glass
                ? background.glass.tint.map { ($0.resolved, background.glass.strength) }
                : background.frosted.tint.map { ($0.resolved, $0.resolved.alpha) }
            luminance = tint.map { Self.over($0.0, alpha: $0.1, backdrop: backdrop) } ?? Self.linear(backdrop)
        case .glass:
            let glass = background.glass
            luminance = glass.tint.map { Self.over($0.resolved, alpha: glass.strength, backdrop: backdrop) }
                ?? Self.linear(backdrop)
        }
        // Equal contrast point between black and white text.
        return luminance > 0.179 ? .light : .dark
    }

    /// Relative luminance of `color` at `alpha` over a gray `backdrop`.
    private static func over(_ color: RGBAColor, alpha: Double, backdrop: Double) -> Double {
        let a = min(max(alpha, 0), 1)
        func mix(_ c: Double) -> Double { linear(c * a + backdrop * (1 - a)) }
        return 0.2126 * mix(color.red) + 0.7152 * mix(color.green) + 0.0722 * mix(color.blue)
    }

    /// sRGB component to linear light.
    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

extension View {
    /// Content drawn on the dock background (text, dots) uses the scheme
    /// that reads on it. Set on the content only, so the background itself
    /// keeps the system appearance.
    func dockContentScheme(_ look: DockLook) -> some View {
        environment(\.colorScheme, look.contentScheme)
    }

    /// The dock background in `look`, clipped to its rounded rectangle.
    /// `shadow` is for floating surfaces (group grids); glass draws its own.
    func dockBackground(_ look: DockLook, shadow: Bool = false) -> some View {
        dockContentScheme(look).modifier(DockBackgroundModifier(
            look: look, shape: RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous),
            roundedRadius: look.cornerRadius, shadow: shadow
        ))
    }

    /// The same background in another shape (the hover label's bubble), so
    /// it always matches the dock. Clear glass uses the public (blurred)
    /// variant here, since the see-through one only does rounded rects.
    func dockBackground<S: InsettableShape>(_ look: DockLook, in shape: S, shadow: Bool = false) -> some View {
        dockContentScheme(look).modifier(DockBackgroundModifier(look: look, shape: shape, roundedRadius: nil, shadow: shadow))
    }
}

private struct DockBackgroundModifier<S: InsettableShape>: ViewModifier {
    let look: DockLook
    let shape: S
    /// Set when `shape` is a plain rounded rectangle of this radius.
    let roundedRadius: CGFloat?
    let shadow: Bool

    func body(content: Content) -> some View {
        switch look.displayStyle {
        case .glass:
            if #available(macOS 26, *) {
                let settings = look.background.glass
                if settings.variant == .clear, let roundedRadius, SeeThroughGlass.isAvailable {
                    // See-through lens glass. It ignores tint colors, so
                    // strength is a fill underneath (the glass refracts it).
                    content.background {
                        ZStack {
                            shape.fill(glassShade.opacity(settings.strength))
                            SeeThroughGlassView(cornerRadius: roundedRadius)
                        }
                    }
                } else {
                    // `id` rebuilds the effect when the variant flips, so the
                    // old glass never lingers.
                    content.glassEffect(glass, in: shape).id(settings.variant)
                }
            } else {
                frosted(content, look.background.frosted)
            }
        case .frosted:
            if look.background.style.effective == .glass {
                // Glass under Reduce Transparency: the system's own fallback
                // look, a regular material with the glass tint.
                frosted(content, glassFallbackFrosted)
            } else {
                frosted(content, look.background.frosted)
            }
        case .solid:
            solid(content, look.background.solid)
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        let settings = look.background.glass
        let base: Glass = settings.variant == .clear ? .clear : .regular
        guard settings.strength > 0 else { return base }
        return base.tint(glassShade.opacity(settings.strength))
    }

    /// Tint color, or the window background for a neutral shade that reads
    /// as a denser pane in both light and dark mode.
    private var glassShade: Color {
        look.background.glass.tint?.opaqueColor ?? Color(nsColor: .windowBackgroundColor)
    }

    /// Frosted stand-in when Liquid Glass is reduced to a material.
    private var glassFallbackFrosted: FrostedBackground {
        var fallback = FrostedBackground()
        fallback.material = .regular
        fallback.tint = look.background.glass.tint.map {
            var tint = $0
            tint.opacity = look.background.glass.strength
            return tint
        }
        return fallback
    }

    private func frosted(_ content: Content, _ settings: FrostedBackground) -> some View {
        content
            .background {
                shape.fill(settings.material.material).opacity(look.opaque(settings.strength))
                    .overlay { if let tint = settings.tint { shape.fill(tint.color) } }
                    .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: 12, y: 5)
            }
            .overlay { if settings.border { shape.strokeBorder(.white.opacity(0.15), lineWidth: 1) } }
    }

    private func solid(_ content: Content, _ settings: SolidBackground) -> some View {
        content
            .background {
                shape.fill(solidFill(settings)).opacity(look.opaque(settings.opacity))
                    .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: 12, y: 5)
            }
            .overlay { if settings.border { shape.strokeBorder(.white.opacity(0.15), lineWidth: 1) } }
    }

    private func solidFill(_ settings: SolidBackground) -> AnyShapeStyle {
        let colors = [settings.color.color, settings.endColor.color]
        switch settings.fill {
        case .color:
            return AnyShapeStyle(settings.color.color)
        case .linear:
            let points = settings.gradientPoints
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: points.start, endPoint: points.end))
        case .radial:
            return AnyShapeStyle(EllipticalGradient(colors: colors, center: .center))
        }
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
