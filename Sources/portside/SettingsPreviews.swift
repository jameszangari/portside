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
        .onChange(of: autoHide) { revealed = false }
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

/// A row of picture cards for a choice whose options are easier seen than read.
struct SettingsChoiceCards<Value: Hashable, Picture: View>: View {
    let selection: Binding<Value>
    let choices: [(value: Value, title: String)]
    let columns: Int
    @ViewBuilder let picture: (Value) -> Picture

    init(selection: Binding<Value>, choices: [(Value, String)], columns: Int, @ViewBuilder picture: @escaping (Value) -> Picture) {
        self.selection = selection
        self.choices = choices.map { (value: $0.0, title: $0.1) }
        self.columns = columns
        self.picture = picture
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 8) {
            ForEach(choices, id: \.value) { choice in
                let selected = selection.wrappedValue == choice.value
                Button {
                    selection.wrappedValue = choice.value
                } label: {
                    VStack(spacing: 5) {
                        picture(choice.value)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .accessibilityHidden(true)
                        Text(choice.title)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 2)
    }
}

private let previewAppColors: [Color] = [.orange, .green, .blue, .pink, .purple, .teal]

/// A miniature screen top: the bar, its notch, and what sits on it.
private struct PreviewMiniBar<Overlay: View>: View {
    var notch = false
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 10)
                if notch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                        .fill(Color.black)
                        .frame(width: size.width * 0.2, height: 10)
                        .offset(x: size.width * 0.4)
                }
                overlay(size)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct PreviewDots: View {
    let count: Int
    var size: CGFloat = 5

    var body: some View {
        HStack(spacing: size * 0.5) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: size * 0.25).fill(previewAppColors[index % previewAppColors.count]).frame(width: size, height: size)
            }
        }
    }
}

private struct PreviewMiniPanel: View {
    var body: some View {
        PreviewDots(count: 4)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.28)))
    }
}

struct MenuBarPresentationPicture: View {
    let presentation: MenuBarPresentation

    var body: some View {
        PreviewMiniBar(notch: presentation == .portsideBarOnNotch) { size in
            if presentation == .menuBar {
                PreviewDots(count: 5, size: 4)
                    .frame(width: size.width - 6, height: 10, alignment: .trailing)
            } else {
                PreviewMiniPanel().frame(width: size.width, alignment: .center).offset(y: 18)
            }
        }
    }
}

struct MenuBarLocationPicture: View {
    let location: MenuBarBarLocation

    var body: some View {
        PreviewMiniBar { size in
            let visible = NSRect(origin: .zero, size: size)
            let icon = NSRect(x: size.width * 0.74, y: 0, width: 8, height: 10)
            let pointerX = size.width * 0.34
            let panelWidth: CGFloat = 26
            let followsPointer = location == .pointer || location == .dynamic
            let placement = MenuBarBarPlacement(location: location, pointer: NSPoint(x: pointerX, y: 0), pointerOnEmptyBar: location == .dynamic)
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: icon.midX - 3, y: 2)
            if followsPointer {
                Image(systemName: "cursorarrow").font(.system(size: 9)).offset(x: pointerX - 3, y: 0)
            }
            if location == .dynamic {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                    .frame(width: panelWidth, height: 11)
                    .offset(x: MenuBarBarPlacement(location: .icon).x(width: panelWidth, visible: visible, anchor: icon), y: 18)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.3))
                .frame(width: panelWidth, height: 11)
                .offset(x: placement.x(width: panelWidth, visible: visible, anchor: icon), y: 18)
        }
    }
}

struct MenuBarRehidePicture: View {
    let strategy: MenuBarRehideStrategy

    private var symbol: String {
        switch strategy {
        case .smart: "sparkles"
        case .timed: "timer"
        case .focusedApp: "macwindow.on.rectangle"
        }
    }

    var body: some View {
        Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
    }
}

