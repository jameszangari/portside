import AppKit
import SwiftUI
import os.log

/// Drag an item out of the dock (or out of an open group grid) to remove
/// it, like the native Dock.
///
/// The strip and the grid keep their own drag gestures; this object only
/// answers "is the cursor clearly outside?", shows the floating icon with a
/// "Remove" label near the cursor while it is, plays the poof on release,
/// and handles Escape. Event driven: it runs only from the gesture's
/// changes, a key monitor and a mouse-up monitor installed for the drag.
/// The one timer is the one-shot that removes the poof once it has played.
///
/// Escape: Portside is never the active app, so key presses go to the
/// frontmost app. For the length of the drag the overlay panel takes key
/// focus without activating Portside (like inline group rename) and gives
/// it back when the drag ends or is canceled.
///
/// React analogy: a small store that both the strip and the grid dispatch
/// to; the overlay is a portal that renders from it.
final class DragOutController {
    /// Where a drag started, which decides the region it has to leave.
    enum Source { case strip, grid }

    /// How far past the region's edge (any direction) the cursor must be
    /// before a release removes the item.
    static let threshold: CGFloat = 24

    /// Dock panel frame on screen (nil while hidden).
    var stripRegion: (() -> NSRect?)?
    /// Open group grid's card on screen (nil when no grid is open).
    var gridRegion: (() -> NSRect?)?
    /// A drag began (true) or finished, dropped or canceled (false).
    var onDraggingChanged: ((Bool) -> Void)?
    /// The dock's background, so the "Remove" label matches it.
    var look: (() -> DockLook?)?

    private(set) var isDragging = false
    private var token = 0
    private var canceled = false
    private var isOutside = false
    private var source: Source = .strip
    /// The current (or last) drag started on the strip, not in a grid.
    var isFromStrip: Bool { source == .strip }
    private var itemID = ""
    private var onCancel: (() -> Void)?
    private var removable = true
    private var monitor: Any?
    private var pendingDismiss: DispatchWorkItem?

    private let overlay = OverlayPanel()
    private let state = DragOutState()
    /// A removal is waiting on a confirmation; the overlay is still up.
    private var isDeferred = false
    private let logger = Logger(subsystem: "com.james.portside", category: "DragOut")

    /// The poof's length. The overlay is removed right after it.
    static let poofDuration: TimeInterval = 0.3

    /// Start tracking a drag. `preview` is drawn `size` points tall
    /// (the caller sizes it). `onCancel` runs on Escape: put the item back.
    /// Returns a token for the other calls, so a gesture that never saw its
    /// end cannot touch the next drag.
    /// With `removable` false (Trash) leaving the dock never offers removal.
    func begin(itemID: String, source: Source, label: String, preview: AnyView, size: CGFloat,
               removable: Bool = true, onCancel: @escaping () -> Void) -> Int {
        if isDragging {
            finish(remove: false, reason: "a new drag started")
        }
        pendingDismiss?.cancel()
        pendingDismiss = nil
        if isDeferred { resolve(remove: false) }
        token += 1
        isDragging = true
        canceled = false
        isOutside = false
        self.source = source
        self.itemID = itemID
        self.removable = removable
        self.onCancel = onCancel
        state.label = label
        state.look = look?()
        state.preview = preview
        state.size = size
        state.phase = .inside
        overlay.present(AnyView(DragOutView(state: state)), anchor: anchor(at: NSEvent.mouseLocation), edge: .bottom, gap: 0)
        overlay.beginKeyFocus()
        installMonitor()
        logger.info("drag started: \(itemID, privacy: .public) from the \(source == .strip ? "strip" : "grid", privacy: .public), overlay key: \(self.overlay.isKey)")
        onDraggingChanged?(true)
        return token
    }

    func isCanceled(_ token: Int) -> Bool {
        token != self.token || !isDragging || canceled
    }

    /// The cursor moved. Returns true while it is clearly outside the
    /// region (a release now would remove the item).
    @discardableResult
    func update(_ token: Int) -> Bool {
        guard !isCanceled(token) else { return false }
        let point = NSEvent.mouseLocation
        let region = source == .strip ? stripRegion?() : gridRegion?()
        let outside = removable && (region.map { !$0.insetBy(dx: -Self.threshold, dy: -Self.threshold).contains(point) } ?? false)
        if outside != isOutside {
            isOutside = outside
            state.phase = outside ? .outside : .inside
            (outside ? NSCursor.disappearingItem : NSCursor.arrow).set()
            logger.info("\(self.itemID, privacy: .public) \(outside ? "outside, release removes" : "back over the dock", privacy: .public)")
        }
        overlay.reanchor(anchor(at: point))
        return outside
    }

