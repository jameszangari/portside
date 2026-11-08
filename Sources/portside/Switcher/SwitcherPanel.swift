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

    func present(_ switcher: AppSwitcher) {
        self.switcher = switcher
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let visible = (Self.screenWithMouse() ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        screenFrame = visible
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
                if let key = SwitcherKey(keyCode: event.keyCode, modifiers: event.modifierFlags) {
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
        let frame = NSRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: (screenFrame.midY - size.height / 2).rounded(),
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

    /// Largest icon at which `count` tiles fit in `maxWidth`, within limits.
    static func iconSize(count: Int, maxWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(count, 1))
        let room = maxWidth - padding * 2 - spacing * (count - 1)
        return min(maxIcon, max(minIcon, (room / count - tileInset * 2).rounded(.down)))
    }
}

/// A row of app icons with the selected one framed and named underneath,
/// like ⌘Tab. Clicking a tile switches to it. Renders state only.
struct SwitcherView: View {
    @ObservedObject var switcher: AppSwitcher
    let maxWidth: CGFloat

    var body: some View {
        let items = switcher.state.items
        let selection = switcher.state.selection
        let icon = SwitcherLayout.iconSize(count: items.count, maxWidth: maxWidth)
        VStack(spacing: 8) {
            HStack(spacing: SwitcherLayout.spacing) {
                ForEach(items) { item in
                    SwitcherTile(item: item, image: switcher.icon(for: item), iconSize: icon, isSelected: item.key == selection,
                                 onChoose: { switcher.choose(item.key) }, onHover: { switcher.hovered(item.key) })
                }
            }
            Text(switcher.state.selectedItem?.name ?? " ")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: max(maxWidth - SwitcherLayout.padding * 2, 120))
                .accessibilityHidden(true)
        }
        .padding(SwitcherLayout.padding)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SwitcherLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App Switcher")
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