struct MenuBarShapePicture: View {
    let shape: MenuBarShape
    let look: MenuBarLook

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width, height: 14)
            let notch = (size.width * 0.42)...(size.width * 0.58)
            let rects = MenuBarStylePlan.rects(shape: shape, size: size, notch: notch, menusEnd: size.width * 0.26, itemsStart: size.width * 0.68)
            let fill = DockLook(background: look.background, cornerRadius: min(look.cornerRadius, 4))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                ForEach(rects.indices, id: \.self) { index in
                    let rect = rects[index]
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .dockBackground(fill, in: RoundedRectangle(cornerRadius: min(look.cornerRadius, rect.height / 2), style: .continuous))
                        .offset(x: rect.minX, y: rect.minY)
                }
                Capsule().fill(Color.primary.opacity(0.6)).frame(width: size.width * 0.16, height: 3).offset(x: 7, y: 5.5)
                PreviewDots(count: 3, size: 4).frame(width: size.width - 8, height: 14, alignment: .trailing)
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                    .fill(Color.black)
                    .frame(width: size.width * 0.16, height: 12)
                    .offset(x: size.width * 0.42)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct MenuBarBarStylePicture: View {
    let style: MenuBarBarStyle
    let look: MenuBarLook
    let dock: DockLook

    var body: some View {
        var chosen = look
        chosen.barStyle = style
        return MenuBarPreviewPanel(look: chosen.panelLook(dock: dock), iconScale: 0.45, count: 4)
    }
}

