import AppKit
import SwiftUI
import os.log

/// DockPanel wraps a non-activating NSPanel that renders the dock strip.
/// It slides up from the bottom edge on `show` and back down on `hide`.
///
/// It knows nothing about the edge tracker or hide delays. It only reports
/// cursor enter/exit over itself and animation milestones; `DockEngine`
/// decides what to do with them.
final class DockPanel {
    /// Called when the cursor enters the panel's own tracking area.
    var onMouseEntered: ((NSEvent) -> Void)?
    /// Called when the cursor leaves the panel's own tracking area.
    var onMouseExited: (() -> Void)?
    /// Fired right after the reveal slide has been scheduled.
    var onRevealAnimationStarted: (() -> Void)?
    /// Fired once the panel is on screen and hit-testable (clicks work).
    var onPanelInteractive: (() -> Void)?
    /// Fired when the reveal slide completes (or immediately if instant).
    var onRevealAnimationFinished: (() -> Void)?

    /// Window level: above normal windows and floating panels, below the
    /// edge tracker window. Same level as menus so it sits over most UI.
    static let windowLevel: NSWindow.Level = .popUpMenu

    private enum State { case hidden, revealing, revealed, hiding }

    private let panel: PortsidePanel
    private let contentView: PanelContentView
    private let hostingView: NSHostingView<DockStrip>
    private let dockModel: DockModel
    private let logger = Logger(subsystem: "com.james.portside", category: "DockPanel")

    private var state: State = .hidden
    /// Incremented on every show/hide so stale animation completions can be ignored.
    private var generation = 0
    private var screenObserver: NSObjectProtocol?

    /// Padding around the SwiftUI strip inside the panel.
    private let horizontalInset: CGFloat = 12
    private let bottomInset: CGFloat = 6
    private let topInset: CGFloat = 10

    var isRevealedOrRevealing: Bool {
        state == .revealed || state == .revealing
    }

    // MARK: - Init

