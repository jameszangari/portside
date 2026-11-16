import AppKit
import SwiftUI
import os.log

/// The shelf's Files page store (SHELF-06b): files dropped on the notch,
/// kept as paths in `notch-shelf-files.json` for the chosen time. One
/// cancelable timer removes each item when it expires; nothing polls.
/// Main queue only.
final class NotchFileShelf: ObservableObject {
    static let shared = NotchFileShelf(url: NotchFileShelf.defaultURL)

    @Published private(set) var tray = NotchFileTray()
    /// Set from Top Notch settings.
    var keep = NotchFilesKeep.day {
        didSet { if keep != oldValue { prune() } }
    }

    private let url: URL?
    private var expiry: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.james.portside", category: "NotchFiles")

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.james.portside").appendingPathComponent("notch-shelf-files.json")
    }

    /// `url` nil keeps the tray in memory (tests, previews).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder.iso.decode(NotchFileTray.self, from: data) {
            tray = saved
        }
        prune()
    }

    var items: [NotchFileTray.Item] { tray.items }

    func add(_ urls: [URL]) {
        guard tray.add(urls) else { return }
        logger.info("files: \(self.tray.items.count, privacy: .public) on the shelf")
        changed()
    }

    func remove(_ id: UUID) {
        tray.remove(id)
        changed()
    }

    func removeAll() {
        tray.removeAll()
        changed()
    }

    /// Drops expired and missing files; run when the page shows and when
    /// the timer fires.
    func prune() {
        if tray.prune(keep: keep.seconds, exists: { FileManager.default.fileExists(atPath: $0) }) { changed() } else { schedule() }
    }

    private func changed() {
        save()
        schedule()
    }

    private func schedule() {
        expiry?.cancel()
        expiry = nil
        guard let next = tray.nextExpiry(keep: keep.seconds) else { return }
        let task = DispatchWorkItem { [weak self] in self?.prune() }
        expiry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow + 0.5), execute: task)
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(tray).write(to: url, options: .atomic)
        } catch {
            logger.error("files: not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Render probe only: shows `urls` without saving or pruning.
    func preview(_ urls: [URL]) {
        var next = NotchFileTray()
        next.add(urls)
        tray = next
    }
    #endif

    /// Hands files to AirDrop's picker. Portside comes forward so the picker
    /// can take the keyboard.
    static func airDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return false }
        NSApp.activate()
        service.perform(withItems: urls)
        return true
    }

    /// The file on the general pasteboard, as Finder's Copy puts it.
    static func copy(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A file tile's mouse handling, in AppKit so the end of a drag out is
/// known (SwiftUI's `onDrag` never says whether the drop happened): a
/// click opens, a drag hands the file out as a copy, right click shows the
/// menu. The top right corner is left to the SwiftUI remove button.
struct NotchFileDragSource: NSViewRepresentable {
    let url: URL
    var onOpen: () -> Void
    /// The drag ended; true when something took the file.
    var onDragEnded: (Bool) -> Void
    var menu: () -> NSMenu

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.url = url
        view.onOpen = onOpen
        view.onDragEnded = onDragEnded
        view.makeMenu = menu
    }

    final class SourceView: NSView, NSDraggingSource {
        var url: URL?
        var onOpen: () -> Void = {}
        var onDragEnded: (Bool) -> Void = { _ in }
        var makeMenu: () -> NSMenu = { NSMenu() }
        private var downAt: NSPoint?
        private var dragging = false
        /// Held for the length of a drag: the shelf may close under it, and
        /// the end of the session still has to arrive.
        private static var active: SourceView?

        /// The remove button's corner.
        static let cornerInset: CGFloat = 24

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            if local.x > bounds.width - Self.cornerInset, local.y < Self.cornerInset { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            downAt = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downAt, !dragging, let url else { return }
            let point = event.locationInWindow
            guard hypot(point.x - downAt.x, point.y - downAt.y) > 4 else { return }
            dragging = true
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let size: CGFloat = 48
            let local = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: local.x - size / 2, y: local.y - size / 2, width: size, height: size), contents: icon)
            Self.active = self
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer { downAt = nil }
            guard downAt != nil, !dragging else { return }
            onOpen()
        }

        override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            downAt = nil
            Self.active = nil
            onDragEnded(operation != [])
        }
    }
}
