import AppKit
import SwiftUI

/// The live switcher panel: the Command Center panel class (key-capable,
/// never main, non-activating), centered on the whole display with the
/// pointer, as ⌘Tab centers on the screen rather than its visible frame.
/// Monitors are installed only while it is open and read only Portside's
/// own events (a local monitor), so nothing here needs a permission. Another
/// app activating is seen by `AppSwitcher` through the window registry, so
/// the switcher's own earlier activation landing late is not taken for one.
@MainActor
final class SwitcherPanelPresenter: SwitcherPresenter {
    private var panel: CommandCenterPanel?
    private var hosting: CommandCenterHostingView?
    private weak var switcher: AppSwitcher?
    private var monitor: Any?
    private var becameKey: NSObjectProtocol?
    private var pendingAnnouncement: DispatchWorkItem?
    /// Display the panel opened on, fixed while open.
    private var screen: NSScreen?
    /// Top edge once placed: a filtering list grows and shrinks downward
    /// instead of jumping around the center.
    private var top: CGFloat?

    func present(_ switcher: AppSwitcher) {
        self.switcher = switcher
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = Self.screenWithMouse() ?? NSScreen.main
        self.screen = screen
        top = nil
        let width = screen?.frame.width ?? 1440
        hosting?.rootView = AnyView(root(switcher, maxWidth: width - SwitcherLayout.screenMargin * 2))
        hosting?.layoutSubtreeIfNeeded()
        place(size: hosting?.fittingSize ?? panel.frame.size)
        // Transparent until the reveal: a quick tap never flashes it, but
        // the panel is already key and hears the modifier release.
        panel.alphaValue = 0
        installMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func reveal() {
        // No fade or scale, so Reduce Motion needs nothing different.
        panel?.alphaValue = 1
    }

    func dismiss() {
        removeMonitors()
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        screen = nil
        top = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 0
    }

    /// Coalesced so fast cycling speaks only where it stopped.
    func announce(_ message: String) {
        pendingAnnouncement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return }
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        pendingAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Events in

    private func installMonitors() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let switcher = self.switcher, let panel = self.panel, panel.isKeyWindow else { return false }
                if event.type == .flagsChanged {
                    switcher.modifiersChanged(event.modifierFlags, keyCode: event.keyCode, timestamp: event.timestamp)
                    return false
                }
                // Every other key is swallowed while open: nothing behind
                // the panel should receive typing meant for the switcher.
                if let key = SwitcherKey(
                    keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.characters,
                    unmodified: event.charactersIgnoringModifiers, searching: switcher.state.isSearching
                ) {
                    switcher.keyPressed(key)
                }
                return true
            }
            return consumed ? nil : event
        }
        // From here on the release is a local event; one let go before this
        // went to the other app, so read the keyboard once at this moment.
        becameKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.switcher?.panelBecameKey() }
        }
    }

    private func removeMonitors() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let becameKey { NotificationCenter.default.removeObserver(becameKey) }
        becameKey = nil
    }

    // MARK: Panel

    private func root(_ switcher: AppSwitcher, maxWidth: CGFloat) -> some View {
        SwitcherView(switcher: switcher, maxWidth: maxWidth)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.place(size: size)
            }
    }

    private func makePanel() -> CommandCenterPanel {
        let panel = CommandCenterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "App Switcher"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // ⌘Tab casts no shadow; the glass edge alone outlines it.
        panel.hasShadow = false
        panel.level = CommandCenterPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityLabel("App Switcher")
        panel.onResignKey = { [weak self] in
            MainActor.assumeIsolated {
                guard self?.switcher?.panelLostKey() == true else { return }
                // Our own earlier switch arrived: take key back on the next
                // turn, outside resignKey.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let panel = self?.panel, panel.isVisible, self?.switcher?.state.isOpen == true else { return }
                        panel.makeKey()
                    }
                }
            }
        }
        let hosting = CommandCenterHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    private func place(size: CGSize) {
        guard let panel, let screen, size.width > 0, size.height > 0 else { return }
        let top = self.top ?? screen.frame.midY + size.height / 2
        self.top = top
        // Whole pixels on any scale, so the glass edge stays crisp.
        let frame = screen.backingAlignedRect(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: max(top - size.height, screen.visibleFrame.minY),
            width: size.width,
            height: size.height
        ), options: .alignAllEdgesNearest)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}


