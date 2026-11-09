import SwiftUI

// Reusable "see what this setting does" illustrations for Settings. Every
// preview is a pure SwiftUI drawing of the current setting value: it reads no
// system state and changes none. Nothing plays by itself; a preview only
// moves when its button is pressed, and Reduce Motion turns the movement off.

// MARK: - Container

/// Frame for a preview: a "Simulation" badge so it is never mistaken for live
/// system state, an optional action button, and an expand button that shows
/// the same drawing larger in a popover. React analogy: a card component
/// that takes its body as children.
struct SettingsPreviewCard<Content: View>: View {
    let title: String
    /// One line of what the picture shows. Also the VoiceOver description.
    let summary: String
    /// Optional control row (for example "Hover the edge").
    var actions: AnyView?
    @ViewBuilder var content: () -> Content

    @State private var expanded = false

    init(title: String, summary: String, actions: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.summary = summary
        self.actions = actions
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text("Simulation")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                    .accessibilityLabel("Simulation, not live")
                Spacer()
                if let actions { actions }
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Enlarge preview")
                .accessibilityLabel("Enlarge preview")
                .popover(isPresented: $expanded, arrowEdge: .bottom) {
                    content()
                        .frame(width: 460, height: 290)
                        .padding(12)
                }
            }
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
        }
        .padding(.vertical, 4)
    }
}

/// Backdrop for a simulated desktop. Flat when Reduce Transparency is on.
struct PreviewDesktop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency {
            Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
        } else {
            LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.purple.opacity(0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}

/// Animation for a preview state change, or none under Reduce Motion.
private func previewAnimation(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.35)
}

/// Small push-button style used inside the preview header.
private struct PreviewButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .controlSize(.small)
    }
}

// MARK: - Dock

/// Where the dock sits and what auto-hide and "keep windows clear" do to a
/// window. Auto-hide starts hidden; the button simulates the pointer touching
/// the edge.
struct DockPlacementPreview: View {
    let edge: DockEdge
    let autoHide: Bool
    let reserveSpace: Bool
    let showTrash: Bool
    /// Pointer at the screen edge. Owned by the card's button.
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dockVisible: Bool { !autoHide || revealed }
    private var windowAvoidsDock: Bool { !autoHide && reserveSpace }

    var body: some View {
        GeometryReader { geo in
            let thickness = max(14, min(geo.size.width, geo.size.height) * 0.16)
            let vertical = edge.isVertical
            ZStack {
                PreviewDesktop()
                // A window. Stops at the dock when windows keep clear of it.
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background)
                    .overlay(alignment: .top) {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in Circle().fill(.quaternary).frame(width: 5, height: 5) }
                            Spacer()
                        }.padding(5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    .padding(EdgeInsets(
                        top: 8,
                        leading: 8 + (windowAvoidsDock && edge == .left ? thickness + 6 : 0),
                        bottom: windowAvoidsDock && edge == .bottom ? thickness + 8 : 0,
                        trailing: 8 + (windowAvoidsDock && edge == .right ? thickness + 6 : 0)
                    ))
                dock(thickness: thickness, vertical: vertical, size: geo.size)
                if autoHide && !revealed {
                    edgeGlow(thickness: thickness, size: geo.size)
                }
            }
            .animation(previewAnimation(reduceMotion), value: edge)
            .animation(previewAnimation(reduceMotion), value: dockVisible)
            .animation(previewAnimation(reduceMotion), value: windowAvoidsDock)
        }
    }

    private func dock(thickness: CGFloat, vertical: Bool, size: CGSize) -> some View {
        let count = showTrash ? 5 : 4
        let tile = thickness - 6
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        let offscreen = thickness + 12
        let shift: CGSize = dockVisible ? .zero : {
            switch edge {
            case .bottom: CGSize(width: 0, height: offscreen)
            case .left: CGSize(width: -offscreen, height: 0)
            case .right: CGSize(width: offscreen, height: 0)
            }
        }()
        return layout {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index == count - 1 && showTrash ? Color.secondary.opacity(0.7) : tileColor(index))
                    .frame(width: tile, height: tile)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .offset(shift)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edgeAlignment)
        .padding(4)
    }

    /// Thin accent line on the screen edge while the dock is tucked away.
    private func edgeGlow(thickness: CGFloat, size: CGSize) -> some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.8))
            .frame(width: edge.isVertical ? 2 : size.width * 0.4, height: edge.isVertical ? size.height * 0.4 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edgeAlignment)
    }

    private var edgeAlignment: Alignment {
        switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private func tileColor(_ index: Int) -> Color {
        [Color.blue, .orange, .green, .pink, .teal][index % 5].opacity(0.85)
    }
}

