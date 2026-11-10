import AppKit
import SwiftUI

/// Portside's one color picker, used everywhere a color is chosen (dock
/// background and tints, badges, group icons): a preview with a hex field,
/// preset swatches, and Hue, Saturation, Tint, Shade and (optionally)
/// Opacity sliders. Inline, so it never needs the system color panel (which
/// a non-activating app handles badly).
///
/// React analogy: a controlled component. `color` is the value, `set` is
/// onChange with a second "commit" flag (false while a slider is dragging).
struct PaletteColorEditor: View {
    let color: PaletteColor
    var showsOpacity = true
    var opacityTitle = "Opacity"
    /// Smaller swatches and narrower slider columns, so the whole editor
    /// fits a 300pt popover without scrolling (the group icon picker).
    var compact = false
    /// (new color, persist)
    let set: (PaletteColor, Bool) -> Void

    private var swatch: CGFloat { compact ? 16 : 22 }
    private var gap: CGFloat { compact ? 2.5 : 8 }
    private var labelWidth: CGFloat { compact ? 70 : SettingsLayout.labelWidth }
    private var valueWidth: CGFloat { compact ? 40 : SettingsLayout.valueWidth }

    /// Swatch sections per row: Brand and Neutrals share the first row,
    /// macOS and RGB (12 each) get a row apiece. Every swatch is visible at
    /// once, nothing scrolls.
    private static let rows: [[Int]] = [[0, 1], [2], [3]]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Self.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: gap * 4 + 6) {
                    ForEach(row, id: \.self) { index in
                        swatchSection(PaletteColor.presetSections[index])
                    }
                }
            }
            slider("Hue", \.hue, format: { "\(Int(($0 * 360).rounded()))°" })
            slider("Saturation", \.saturation)
            slider("Tint", \.tint)
            slider("Shade", \.shade)
            if showsOpacity {
                slider(opacityTitle, \.opacity)
            }
        }
        .padding(.vertical, 2)
    }

    private func swatchSection(_ section: (title: String, presets: [PaletteColor.Preset])) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: gap) {
                ForEach(section.presets, id: \.name) { preset in
                    ColorChip(color: preset.color.color, size: swatch, isSelected: color.base.sameRGB(as: preset.color)) {
                        var next = color
                        next.base = preset.color.withAlpha(1)
                        set(next, true)
                    }
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                }
            }
        }
    }

    /// The result, its hex value (editable), and a reset for the sliders.
    private var header: some View {
        HStack(spacing: 8) {
            ColorChip(color: color.color, size: 22)
                .accessibilityLabel("Current color")
            HexField(color: color) { base in
                // A typed color is exact: adjustments start over.
                set(PaletteColor(base: base, opacity: color.opacity), true)
            }
            Spacer(minLength: 0)
            Button("Reset Adjustments") { set(color.unadjusted, true) }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(!color.isAdjusted)
                .help("Hue, Saturation, Tint and Shade back to the swatch's own color")
        }
    }

    private func slider(_ title: String, _ path: WritableKeyPath<PaletteColor, Double>,
                        format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }) -> SettingsSlider {
        SettingsSlider(
            title: title,
            value: color[keyPath: path],
            range: 0...1,
            snap: path == \PaletteColor.hue ? 1.0 / 360 : 0.01,
            format: format,
            labelWidth: labelWidth,
            valueWidth: valueWidth,
            set: { value, persist in
                var next = color
                next[keyPath: path] = value
                set(next, persist)
            }
        )
    }
}

/// "#RRGGBB" of the resolved color. Return (or leaving the field) applies a
/// typed value as the new base; anything unparsable reverts.
private struct HexField: View {
    let color: PaletteColor
    let apply: (RGBAColor) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Hex", text: $draft, prompt: Text(SettingsTextField.Kind.code.hint))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: 84)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { draft = color.resolved.hex }
            .onChange(of: color) { _, new in if !focused { draft = new.resolved.hex } }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .accessibilityLabel("Hex color")
            .help("Type a hex color, for example #1E90FF")
    }

    private func commit() {
        if let parsed = RGBAColor(hex: draft), !parsed.sameRGB(as: color.resolved) {
            apply(parsed)
        }
        draft = color.resolved.hex
    }
}

/// A round color sample over a checkerboard (so opacity shows). With an
/// action it is a button; `isSelected` draws a ring.
struct ColorChip: View {
    let color: Color
    var size: CGFloat = 22
    var isSelected = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
        } else {
            chip
        }
    }

    private var chip: some View {
        ZStack {
            Checkerboard().clipShape(Circle())
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
        .padding(3)
        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        .contentShape(Circle())
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 4
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) where (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.8)))
                }
            }
        }
    }
}