/// The Portside Bar, drawn with the same look as the real one.
private struct MenuBarPreviewPanel: View {
    let look: MenuBarOverflowPanel.Look
    let iconScale: CGFloat
    let count: Int

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: min(look.cornerRadius, 12), style: .continuous) }

    var body: some View {
        let content = PreviewDots(count: count, size: max(look.iconSize * iconScale, 5)).padding(5)
        if let dock = look.dock {
            content.dockBackground(dock, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A small bar with the pointer on its empty part, showing the gesture.
struct MenuBarGestureGlyph: View {
    enum Kind { case click, scroll, hover }
    let kind: Kind

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07))
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 10)
            PreviewDots(count: 2, size: 4).frame(width: 40, height: 10, alignment: .trailing)
            switch kind {
            case .click:
                Circle().strokeBorder(Color.accentColor, lineWidth: 1).frame(width: 12, height: 12).offset(x: 6, y: -1)
            case .scroll:
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor).offset(x: 22, y: 12)
            case .hover:
                ForEach(0..<3, id: \.self) { step in
                    Circle().fill(Color.accentColor.opacity(0.7 - Double(step) * 0.2)).frame(width: 3, height: 3).offset(x: CGFloat(22 + step * 5), y: 17)
                }
            }
            Image(systemName: "cursorarrow").font(.system(size: 11)).offset(x: 9, y: 3)
        }
        .frame(width: 46, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// When the shelf closes: open, then the chosen condition, then hidden.
struct MenuBarRehideFlow: View {
    let settings: MenuBarTriggerSettings

    private var condition: (symbol: String, text: String)? {
        guard settings.rehideSeconds > 0 else { return nil }
        let time = "\(settings.rehideSeconds) s"
        switch settings.strategy {
        case .smart: return ("sparkles", "\(time), or a click elsewhere")
        case .timed: return ("timer", "\(time) off the menu bar")
        case .focusedApp: return ("macwindow.on.rectangle", "You switch apps")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            step("eye", "Open")
            if let condition {
                arrow
                step(condition.symbol, condition.text)
                arrow
                step("eye.slash", "Hidden")
            } else {
                arrow
                step("hand.raised", "Stays open until you hide it")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// The menu bar and Portside Bar as they are set up now: shape, fill, icon,
/// where hidden items appear and where the bar opens.
struct MenuBarLivePreview: View {
    let settings: MenuBarTriggerSettings
    let dock: DockLook
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barHeight: CGFloat = 24
    private static let hiddenCount = 5
    private static let iconScale: CGFloat = 0.55

    private var look: MenuBarLook { settings.look }
    private var usesBar: Bool { settings.presentation != .menuBar }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let size = CGSize(width: width, height: Self.barHeight)
            let notch = (width * 0.44)...(width * 0.56)
            let inline = revealed && !usesBar
            let visibleWidth: CGFloat = 96
            let itemsStart = width - visibleWidth - (inline ? 72 : 0)
            let rects = MenuBarStylePlan.rects(shape: look.shape, size: size, notch: notch, menusEnd: width * 0.2, itemsStart: itemsStart)
            let fill = DockLook(background: look.background, cornerRadius: look.cornerRadius)
            ZStack(alignment: .topLeading) {
                PreviewDesktop()
                ForEach(rects.indices, id: \.self) { index in
                    let rect = rects[index]
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .dockBackground(fill, in: RoundedRectangle(cornerRadius: min(look.cornerRadius, rect.height / 2), style: .continuous), shadow: look.shadow)
                        .offset(x: rect.minX, y: rect.minY)
                }
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo")
                    Text("App").fontWeight(.semibold)
                    Text("File")
                    Spacer()
                    if inline { PreviewDots(count: Self.hiddenCount, size: 9).transition(.opacity) }
                    controlIcon
                    Image(systemName: "wifi")
                    Text("9:41")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .frame(width: width, height: Self.barHeight)
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(Color.black)
                    .frame(width: notch.upperBound - notch.lowerBound, height: Self.barHeight)
                    .offset(x: notch.lowerBound)
                if revealed && usesBar {
                    bar(width: width).transition(.opacity)
                }
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(width: width, height: proxy.size.height - 6, alignment: .bottomLeading)
            }
            .animation(previewAnimation(reduceMotion), value: revealed)
        }
    }

    @ViewBuilder private var controlIcon: some View {
        if let image = look.controlArtwork(hidden: !revealed, description: "") {
            Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
        }
    }

    private func bar(width: CGFloat) -> some View {
        let panel = MenuBarPreviewPanel(look: look.panelLook(dock: dock), iconScale: Self.iconScale, count: Self.hiddenCount)
        let panelWidth = CGFloat(Self.hiddenCount) * (max(look.barIconSize * Self.iconScale, 5) * 1.5) + 10
        let anchor = NSRect(x: width - 100, y: 0, width: 16, height: Self.barHeight)
        let placement = MenuBarBarPlacement(location: settings.barLocation, pointer: NSPoint(x: width * 0.34, y: 0), pointerOnEmptyBar: false)
        let visible = NSRect(x: 0, y: 0, width: width, height: 132)
        return panel.offset(x: placement.x(width: panelWidth, visible: visible, anchor: anchor), y: Self.barHeight + 8)
    }

    private var caption: String {
        guard revealed else { return "Closed: only your Visible items are in the menu bar." }
        return usesBar ? "Open: hidden items appear in the Portside Bar." : "Open: hidden items appear in the menu bar."
    }
}

struct MenuBarLivePreviewCard: View {
    let settings: MenuBarTriggerSettings
    let dock: DockLook
    @State private var revealed = true

    var body: some View {
        SettingsPreviewCard(
            title: "Your menu bar",
            summary: "Shows your current shape, colors, icon and where hidden items appear.",
            actions: AnyView(PreviewButton(title: revealed ? "Close" : "Open") { revealed.toggle() })
        ) {
            MenuBarLivePreview(settings: settings, dock: dock, revealed: revealed)
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

// MARK: - Top Notch

/// A black notch pill on a miniature screen top, at `position`.
struct NotchPositionPicture: View {
    let position: AgentNotchPosition

    var body: some View {
        PreviewMiniBar(notch: true) { size in
            let notch = size.width * 0.2
            switch position {
            case .attached:
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(Color.black)
                    .frame(width: notch + 24, height: 13)
                    .offset(x: (size.width - notch - 24) / 2)
            case .below:
                Capsule().fill(Color.black).frame(width: notch + 14, height: 9)
                    .offset(x: (size.width - notch - 14) / 2, y: 14)
            case .left, .right:
                Capsule().fill(Color.black).frame(width: 16, height: 8)
                    .offset(x: position == .left ? size.width * 0.4 - 19 : size.width * 0.6 + 3, y: 1)
            }
        }
    }
}

/// Which screens get the notch: a primary external display (left) and
/// a laptop with a notch (right).
struct NotchDisplayPicture: View {
    let display: AgentNotchDisplay

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            screen(notched: false, shows: display != .automatic)
            screen(notched: true, shows: display != .primary)
        }
        .padding(.horizontal, 4)
    }

    private func screen(notched: Bool, shows: Bool) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 5)
            if notched {
                UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2).fill(Color.black).frame(width: 9, height: 5)
            }
            if shows {
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(Color.black)
                    .frame(width: notched ? 22 : 16, height: notched ? 7 : 5)
                    .overlay { Circle().fill(Color.accentColor).frame(width: 3, height: 3).offset(x: notched ? -7 : -4) }
            }
        }
        .frame(width: notched ? 40 : 48, height: notched ? 28 : 34)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// The compact pill's content in each style.
struct NotchCompactStylePicture: View {
    let style: AgentNotchCompactStyle

    var body: some View {
        HStack(spacing: 4) {
            switch style {
            case .counts:
                PreviewDots(count: 2, size: 3).padding(.leading, 2)
                Text("2").font(.system(size: 8, weight: .semibold))
                Spacer(minLength: 2)
                Text("3").font(.system(size: 8))
            case .providers:
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Circle().fill(Color.blue).frame(width: 5, height: 5)
                Spacer(minLength: 2)
                Text("3").font(.system(size: 8))
            case .minimal:
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                Spacer(minLength: 2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(width: 62, height: 14)
        .background(Capsule().fill(Color.black))
    }
}

/// What a click on the compact classic island does.
struct NotchClickActionPicture: View {
    let action: AgentNotchClickAction

    var body: some View {
        VStack(spacing: 3) {
            Capsule().fill(Color.black).frame(width: 40, height: 8)
            if action == .expand {
                RoundedRectangle(cornerRadius: 4).fill(Color.black).frame(width: 52, height: 22)
                    .overlay { VStack(spacing: 3) { previewRow; previewRow } }
            } else {
                Image(systemName: "macwindow").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
    }

    private var previewRow: some View {
        Capsule().fill(Color.white.opacity(0.3)).frame(width: 38, height: 3)
    }
}

/// A black shelf with session rows: one plus "+2", or all three.
struct NotchAgentCardPicture: View {
    let card: NotchAgentCard

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<(card == .all ? 3 : 1), id: \.self) { index in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(previewAppColors[index]).frame(width: 6, height: 6)
                    Capsule().fill(Color.white.opacity(0.45)).frame(width: 30, height: 3)
                }
            }
            if card == .latest {
                Text("+2").font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(6)
        .frame(width: 64, height: 40, alignment: .topLeading)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7).fill(Color.black))
    }
}

/// The shelf's tab row with the page it opens on selected.
struct NotchStartPagePicture: View {
    let start: NotchShelfStartPage

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: start == .lastUsed ? "clock.arrow.circlepath" : start.page?.symbol ?? "1.circle")
                .font(.system(size: 13)).foregroundStyle(.white)
            HStack(spacing: 3) {
                ForEach(NotchShelfPage.allCases) { page in
                    let selected = start.page == page || start == .first && page == NotchShelfPage.allCases.first
                    Capsule().fill(Color.white.opacity(selected ? 0.8 : 0.2)).frame(width: 12, height: 4)
                }
            }
        }
        .frame(width: 58, height: 38)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7).fill(Color.black))
    }
}