/// Card wrapper for the dock preview with the "touch the edge" button.
struct DockPlacementPreviewCard: View {
    let edge: DockEdge
    let autoHide: Bool
    let reserveSpace: Bool
    let showTrash: Bool
    @State private var revealed = false

    var body: some View {
        SettingsPreviewCard(
            title: "Dock preview",
            summary: summary,
            actions: autoHide
                ? AnyView(PreviewButton(title: revealed ? "Move pointer away" : "Touch the edge") { revealed.toggle() })
                : nil
        ) {
            DockPlacementPreview(edge: edge, autoHide: autoHide, reserveSpace: reserveSpace, showTrash: showTrash, revealed: revealed)
        }
        .onChange(of: autoHide) { _ in revealed = false }
    }

    private var summary: String {
        let side = edge.title.lowercased()
        if autoHide { return "Dock on the \(side) edge, hidden until the pointer touches the edge." }
        if reserveSpace { return "Dock on the \(side) edge. Windows stop at the dock." }
        return "Dock on the \(side) edge. Windows can extend under the dock."
    }
}

// MARK: - App Switcher

/// What the switcher lists and how Tab moves through it.
struct SwitcherPreview: View {
    let mode: SwitcherMode
    let previews: Bool
    let selected: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let apps: [(name: String, symbol: String, color: Color)] = [
        ("Browser", "safari", .blue),
        ("Editor", "chevron.left.forwardslash.chevron.right", .orange),
        ("Terminal", "terminal", .gray),
        ("Notes", "note.text", .yellow),
    ]
    /// Window mode lists two windows of one app side by side.
    private static let windows: [(app: Int, title: String)] = [
        (0, "Page one"), (0, "Page two"), (1, "main.swift"), (2, "Shell"),
    ]

    var body: some View {
        ZStack {
            PreviewDesktop()
            HStack(spacing: 8) {
                switch mode {
                case .apps:
                    ForEach(Array(Self.apps.enumerated()), id: \.offset) { index, app in
                        tile(selected: index == selected) {
                            Image(systemName: app.symbol).font(.system(size: 20)).foregroundStyle(app.color)
                        } label: { app.name }
                    }
                case .windows:
                    ForEach(Array(Self.windows.enumerated()), id: \.offset) { index, window in
                        tile(selected: index == selected) {
                            if previews {
                                windowThumbnail(color: Self.apps[window.app].color)
                            } else {
                                Image(systemName: Self.apps[window.app].symbol).font(.system(size: 20)).foregroundStyle(Self.apps[window.app].color)
                            }
                        } label: { window.title }
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .animation(previewAnimation(reduceMotion), value: selected)
            .animation(previewAnimation(reduceMotion), value: mode)
        }
    }

    private func tile<Icon: View>(selected: Bool, @ViewBuilder icon: () -> Icon, label: () -> String) -> some View {
        VStack(spacing: 4) {
            icon()
                .frame(width: 52, height: 40)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Text(label()).font(.system(size: 10)).lineLimit(1)
        }
        .padding(5)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
    }

    /// A drawn stand-in for a window picture: title bar plus content lines.
    private func windowThumbnail(color: Color) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(color.opacity(0.6)).frame(height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(.quaternary).frame(width: 34, height: 3)
                Capsule().fill(.quaternary).frame(width: 24, height: 3)
                Capsule().fill(.quaternary).frame(width: 30, height: 3)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(3)
    }
}

struct SwitcherPreviewCard: View {
    let mode: SwitcherMode
    let previews: Bool
    @State private var selected = 0

    private var count: Int { 4 }

    var body: some View {
        SettingsPreviewCard(
            title: "App Switcher preview",
            summary: mode == .apps
                ? "The switcher lists running apps. Tab moves to the next one."
                : previews
                    ? "The switcher lists each window with a picture of it. Tab moves to the next one."
                    : "The switcher lists each window with its app icon. Tab moves to the next one.",
            actions: AnyView(PreviewButton(title: "Press Tab") { selected = (selected + 1) % count })
        ) {
            SwitcherPreview(mode: mode, previews: previews, selected: selected)
        }
    }
}

// MARK: - Menu Bar

/// Left to right in the real menu bar: Always Hidden, separator, Hidden,
/// separator, Visible. Collapsed, only Visible shows; revealing slides the
/// Hidden items in. Always Hidden only appears when that section is on.
struct MenuBarSectionsPreview: View {
    let alwaysHiddenOn: Bool
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            PreviewDesktop()
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo")
                    Text("App").fontWeight(.semibold)
                    Text("File")
                    Text("Edit")
                    Spacer()
                    if alwaysHiddenOn && revealed {
                        group([.red, .indigo], label: "Always Hidden", tint: .red)
                            .transition(.opacity)
                        separatorBar
                    }
                    if revealed {
                        group([.orange, .green, .blue], label: "Hidden", tint: .orange)
                            .transition(.opacity)
                    }
                    if revealed || alwaysHiddenOn { separatorBar }
                    group([.gray, .teal], label: "Visible", tint: .accentColor)
                    Text("9:41").font(.system(size: 11))
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10).frame(height: 24)
                .background(.regularMaterial)
                Text(caption)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .animation(previewAnimation(reduceMotion), value: revealed)
            .animation(previewAnimation(reduceMotion), value: alwaysHiddenOn)
        }
    }

