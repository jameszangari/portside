import AppKit
import SwiftUI

/// The live switcher panel: the Command Center panel class (key-capable,
/// never main, non-activating), centered on the display with the pointer.
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
    /// Visible frame of the display the panel opened on, fixed while open.
    private var screenFrame: NSRect?
    /// Top edge once placed: a filtering list grows and shrinks downward
    /// instead of jumping around the center.
    private var top: CGFloat?

    func present(_ switcher: AppSwitcher) {
        self.switcher = switcher
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let visible = (Self.screenWithMouse() ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        screenFrame = visible
        top = nil
        hosting?.rootView = AnyView(root(switcher, maxWidth: visible.width * 0.9))
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
        screenFrame = nil
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
        panel.hasShadow = true
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
        guard let panel, let screenFrame, size.width > 0, size.height > 0 else { return }
        let top = self.top ?? (screenFrame.midY + size.height / 2).rounded()
        self.top = top
        let frame = NSRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: max(top - size.height, screenFrame.minY),
            width: size.width,
            height: size.height
        )
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}


enum SwitcherLayout {
    static let maxIcon: CGFloat = 72
    static let minIcon: CGFloat = 28
    static let tileInset: CGFloat = 8
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 16
    static let cornerRadius: CGFloat = 22
    /// Window list: fixed row height so the list's height is known without
    /// measuring, and at most this many rows before it scrolls.
    static let rowHeight: CGFloat = 44
    static let maxRows = 9
    static let listWidth: CGFloat = 560

    /// Largest icon at which `count` tiles fit in `maxWidth`, within limits.
    static func iconSize(count: Int, maxWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(count, 1))
        let room = maxWidth - padding * 2 - spacing * (count - 1)
        return min(maxIcon, max(minIcon, (room / count - tileInset * 2).rounded(.down)))
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

    var body: some View {
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
            }
        }
        .padding(SwitcherLayout.padding)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SwitcherLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App Switcher")
    }

    @ViewBuilder private var appRow: some View {
        let items = state.items
        let selected = state.selectedItem
        let icon = SwitcherLayout.iconSize(count: items.count, maxWidth: maxWidth)
        HStack(spacing: SwitcherLayout.spacing) {
            ForEach(items) { item in
                SwitcherTile(item: item, image: switcher.icon(for: item), iconSize: icon, isSelected: item.id == state.selection,
                             onChoose: { switcher.choose(item.id) }, onHover: { switcher.hovered(item.id) })
            }
        }
        Text(selected?.name ?? " ")
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: max(maxWidth - SwitcherLayout.padding * 2, 120))
            .accessibilityHidden(true)
        if let selected {
            if state.windowSelection != nil {
                // Down chose a window: the app's windows, that one framed.
                rows(selected.windows.map(selected.entry)) { entry in
                    entry.window?.id == state.windowSelection
                } choose: { entry in
                    switcher.choose(selected.id, window: entry.window?.id)
                }
            } else if selected.windows.count > 1 {
                Text("\(selected.windows.count) windows. Press ↓ to choose one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
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

private struct SwitcherTile: View {
    let item: SwitcherItem
    let image: NSImage
    let iconSize: CGFloat
    let isSelected: Bool
    let onChoose: () -> Void
    let onHover: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var icon: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: iconSize, height: iconSize)
            // Hidden apps read dimmed, as in the dock's translucent option.
            .opacity(item.isHidden ? 0.55 : 1)
            .padding(SwitcherLayout.tileInset)
    }

    var body: some View {
        icon
            .background(shape.fill(isSelected ? Color.primary.opacity(0.16) : Color.clear))
            // Fill plus an orange edge, so selection never rests on color alone.
            .overlay(shape.strokeBorder(isSelected ? Color.orange : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(perform: onChoose)
            .onContinuousHover { phase in
                if case .active = phase { onHover() }
            }
            .help(item.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.spokenName)
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }

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
        .background(shape.fill(isSelected ? Color.primary.opacity(0.16) : Color.clear))
        .overlay(shape.strokeBorder(isSelected ? Color.orange : Color.clear, lineWidth: 2))
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
