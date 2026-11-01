import AppKit
import SwiftUI
import os.log

private let iconLogger = Logger(subsystem: "com.james.portside", category: "GroupIcon")

/// A custom icon for a group tile: an SF Symbol on a squircle in one of the
/// system colors, drawn to sit with the app icons around it. Nil on a group
/// means the default mini grid of member icons.
struct GroupIcon: Codable, Hashable {
    var symbol: String
    var color: GroupIconColor
    /// A color from Portside's palette (presets plus Saturation, Tint and
    /// Shade, like the Solid dock background). Overrides `color` when set.
    var custom: PaletteColor?

    static let defaultSymbol = "folder.fill"

    /// The color the artwork is drawn in (opaque).
    var nsColor: NSColor {
        guard let custom else { return color.nsColor }
        let c = custom.resolved
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

/// The standard macOS system colors. Stored by name so a saved dock.json
/// stays readable, and resolved through `NSColor.system*` so they follow
/// the system's light and dark variants.
enum GroupIconColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    /// An unknown name (edited by hand, or from a newer version) reads as
    /// blue rather than failing the whole dock.json decode.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GroupIconColor(rawValue: raw) ?? .blue
    }
}

// MARK: - Symbol catalog

/// Every SF Symbol name with its search keywords.
///
/// There is no public API that lists SF Symbols, so this reads the plists
/// that ship in CoreGlyphs.bundle (the same data the SF Symbols app
/// searches). They are undocumented: if they are missing or change shape,
/// the catalog falls back to `suggested`, and search matches names only.
final class SymbolCatalog {
    static let shared = SymbolCatalog()

    struct Symbol: Identifiable {
        let name: String
        /// Name words plus keywords, lowercased, for matching.
        let haystack: String
        var id: String { name }
    }

    /// Shown before the user searches. Picked to suit app groups.
    static let suggested = [
        "folder.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill", "sparkles",
        "hammer.fill", "wrench.and.screwdriver.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill",
        "paintbrush.pointed.fill", "paintpalette.fill", "pencil.and.ruler.fill", "camera.fill",
        "photo.fill", "film.fill", "music.note", "headphones", "gamecontroller.fill", "tv.fill",
        "message.fill", "bubble.left.and.bubble.right.fill", "envelope.fill", "phone.fill",
        "briefcase.fill", "doc.text.fill", "book.fill", "graduationcap.fill", "chart.bar.fill",
        "dollarsign.circle.fill", "cart.fill", "globe", "safari.fill", "cloud.fill",
        "gearshape.fill", "cpu.fill", "externaldrive.fill", "lock.fill", "key.fill",
        "house.fill", "leaf.fill", "airplane", "car.fill", "figure.run", "cup.and.saucer.fill",
        "calendar", "checklist", "square.grid.2x2.fill",
    ]

    /// Script and right-to-left variants (`character.ar`, `text.rtl`),
    /// which would crowd the results with near duplicates.
    private static let variantSuffixes: Set<String> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "km", "kn", "ko", "ml", "mni", "mr",
        "my", "or", "pa", "ru", "sat", "si", "ta", "te", "th", "zh", "rtl",
    ]

    private(set) lazy var symbols: [Symbol] = load()

    /// Symbols matching every word of `query`, in SF Symbols order.
    func search(_ query: String, limit: Int = 300) -> [String] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return Self.suggested }
        var found: [String] = []
        for symbol in symbols where words.allSatisfy({ symbol.haystack.contains($0) }) {
            found.append(symbol.name)
            if found.count == limit { break }
        }
        return found
    }

    private func load() -> [Symbol] {
        let started = CACurrentMediaTime()
        let base = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
        let order = NSArray(contentsOf: base.appendingPathComponent("symbol_order.plist")) as? [String]
        let keywords = NSDictionary(contentsOf: base.appendingPathComponent("symbol_search.plist")) as? [String: [String]] ?? [:]
        guard let order, !order.isEmpty else {
            iconLogger.error("SF Symbols catalog unavailable, searching the suggested symbols only")
            return Self.suggested.map { Symbol(name: $0, haystack: $0.replacingOccurrences(of: ".", with: " ")) }
        }
        let symbols = order.compactMap { name -> Symbol? in
            if let last = name.split(separator: ".").last, Self.variantSuffixes.contains(String(last)) { return nil }
            let words = [name.replacingOccurrences(of: ".", with: " ")] + (keywords[name] ?? [])
            return Symbol(name: name, haystack: words.joined(separator: " ").lowercased())
        }
        let ms = (CACurrentMediaTime() - started) * 1000
        iconLogger.info("SF Symbols catalog: \(symbols.count) symbols in \(ms, format: .fixed(precision: 1))ms")
        return symbols
    }
}

