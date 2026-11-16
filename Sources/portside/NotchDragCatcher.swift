import AppKit
import os.log

/// Keeps a file drag out of the menu bar while the Notch Shelf takes files
/// (maintainer report: a Finder file dragged toward the notch opened
/// Mission Control, with Portside off too). macOS 27's WindowManager opens
/// Mission Control about 75 ms after a drag's pointer enters the menu bar
/// band, whatever is under it (its log: "Change expose mode off ->
/// missionControl"); the Mission Control drag setting does not cover file
/// drags. So while a file drag is in progress the pointer is held just
/// below the menu bar (`CGWarpMouseCursorPosition`, public), and a window
/// lies under the bar on each screen: hovering it opens the shelf on Files,
/// which then grows down under the pointer to take the drop; dropping on
/// the window itself adds the files too. Its fill is 1% black, since fully
/// clear pixels let a drag fall through. A drag starts when the drag
/// pasteboard changes after a mouse down and holds file URLs; everything
/// goes away when the drag ends. Global mouse monitors only, no permission
/// and no polling. Main queue only.
final class NotchDragCatcher {
    /// The band under the menu bar that opens the shelf.
    static let bandHeight: CGFloat = 28

    /// A file drag entered (true) or left (false) the catcher on a screen.
    var onHover: ((NSScreen, Bool) -> Void)?
    var onDrop: ((NSScreen, [URL]) -> Void)?
    /// Windows that stay above the catcher (the notch panels).
    var above: () -> [NSWindow] = { [] }
    private(set) var running = false
    private var monitor: Any?
    private var pressCount = 0
    /// This press was already checked and is not a file drag.
    private var ignored = false
    private var panels: [NSPanel] = []
    private var hideTask: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.james.portside", category: "NotchDragCatcher")

    func start() {
        guard !running else { return }
        running = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hide()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressCount = NSPasteboard(name: .drag).changeCount
            ignored = false
            hide()
        case .leftMouseDragged:
            if !panels.isEmpty { keepOutOfBar(); return }
            guard !ignored else { return }
            let board = NSPasteboard(name: .drag)
            // The source writes the drag pasteboard a few events in.
            guard board.changeCount != pressCount else { return }
            guard board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
                ignored = true
                return
            }
            show()
        case .leftMouseUp, .mouseMoved:
            // The drag is over (a moved event means no button is down).
            // Wait a moment so the drop is handed over first.
            guard !panels.isEmpty, hideTask == nil else { return }
            let task = DispatchWorkItem { [weak self] in self?.hide() }
            hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        default:
            break
        }
    }

    /// The menu bar band's height on `screen`, in points.
    static func barHeight(_ screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
    }

    /// Holds the pointer one point below the menu bar of the screen it is on.
    private func keepOutOfBar() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }),
              let primary = NSScreen.screens.first else { return }
        let limit = screen.frame.maxY - Self.barHeight(screen) - 1
        guard point.y > limit else { return }
        // Global Quartz coordinates: origin at the primary screen's top left.
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.maxY - limit))
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        for screen in NSScreen.screens {
            let top = screen.frame.maxY - Self.barHeight(screen)
            let frame = NSRect(x: screen.frame.minX, y: top - Self.bandHeight, width: screen.frame.width, height: Self.bandHeight)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            let view = CatcherView(frame: NSRect(origin: .zero, size: frame.size))
            view.onHover = { [weak self, weak screen] inside in if let screen { self?.onHover?(screen, inside) } }
            view.onDrop = { [weak self, weak screen] urls in if let screen { self?.onDrop?(screen, urls) } }
            view.onEnd = { [weak self] in self?.hide() }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        above().filter(\.isVisible).forEach { $0.orderFrontRegardless() }
        keepOutOfBar()
        logger.info("file drag: holding the pointer under the menu bar on \(self.panels.count) screen(s)")
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard !panels.isEmpty else { return }
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels = []
        logger.info("file drag: done")
    }

    private final class CatcherView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        var onDrop: ([URL]) -> Void = { _ in }
        var onEnd: () -> Void = {}

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onHover(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            onDrop(urls)
            return !urls.isEmpty
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) { onEnd() }
    }
}
