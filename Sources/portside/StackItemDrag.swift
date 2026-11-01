import AppKit
import SwiftUI
import os.log

/// Drags a file out of an open folder stack, like dragging it out of a
/// Finder window: drop it on an app window, a Finder folder, the Desktop, or
/// an app tile in the dock. Same volume moves, Option copies, Command-Option
/// makes an alias (the destination decides, as with Finder).
///
/// SwiftUI notices the drag (so it works inside the fan's rotated rows,
/// where an AppKit subview would not follow the rotation), then this hands
/// it to a real AppKit dragging session started from the overlay window.
///
/// React analogy: the SwiftUI side is an `onPointerMove` that calls a
/// shared, imperative drag API once the pointer has moved far enough.
final class StackItemDragSource: NSObject, NSDraggingSource {
    /// Cursor moved during the drag (screen coordinates).
    var onMoved: ((NSPoint) -> Void)?
    /// Drag finished; `operation` is empty when canceled or refused.
    var onEnded: ((NSDragOperation) -> Void)?

    private(set) var isDragging = false
    private let logger = Logger(subsystem: "com.james.portside", category: "Stacks")

    /// Starts the drag from the event being handled right now (the mouse
    /// drag SwiftUI is reporting). `translation` is how far the cursor has
    /// moved since the press, so the image starts where the press was.
    func begin(url: URL, icon: NSImage, size: CGFloat, translation: CGSize) {
        guard !isDragging,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let view = event.window?.contentView else { return }
        let location = view.convert(event.locationInWindow, from: nil)
        // SwiftUI's y grows downward; the content view's grows upward.
        let press = NSPoint(x: location.x - translation.width, y: location.y + translation.height)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: press.x - size / 2, y: press.y - size / 2, width: size, height: size), contents: icon)
        isDragging = true
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        logger.info("item drag started: \(url.lastPathComponent, privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: [.copy, .move, .link, .generic]
        default: [.copy, .move, .generic]
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onMoved?(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        logger.info("item drag ended, operation \(operation.rawValue)")
        onEnded?(operation)
    }
}

extension View {
    /// Click-and-drag on this view drags `url` out as a file. Taps still
    /// reach the view's own tap gesture.
    func stackItemDrag(url: URL, iconSize: CGFloat, source: StackItemDragSource) -> some View {
        gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard !source.isDragging else { return }
                    source.begin(url: url, icon: IconCache.shared.icon(for: url), size: iconSize, translation: value.translation)
                }
        )
    }
}