    init(dockModel: DockModel, strip: DockStrip) {
        self.dockModel = dockModel

        let hosting = FirstMouseHostingView(rootView: strip)
        hostingView = hosting
        // Report the SwiftUI ideal size through intrinsicContentSize, but do
        // not let the hosting view drive the window size (we animate the
        // window frame ourselves).
        hostingView.sizingOptions = [.intrinsicContentSize]

        contentView = PanelContentView(frame: .zero)
        contentView.addSubview(hostingView)

        panel = PortsidePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Not fully clear: the window server makes fully transparent pixels
        // click-through, and we want every point of the panel to be hit-testable.
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = DockPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.contentView = contentView

        contentView.onMouseEntered = { [weak self] event in self?.onMouseEntered?(event) }
        contentView.onMouseExited = { [weak self] in self?.onMouseExited?() }

        layout()
        // The strip's width changes as apps are pinned, removed, launched or
        // quit. Deferred so SwiftUI finishes its layout pass first.
        hosting.onIntrinsicSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.layoutIfSizeChanged() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layout()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Geometry

    private var screenFrame: NSRect {
        NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    private var panelSize: NSSize {
        var content = hostingView.intrinsicContentSize
        if content.width <= 0 || content.height <= 0 {
            content = hostingView.fittingSize
        }
        return NSSize(
            width: content.width + horizontalInset * 2,
            height: content.height + topInset + bottomInset
        )
    }

    private var revealedFrame: NSRect {
        let size = panelSize
        let screen = screenFrame
        return NSRect(
            x: screen.midX - size.width / 2,
            y: screen.minY,
            width: size.width,
            height: size.height
        )
    }

    private var hiddenFrame: NSRect {
        var frame = revealedFrame
        frame.origin.y = screenFrame.minY - frame.height
        return frame
    }

    /// Size the hosting view and put the panel at the frame matching its state.
    private func layout() {
        // Size the window first, then fit the hosting view inside the
        // content view's real bounds. Setting the subview frame before the
        // window has a size would get skewed by autoresizing.
        switch state {
        case .hidden, .hiding:
            panel.setFrame(hiddenFrame, display: false)
        case .revealed, .revealing:
            panel.setFrame(revealedFrame, display: false)
        }
        let bounds = contentView.bounds
        hostingView.frame = NSRect(
            x: bounds.minX + horizontalInset,
            y: bounds.minY + bottomInset,
            width: bounds.width - horizontalInset * 2,
            height: bounds.height - topInset - bottomInset
        )
        // Keeps the insets when the window is resized without going through
        // layout(), e.g. show() picking up a new strip width.
        hostingView.autoresizingMask = [.width, .height]
    }

    private func layoutIfSizeChanged() {
        guard panelSize != panel.frame.size else { return }
        layout()
        logger.info("panel resized to \(self.panel.frame.width, format: .fixed(precision: 0))x\(self.panel.frame.height, format: .fixed(precision: 0))")
    }

    /// Whether a point in screen coordinates is over the visible panel.
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    // MARK: - Show / Hide

    /// Put the panel in its hidden state without animation and keep it off screen.
    func prepareHidden() {
        generation += 1
        state = .hidden
        panel.setFrame(hiddenFrame, display: false)
        panel.orderOut(nil)
    }

    /// Slide the panel up from the bottom edge. Non-activating: the frontmost
    /// app keeps focus and the first click on the panel is delivered.
    func show(animated: Bool) {
        guard !isRevealedOrRevealing else { return }
        generation += 1
        let myGeneration = generation
        state = .revealing

        if !panel.isVisible {
            panel.setFrame(hiddenFrame, display: false)
        }
        panel.orderFrontRegardless()

        let target = revealedFrame
        let duration = effectiveDuration(animated: animated)

        if duration == 0 {
            panel.setFrame(target, display: true)
            onRevealAnimationStarted?()
            onPanelInteractive?()
            finishReveal(generation: myGeneration)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.finishReveal(generation: myGeneration)
        })
        onRevealAnimationStarted?()
        onPanelInteractive?()
    }

    /// Slide the panel down below the screen edge, then order it out.
    func hide(animated: Bool) {
        guard state == .revealed || state == .revealing else { return }
        generation += 1
        let myGeneration = generation
        state = .hiding

        let target = hiddenFrame
        let duration = effectiveDuration(animated: animated)

        if duration == 0 {
            panel.setFrame(target, display: true)
            finishHide(generation: myGeneration)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.finishHide(generation: myGeneration)
        })
    }

    private func finishReveal(generation: Int) {
        guard generation == self.generation else { return }
        state = .revealed
        onRevealAnimationFinished?()
        logger.info("panel revealed")
    }

    private func finishHide(generation: Int) {
        guard generation == self.generation else { return }
        state = .hidden
        panel.orderOut(nil)
        logger.info("panel hidden")
    }

    /// Animation duration honoring the instant option and Reduce Motion.
    private func effectiveDuration(animated: Bool) -> TimeInterval {
        if !animated { return 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
        return max(0, dockModel.animationDuration)
    }
}

// MARK: - NSPanel subclass

/// The panel never becomes key or main, like the native Dock: clicking an
/// item must not move keyboard focus away from the frontmost app. Clicks
/// still arrive because the hosting view accepts first mouse (verified with
/// synthetic clicks: item click logged, key window false, app inactive).
private final class PortsidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Do not let AppKit nudge the panel back on screen while it is parked
    /// below the bottom edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Content view with its own tracking area

/// Hosts the SwiftUI strip and reports cursor enter/exit over the panel so
/// the dock stays up while the user hovers it.
private final class PanelContentView: NSView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?(event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

/// NSHostingView that accepts the first click even when its window is not
/// key, so the user never needs a "wake up" click. Logs each mouse down so
/// the hand test can confirm no focus change (key window and app active
/// should both stay false).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private let logger = Logger(subsystem: "com.james.portside", category: "DockPanel")
    var onIntrinsicSizeChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }

    override func mouseDown(with event: NSEvent) {
        let keyWindow = window?.isKeyWindow ?? false
        logger.info("panel mouseDown (key window: \(keyWindow), portside active: \(NSApp.isActive))")
        super.mouseDown(with: event)
    }}