// MARK: - Appearance

/// Which system icon style the artwork imitates: System Settings >
/// Appearance > Icon and widget style (`AppleIconAppearanceTheme`, for
/// example "RegularDark" or "ClearAutomatic"). The Original icon style in
/// Portside's settings always uses the default colored look.
struct GroupIconAppearance {
    enum Variant { case regular, clear, tinted }

    var variant: Variant
    var dark: Bool

    static var current: GroupIconAppearance {
        guard IconCache.shared.style == .matchSystem else { return .init(variant: .regular, dark: false) }
        let theme = IconThemeObserver.currentTheme ?? ""
        let variant: Variant = theme.hasPrefix("Clear") ? .clear : theme.hasPrefix("Tinted") ? .tinted : .regular
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let dark = theme.hasSuffix("Dark") || (theme.hasSuffix("Automatic") && systemDark)
        return .init(variant: variant, dark: dark)
    }
}

// MARK: - Artwork

/// A group's custom icon at `size` (the visible squircle, without the app
/// icon margin). Mimics a macOS 26 app icon: continuous-corner squircle,
/// top-lit gradient, a thin light rim, and a centered glyph.
struct GroupIconArtwork: View {
    let icon: GroupIcon
    let size: CGFloat
    /// Redraws when the icon style or the system icon style changes.
    @ObservedObject private var icons = IconCache.shared

    init(icon: GroupIcon, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        let look = GroupIconAppearance.current
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        return shape
            .fill(background(look))
            // Sheen across the top, like the glass highlight on app icons.
            .overlay(
                shape.fill(LinearGradient(
                    colors: [Color.white.opacity(look.dark ? 0.04 : 0.22), .clear],
                    startPoint: .top, endPoint: .center))
            )
            .overlay(
                shape.strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(look.dark ? 0.22 : 0.5), Color.white.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom),
                    lineWidth: max(0.5, size * 0.014))
            )
            .overlay(glyph(look))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.22), radius: size * 0.03, y: size * 0.015)
            .accessibilityHidden(true)
    }

    private var tint: NSColor {
        GroupIconAppearance.current.variant == .tinted ? .controlAccentColor : icon.nsColor
    }

    private func background(_ look: GroupIconAppearance) -> LinearGradient {
        let colors: [Color]
        switch (look.variant, look.dark) {
        case (.clear, false):
            colors = [Color.white.opacity(0.5), Color.white.opacity(0.28)]
        case (.clear, true):
            colors = [Color.black.opacity(0.35), Color.black.opacity(0.5)]
        case (_, true):
            colors = [Color(white: 0.13), Color(white: 0.04)]
        case (_, false):
            colors = [Color(nsColor: Self.shade(tint, by: 0.18)), Color(nsColor: Self.shade(tint, by: -0.18))]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private func glyph(_ look: GroupIconAppearance) -> some View {
        let style: AnyShapeStyle
        switch (look.variant, look.dark) {
        case (.clear, _):
            style = AnyShapeStyle(Color.white.opacity(0.92))
        case (_, true):
            style = AnyShapeStyle(LinearGradient(
                colors: [Color(nsColor: Self.shade(tint, by: 0.2)), Color(nsColor: tint)],
                startPoint: .top, endPoint: .bottom))
        case (_, false):
            style = AnyShapeStyle(Color.white)
        }
        let name = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) == nil
            ? GroupIcon.defaultSymbol : icon.symbol
        return Image(systemName: name)
            .resizable()
            .fontWeight(.semibold)
            .symbolRenderingMode(.monochrome)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(style)
            .frame(width: size * 0.54, height: size * 0.5)
            .shadow(color: .black.opacity(look.variant == .clear ? 0.25 : 0.12), radius: size * 0.015, y: size * 0.01)
    }

    /// Lighter (positive) or darker (negative) version of `color`.
    private static func shade(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return amount >= 0
            ? rgb.blended(withFraction: amount, of: .white) ?? rgb
            : rgb.blended(withFraction: -amount, of: .black) ?? rgb
    }
}