    /// The gesture ended (mouse up). Returns true if the item should be
    /// removed now; the poof is already playing.
    ///
    /// With `deferResolution`, a removal keeps the overlay up with no poof
    /// until the caller reports the outcome through `resolve(remove:)` (used
    /// while a confirmation alert is shown).
    func end(_ token: Int, deferResolution: Bool = false) -> Bool {
        guard token == self.token, isDragging else { return false }
        let remove = !canceled && isOutside
        finish(remove: remove, deferResolution: deferResolution && remove,
               reason: canceled ? "canceled" : (remove ? "dropped outside" : "dropped inside"))
        return remove
    }

    /// Ends a deferred removal: the poof if it went ahead, else the overlay
    /// just goes away.
    func resolve(remove: Bool) {
        guard isDeferred else { return }
        isDeferred = false
        logger.info("deferred removal resolved: \(remove ? "removing" : "kept", privacy: .public)")
        finishOverlay(poof: remove)
    }

    // MARK: - Private

    private func finish(remove: Bool, deferResolution: Bool = false, reason: String) {
        removeMonitor()
        overlay.endKeyFocus()
        isDragging = false
        canceled = false
        isOutside = false
        onCancel = nil
        NSCursor.arrow.set()
        logger.info("drag ended (\(reason, privacy: .public)): \(self.itemID, privacy: .public)\(remove ? ", removing" : "", privacy: .public)")
        if deferResolution {
            isDeferred = true
        } else {
            finishOverlay(poof: remove)
        }
        onDraggingChanged?(false)
    }

    private func finishOverlay(poof: Bool) {
        if poof && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            state.phase = .poof
            let work = DispatchWorkItem { [weak self] in
                self?.pendingDismiss = nil
                self?.overlay.dismiss()
            }
            pendingDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.poofDuration, execute: work)
        } else {
            overlay.dismiss()
        }
    }

    private func cancel() {
        guard isDragging, !canceled else { return }
        canceled = true
        isOutside = false
        state.phase = .inside
        NSCursor.arrow.set()
        // Typing goes back to the frontmost app right away; the dock stays
        // up until the button is released.
        overlay.endKeyFocus()
        logger.info("drag canceled with Escape: \(self.itemID, privacy: .public)")
        onCancel?()
        onCancel = nil
    }

    /// Escape cancels. The mouse up is watched too: if the view that owned
    /// the gesture went away mid-drag, its end never comes, so the drag is
    /// closed here (after the gesture had its turn).
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.cancel()
                return nil
            }
            let token = self.token
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isDragging, self.token == token else { return }
                self.finish(remove: false, reason: "mouse up without a gesture end")
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// A zero-size anchor under the cursor such that the overlay content,
    /// placed above it (`edge: .bottom`), has its preview centered on the cursor.
    /// The "Remove" label sits above the preview inside the laid-out size (not
    /// clipped by the hosting view), so measuring from the bottom keeps the
    /// icon under the cursor whether or not the label is showing.
    private func anchor(at point: NSPoint) -> NSRect {
        let pad = DragOutView.padding(for: state.size)
        let half = state.size / 2 + pad
        return NSRect(x: point.x, y: point.y - half, width: 0, height: 0)
    }
}

/// What the overlay shows. Observed by `DragOutView`.
final class DragOutState: ObservableObject {
    enum Phase { case inside, outside, poof }
    @Published var phase: Phase = .inside
    var label = "Remove"
    var preview = AnyView(EmptyView())
    var size: CGFloat = 48
    var look: DockLook?
}

/// The floating item under the cursor for the whole drag. While over the
/// dock the strip leaves a gap (tile opacity 0); when clearly outside, a
/// "Remove" label sits above the icon. React analogy: a drag portal that
/// stays mounted for the gesture, not only for the "outside" phase.
struct DragOutView: View {
    @ObservedObject var state: DragOutState

    /// Room around the preview for the poof to grow into.
    static func padding(for size: CGFloat) -> CGFloat { (size * 0.4).rounded() }

    var body: some View {
        let pad = Self.padding(for: state.size)
        // Label is in the layout (not offset outside a fixed frame) so the
        // overlay panel grows to fit and AppKit does not clip the text.
        VStack(spacing: 4) {
            if state.phase == .outside, !state.label.isEmpty {
                DockLabel(title: state.label)
            }
            ZStack {
                if state.phase == .poof {
                    PoofView(preview: state.preview, size: state.size)
                } else {
                    state.preview
                        .scaleEffect(1.06)
                }
            }
            .frame(width: state.size, height: state.size)
        }
        .padding(pad)
    }
}

/// Scale up and fade the item while a ring of small puffs drifts out.
private struct PoofView: View {
    let preview: AnyView
    let size: CGFloat
    @State private var played = false

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi + .pi / 8
                let distance = played ? size * 0.6 : size * 0.15
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .blur(radius: size * 0.03)
                    .scaleEffect(played ? 1.3 : 0.5)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                    .opacity(played ? 0 : 0.9)
            }
            preview
                .scaleEffect(played ? 1.5 : 1)
                .opacity(played ? 0 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: DragOutController.poofDuration)) { played = true }
        }
    }
}
