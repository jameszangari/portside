import AppKit
import SwiftUI
import os.log

private let iconLogger = Logger(subsystem: "com.james.portside", category: "GroupIcon")

/// A custom icon for a group tile: an SF Symbol on a squircle in a
/// palette color, drawn to sit with the app icons around it. Nil on a group
/// means the default mini grid of member icons.
struct GroupIcon: Codable, Hashable {
    var symbol: String
    /// Same color model and editor as the dock background. Opacity is
    /// ignored: icons are opaque.
    var color: PaletteColor
    /// System follows the macOS icon style; Light and Dark pin this icon.
    var theme: GroupIconTheme = .system

    static let defaultSymbol = "folder.fill"
    static let defaultColor = PaletteColor.preset("Blue")

    init(symbol: String = GroupIcon.defaultSymbol, color: PaletteColor = GroupIcon.defaultColor, theme: GroupIconTheme = .system) {
        self.symbol = symbol
        self.color = color
        self.theme = theme
    }

    /// The look this icon is drawn with.
    var appearance: GroupIconAppearance {
        switch theme {
        case .system: .current
        case .light: .init(variant: .regular, dark: false)
        case .dark: .init(variant: .regular, dark: true)
        }
    }

    /// The color the artwork is drawn in (opaque).
    var nsColor: NSColor {
        let c = color.resolved
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    private enum CodingKeys: String, CodingKey { case symbol, color, custom, theme }

    /// Earlier builds stored `color` as a system color name ("blue") plus an
    /// optional `custom` palette color. Both read into the palette color.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = c.value(.symbol, or: Self.defaultSymbol)
        theme = c.value(.theme, or: .system)
        if let custom = try? c.decode(PaletteColor.self, forKey: .custom) {
            color = custom
        } else if let palette = try? c.decode(PaletteColor.self, forKey: .color) {
            color = palette
        } else if let name = try? c.decode(String.self, forKey: .color) {
            color = PaletteColor.preset(name.capitalized)
        } else {
            color = Self.defaultColor
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(color, forKey: .color)
        if theme != .system { try c.encode(theme, forKey: .theme) }
    }
}

/// Per-icon override of the system icon style.
enum GroupIconTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// An unknown value (newer build, hand edit) reads as System.
    init(from decoder: Decoder) throws {
        self = GroupIconTheme(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
    }
}

extension PaletteColor {
    /// A preset by name ("Blue"); Blue if there is none by that name.
    static func preset(_ name: String) -> PaletteColor {
        let rgba = presets.first { $0.name == name }?.color ?? presets.first { $0.name == "Blue" }!.color
        return PaletteColor(base: rgba)
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
        let look = icon.appearance
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
        icon.appearance.variant == .tinted ? .controlAccentColor : icon.nsColor
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

/// Symbol and Color tabs under a live preview. Changes apply as soon as
/// they are picked; "Remove Icon" goes back to the mini grid. The Color tab
/// is the same `PaletteColorEditor` as the dock background.
struct GroupIconPicker: View {
    let icon: GroupIcon?
    /// (new icon, persist). Slider drags send `false` until release.
    let onChange: (GroupIcon?, Bool) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case symbol = "Symbol", color = "Color"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .symbol
    @State private var query = ""
    @State private var results = SymbolCatalog.suggested

    static let width: CGFloat = 300
    private static let cell: CGFloat = 34
    /// Both tabs take this height, so switching never resizes the popover.
    private static let contentHeight: CGFloat = 312

    private var current: GroupIcon { icon ?? GroupIcon() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                preview
                Picker("Edit", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(role: .destructive) { onChange(nil, true) } label: {
                    Label("Remove Icon", systemImage: "xmark.circle")
                }
                    .controlSize(.small)
                    .disabled(icon == nil)
                    .help("Remove the custom icon. The tile shows the group's apps again.")
            }
            HStack(spacing: 10) {
                Text("Style")
                    .foregroundStyle(.secondary)
                Picker("Style", selection: Binding(
                    get: { current.theme },
                    set: { theme in
                        var next = current
                        next.theme = theme
                        onChange(next, true)
                    }
                )) {
                    ForEach(GroupIconTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("System follows System Settings > Appearance > Icon and widget style")
            }
            Group {
                switch tab {
                case .symbol: symbolTab
                case .color:
                    PaletteColorEditor(color: current.color, showsOpacity: false, compact: true) { value, persist in
                        var next = current
                        next.color = value
                        onChange(next, persist)
                    }
                }
            }
            .frame(width: Self.width, height: Self.contentHeight, alignment: .top)
        }
        .frame(width: Self.width)
        .onChange(of: query) { _, text in results = SymbolCatalog.shared.search(text) }
    }

    /// The tile as it will look, or the default grid hint when unset.
    @ViewBuilder private var preview: some View {
        if let icon {
            GroupIconArtwork(icon: icon, size: 32)
        } else {
            RoundedRectangle(cornerRadius: 32 * 0.225, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .overlay(Image(systemName: "square.grid.2x2").foregroundStyle(.secondary))
                .frame(width: 32, height: 32)
                .help("Showing the apps. Pick a symbol or color for a custom icon.")
        }
    }

    private var symbolTab: some View {
        VStack(spacing: 8) {
            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search symbols")
            symbolGrid
        }
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
    }
}