// MARK: - Picker

/// Color swatches plus a searchable SF Symbols grid. Changes apply as soon
/// as they are picked; "Show Apps" goes back to the mini grid. The last
/// swatch opens Portside's palette editor (the Solid background's presets
/// and sliders) for any other color.
struct GroupIconPicker: View {
    let icon: GroupIcon?
    /// (new icon, persist). Slider drags send `false` until release.
    let onChange: (GroupIcon?, Bool) -> Void

    @State private var query = ""
    @State private var results = SymbolCatalog.suggested

    static let width: CGFloat = 300
    private static let cell: CGFloat = 34
    private static let swatch: CGFloat = 16

    private var color: GroupIconColor { icon?.color ?? .blue }
    private var current: GroupIcon { icon ?? GroupIcon(symbol: GroupIcon.defaultSymbol, color: .blue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            swatches
            if let custom = icon?.custom {
                PaletteColorEditor(color: custom, showsOpacity: false, labelWidth: 70, valueWidth: 40) { value, persist in
                    var next = current
                    next.custom = value
                    onChange(next, persist)
                }
            }
            HStack(spacing: 6) {
                TextField("Search symbols", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search symbols")
                Button("Show Apps") { onChange(nil, true) }
                    .disabled(icon == nil)
                    .help("Use the grid of app icons instead")
            }
            symbolGrid
        }
        .frame(width: Self.width)
        .onChange(of: query) { _, text in results = SymbolCatalog.shared.search(text) }
    }

    private var swatches: some View {
        // Equal-width cells spread the swatches across the picker's width.
        HStack(spacing: 0) {
            ForEach(GroupIconColor.allCases) { option in
                let selected = icon != nil && icon?.custom == nil && option == color
                swatch(Circle().fill(Color(nsColor: option.nsColor)), selected: selected, title: option.title) {
                    var next = current
                    next.color = option
                    next.custom = nil
                    onChange(next, true)
                }
            }
            // Custom: starts from the current color so the sliders adjust it.
            swatch(Circle().fill(AngularGradient(
                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)),
                   selected: icon?.custom != nil, title: "Custom") {
                guard icon?.custom == nil else { return }
                var next = current
                let c = current.color.nsColor.usingColorSpace(.sRGB) ?? .systemBlue
                next.custom = PaletteColor(base: RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1))
                onChange(next, true)
            }
        }
    }

    private func swatch(_ fill: some View, selected: Bool, title: String, action: @escaping () -> Void) -> some View {
        fill
            .frame(width: Self.swatch, height: Self.swatch)
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                    .padding(-3)
            )
            .frame(maxWidth: .infinity)
            .frame(height: Self.swatch + 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var symbolGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 8)
        let tint = Color(nsColor: current.nsColor)
        return ScrollView {
            if results.isEmpty {
                Text("No symbols match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(results, id: \.self) { name in
                    let selected = icon?.symbol == name
                    Image(systemName: name)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.cell)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? tint.opacity(0.35) : Color.primary.opacity(0.0001))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            var next = current
                            next.symbol = name
                            onChange(next, true)
                        }
                        .help(name)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .frame(width: Self.width, height: 170)
    }
}