/// One Widgets page card in miniature.
struct NotchSlotPicture: View {
    let slot: NotchShelfSlot

    var body: some View {
        Group {
            switch slot {
            case .music:
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(Color.white.opacity(0.7)).frame(width: 18, height: 3)
                        Image(systemName: "playpause.fill").font(.system(size: 7))
                    }
                }
            case .weather:
                VStack(spacing: 1) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 11))
                    Text("42°").font(.system(size: 9, weight: .semibold))
                }
            case .calendar:
                VStack(alignment: .leading, spacing: 3) {
                    Text("SAT").font(.system(size: 6, weight: .bold)).foregroundStyle(.red)
                    ForEach([Color.blue, Color.orange], id: \.self) { color in
                        HStack(spacing: 2) {
                            Capsule().fill(color).frame(width: 2, height: 7)
                            Capsule().fill(Color.white.opacity(0.5)).frame(width: 18, height: 3)
                        }
                    }
                }
            case .empty:
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                    .frame(width: 32, height: 22)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 50, height: 36)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black))
    }
}

/// Square album art, or a record with a spindle hole.
struct NotchMusicStylePicture: View {
    let style: NotchMusicStyle

    private var art: LinearGradient {
        LinearGradient(colors: [.pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        HStack(spacing: 6) {
            if style == .vinyl {
                ZStack {
                    Circle().fill(Color(white: 0.08))
                    Circle().fill(art).padding(2)
                    Circle().fill(Color.black).frame(width: 4, height: 4)
                }
                .frame(width: 26, height: 26)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(art).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Color.white.opacity(0.75)).frame(width: 22, height: 3)
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 16, height: 3)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
    }
}