/// App row sizes measured from the macOS 27 ⌘Tab switcher on a 2x display:
/// 120 pt selection squares 14 pt apart, 28 pt around them, 128 pt icons
/// overhanging the square, the name 4 pt under it. With more apps the squares
/// and gaps shrink together and the padding stays.
enum SwitcherLayout {
    static let maxSlot: CGFloat = 120
    static let minSlot: CGFloat = 32
    static let iconScale: CGFloat = 128 / 120
    static let gapScale: CGFloat = 14 / 120
    static let padding: CGFloat = 28
    /// Selection corner, a plain circular arc as measured; the panel corner
    /// is this plus the padding, so the two curves stay concentric.
    static let slotRadiusScale: CGFloat = 32 / 120
    static let labelGap: CGFloat = 4
    static let labelHeight: CGFloat = 16
    /// The name moves in from the panel ends rather than reaching the corner.
    static let labelEdgeInset: CGFloat = 50
    /// ⌘Tab leaves this much screen on each side at its widest.
    static let screenMargin: CGFloat = 37
    /// Window list and search keep Portside's tighter panel.
    static let listPadding: CGFloat = 16
    static let listCornerRadius: CGFloat = 22
    /// Window list: fixed row height so the list's height is known without
    /// measuring, and at most this many rows before it scrolls.
    static let rowHeight: CGFloat = 44
    static let maxRows = 9
    static let listWidth: CGFloat = 560

    /// Largest selection square at which `count` slots fit in `maxWidth`.
    static func slotSize(count: Int, maxWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(count, 1))
        let room = maxWidth - padding * 2
        return min(maxSlot, max(minSlot, (room / (count + gapScale * (count - 1))).rounded(.down)))
    }

    /// Rounded down so the row never outgrows the width its slot was fitted to.
    static func gap(slot: CGFloat) -> CGFloat {
        (slot * gapScale).rounded(.down)
    }

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), maxRows)) * rowHeight
    }
}

/// The app row (⌘Tab style) or, in window mode and while searching, a
/// window list. Clicking an entry switches to it. Renders state only.
struct SwitcherView: View {
    @ObservedObject var switcher: AppSwitcher
    let maxWidth: CGFloat

    private var state: SwitcherState { switcher.state }

    /// Honest limits, shown where windows are expected.
    private var note: String? {
        let wantsWindows = state.isSearching || switcher.preferences.mode == .windows || state.windowSelection != nil
        guard wantsWindows else { return nil }
        if !switcher.windowsAvailable { return "Window titles need Accessibility. Showing apps." }
        return "Windows on other Spaces may not be listed."
    }

    /// The plain app row: nothing but ⌘Tab's own icons and name.
    private var isPlainRow: Bool { !state.isWindowList && state.query == nil && note == nil && state.windowSelection == nil }

    private var slot: CGFloat { SwitcherLayout.slotSize(count: state.items.count, maxWidth: maxWidth) }

    /// The app row's corners follow its tiles, as in ⌘Tab. Anything under
    /// the row (window rows, the Accessibility note) gets the list's smaller
    /// bottom corners so it is not clipped.
    private var shape: UnevenRoundedRectangle {
        let list = SwitcherLayout.listCornerRadius
        if state.isWindowList {
            return UnevenRoundedRectangle(cornerRadii: .init(topLeading: list, bottomLeading: list, bottomTrailing: list, topTrailing: list),
                                          style: .continuous)
        }
        let row = SwitcherLayout.padding + slot * SwitcherLayout.slotRadiusScale
        let bottom = isPlainRow ? row : list
        return UnevenRoundedRectangle(cornerRadii: .init(topLeading: row, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: row),
                                      style: .circular)
    }