    private var caption: String {
        if revealed {
            return alwaysHiddenOn
                ? "Shelf open: Always Hidden and Hidden items show left of the bars."
                : "Shelf open: Hidden items show left of the bar."
        }
        return alwaysHiddenOn
            ? "Shelf closed: only Visible items show. Always Hidden stays out until you turn the section off."
            : "Shelf closed: only Visible items show."
    }

    private var separatorBar: some View {
        Capsule().fill(.secondary).frame(width: 2, height: 14)
    }

    private func group(_ colors: [Color], label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.85)).frame(width: 14, height: 14)
            }
        }
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.9), lineWidth: 1))
        .overlay(alignment: .bottom) {
            Text(label).font(.system(size: 8)).foregroundStyle(tint)
                .fixedSize().offset(y: 12)
        }
        .padding(.bottom, 10)
    }
}

/// The shelf with the chosen ways to open it listed under the bar, and when it
/// closes again. Chips only; the pointer triggers show only when available.
struct MenuBarTriggersPreview: View {
    let settings: MenuBarTriggerSettings
    let revealed: Bool
    let pointerAvailable: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            MenuBarSectionsPreview(alwaysHiddenOn: false, revealed: revealed)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    chip("Click the control", on: true)
                    chip(settings.hotkey?.displayString ?? "No shortcut", on: settings.hotkey != nil)
                    chip("Hover", on: settings.hover && pointerAvailable)
                    chip("Scroll", on: settings.scroll && pointerAvailable)
                    chip("Empty bar click", on: settings.emptyClick && pointerAvailable)
                }
                Text(rehide).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
        }
    }

    private var rehide: String {
        var parts: [String] = []
        if settings.rehideSeconds > 0 { parts.append("after \(settings.rehideSeconds) s") }
        if settings.rehideOnAppChange { parts.append("when you switch apps") }
        return parts.isEmpty ? "Stays open until you hide it." : "Hides again " + parts.joined(separator: " or ") + "."
    }

    private func chip(_ title: String, on: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(on ? Color.white : Color.secondary)
            .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
    }
}

struct MenuBarTriggersPreviewCard: View {
    let settings: MenuBarTriggerSettings
    let pointerAvailable: Bool
    @State private var revealed = false

    var body: some View {
        SettingsPreviewCard(
            title: "Reveal and hide",
            summary: "Lit chips are the ways to open the shelf. It hides again on its own as chosen below.",
            actions: AnyView(PreviewButton(title: revealed ? "Hide again" : "Reveal") { revealed.toggle() })
        ) {
            MenuBarTriggersPreview(settings: settings, revealed: revealed, pointerAvailable: pointerAvailable)
        }
    }
}

// MARK: - Command Center

/// The launcher panel: search field, mixed result kinds, and the shortcut.
struct CommandCenterLauncherPreview: View {
    let shortcut: String?

    var body: some View {
        ZStack {
            PreviewDesktop()
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("saf").font(.system(size: 13))
                    Rectangle().fill(Color.accentColor).frame(width: 1, height: 14)
                    Spacer()
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                Divider()
                row("safari", "Safari", "App", selected: true)
                row("gearshape", "Settings: Safari", "Settings", selected: false)
                row("link", "Safari Technology Preview", "Quicklink", selected: false)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 40).padding(.vertical, 10)
        }
    }

    private func row(_ symbol: String, _ title: String, _ kind: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(kind).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(selected ? Color.accentColor.opacity(0.3) : .clear)
    }
}

struct CommandCenterLauncherPreviewCard: View {
    let shortcut: String?

    var body: some View {
        SettingsPreviewCard(
            title: "Command Center preview",
            summary: "A search box over apps, commands, Settings panes and quicklinks. Return opens the highlighted row."
        ) {
            CommandCenterLauncherPreview(shortcut: shortcut)
        }
    }
}