    var body: some View {
        let shape = self.shape
        VStack(spacing: 8) {
            if let query = state.query {
                SwitcherSearchField(query: query)
            }
            if state.isWindowList {
                windowList
            } else {
                appRow
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, state.isWindowList ? 0 : SwitcherLayout.listPadding)
            }
        }
        .padding(.top, state.isWindowList ? SwitcherLayout.listPadding : SwitcherLayout.padding)
        .padding(.horizontal, state.isWindowList ? SwitcherLayout.listPadding : 0)
        .padding(.bottom, isPlainRow ? SwitcherLayout.padding - SwitcherLayout.labelGap - SwitcherLayout.labelHeight : SwitcherLayout.listPadding)
        .background { SwitcherBackdrop().clipShape(shape) }
        .glassEffect(.clear, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App Switcher")
    }

    @ViewBuilder private var appRow: some View {
        let items = state.items
        let selected = state.selectedItem
        let slot = self.slot
        let gap = SwitcherLayout.gap(slot: slot)
        let index = items.firstIndex { $0.id == state.selection }
        VStack(spacing: SwitcherLayout.labelGap) {
            HStack(spacing: gap) {
                ForEach(items) { item in
                    SwitcherTile(item: item, image: switcher.icon(for: item), slot: slot, isSelected: item.id == state.selection,
                                 onChoose: { switcher.choose(item.id) }, onHover: { switcher.hovered(item.id) })
                }
            }
            .padding(.horizontal, SwitcherLayout.padding)
            // The name sits under the selected icon, as in ⌘Tab.
            SelectedNameLayout(centerX: SwitcherLayout.padding + CGFloat(index ?? 0) * (slot + gap) + slot / 2) {
                Text(selected?.name ?? " ")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: SwitcherLayout.labelHeight)
            .accessibilityHidden(true)
        }
        if let selected, state.windowSelection != nil {
            // Down chose a window: the app's windows, that one selected.
            rows(selected.windows.map(selected.entry)) { entry in
                entry.window?.id == state.windowSelection
            } choose: { entry in
                switcher.choose(selected.id, window: entry.window?.id)
            }
            .padding(.horizontal, SwitcherLayout.listPadding)
        }
    }

    @ViewBuilder private var windowList: some View {
        let shown = state.shown
        if shown.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .frame(width: min(maxWidth, SwitcherLayout.listWidth), height: SwitcherLayout.rowHeight)
        } else {
            rows(shown) { $0.id == state.selection } choose: { switcher.choose($0.id) } hover: { switcher.hovered($0.id) }
        }
    }

    /// `hover` is nil for the app row's window list, whose entries are not
    /// in `shown` (Down and Up choose there).
    private func rows(_ entries: [SwitcherItem], isSelected: @escaping (SwitcherItem) -> Bool,
                      choose: @escaping (SwitcherItem) -> Void,
                      hover: ((SwitcherItem) -> Void)? = nil) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        SwitcherRow(item: entry, image: switcher.icon(for: entry), isSelected: isSelected(entry),
                                    onChoose: { choose(entry) }, onHover: hover.map { hover in { hover(entry) } })
                        .id(entry.id)
                    }
                }
            }
            .scrollIndicators(entries.count > SwitcherLayout.maxRows ? .automatic : .never)
            .frame(width: min(maxWidth, SwitcherLayout.listWidth), height: SwitcherLayout.listHeight(rows: entries.count))
            .onChange(of: entries.first(where: isSelected)?.id, initial: true) { _, id in
                // Jumps, never animates, so Reduce Motion needs nothing more.
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

/// The latched search text with a caret. Typing reaches it through the
/// panel's key monitor, not a text field, so the panel never needs to
/// become main or take Portside active.
private struct SwitcherSearchField: View {
    let query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Search window titles").foregroundStyle(.secondary)
            } else {
                Text(query + "▏").lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 15))
        .padding(.horizontal, 10)
        .frame(width: SwitcherLayout.listWidth - 8, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search window titles")
        .accessibilityValue(query)
    }
}

/// Shading over the clear glass, fitted so the panel reads like ⌘Tab's over
/// black and white backdrops: 13 and 189 of 255 in Dark mode, 50 and 234 in
/// Light (the clear glass alone passes about 33 and 255 in Dark, 50 and 255 in Light).
private struct SwitcherBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            ZStack {
                Color.black.opacity(0.26)
                Color(white: 1 - 11 / 255).blendMode(.plusDarker)
            }
        } else {
            Color(white: 50 / 255).opacity(0.12)
        }
    }
}

/// ⌘Tab's selection: a square that lightens what is under it by a fixed
/// amount in Dark mode and darkens it in Light, so it reads the same over any
/// backdrop. Increase Contrast adds an edge.
private struct SwitcherSelection: View {
    let cornerRadius: CGFloat
    var style: RoundedCornerStyle = .circular
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: style)
        Group {
            if colorScheme == .dark {
                shape.fill(Color(white: 67 / 255)).blendMode(.plusLighter)
            } else {
                shape.fill(Color(white: 1 - 49 / 255)).blendMode(.plusDarker)
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.8 : 0), lineWidth: 2))
    }
}

/// Puts the selected app's name centered under `centerX`, slid in from the
/// panel ends when it would run past `labelEdgeInset`.
private struct SelectedNameLayout: Layout {
    let centerX: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.first?.sizeThatFits(.unspecified).height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let name = subviews.first else { return }
        let ideal = name.sizeThatFits(.unspecified).width
        // A short panel lets a long name use the padding before truncating.
        let inset = ideal + SwitcherLayout.labelEdgeInset * 2 <= bounds.width ? SwitcherLayout.labelEdgeInset : SwitcherLayout.listPadding
        let width = min(ideal, max(bounds.width - inset * 2, 0))
        let x = min(max(centerX - width / 2, inset), bounds.width - inset - width)
        name.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
    }
}

private struct SwitcherTile: View {
    let item: SwitcherItem
    let image: NSImage
    let slot: CGFloat
    let isSelected: Bool
    let onChoose: () -> Void
    let onHover: () -> Void

    var body: some View {
        // Hidden apps are not dimmed: ⌘Tab shows them like any other.
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: slot * SwitcherLayout.iconScale, height: slot * SwitcherLayout.iconScale)
            .frame(width: slot, height: slot)
            .background {
                if isSelected { SwitcherSelection(cornerRadius: slot * SwitcherLayout.slotRadiusScale) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onChoose)
            .onContinuousHover { phase in
                if case .active = phase { onHover() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.spokenName)
            .accessibilityHint(item.windows.count > 1 ? "Press Down Arrow to choose a window." : "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction(.default, onChoose)
    }
}

/// One window (or a windowless app) in the list: app icon, title, and the
/// app name and indicators in words and symbols, never color alone.
private struct SwitcherRow: View {
    let item: SwitcherItem
    let image: NSImage
    let isSelected: Bool
    let onChoose: () -> Void
    let onHover: (() -> Void)?

    private var detail: Text {
        var parts: [Text] = []
        if item.window != nil, item.title != item.name { parts.append(Text(item.name)) }
        if item.isHidden { parts.append(Text("\(Image(systemName: "eye.slash")) Hidden")) }
        if let window = item.window {
            if window.isMinimized { parts.append(Text("\(Image(systemName: "minus.circle")) Minimized")) }
            if window.isFullScreen { parts.append(Text("\(Image(systemName: "arrow.up.left.and.arrow.down.right")) Full Screen, own Space")) }
            if let display = window.display { parts.append(Text("\(Image(systemName: "display")) \(display)")) }
        } else if item.windowsUnavailable {
            parts.append(Text("Windows unavailable"))
        } else {
            parts.append(Text("No windows listed"))
        }
        guard let first = parts.first else { return Text("") }
        return parts.dropFirst().reduce(first) { Text("\($0)  ·  \($1)") }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(item.isHidden ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: SwitcherLayout.rowHeight)
        .background {
            if isSelected { SwitcherSelection(cornerRadius: 9, style: .continuous) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
        .onContinuousHover { phase in
            if case .active = phase { onHover?() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(.default, onChoose)
    }
}
