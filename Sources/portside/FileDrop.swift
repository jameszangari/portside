import AppKit
import os.log

private let dropLogger = Logger(subsystem: "com.james.portside", category: "FileDrop")

/// What a file drag over the strip can do, decided once per drag from the
/// dragged URLs.
///
/// - `.pin`: every item is an `.app` bundle. Dropping anywhere on the strip
///   (empty space, between tiles, or on a tile) pins them at the slot under
///   the cursor, like before. App tiles never highlight.
/// - `.open`: anything else. Only an app tile whose app can open every item
///   highlights and accepts the drop; everything else rejects it.
///
/// React analogy: a ref holding per-drag state (no re-render on change).
/// The highlighted tile id lives in the strip's @State instead.
final class FileDropSession {
    enum Mode { case pin, open }

    private(set) var urls: [URL] = []
    private(set) var mode: Mode = .open
    /// Per drag: app id -> can open every dragged item. Launch Services is
    /// asked once per tile per drag, not on every dropUpdated.
    private var verdicts: [String: Bool] = [:]

    /// Reads the dragged file URLs from the drag pasteboard. DropInfo's item
    /// providers only load asynchronously, but the pasteboard is readable
    /// synchronously while the drag is over us, so the highlight can follow
    /// the cursor without waiting.
    func begin() {
        let objects = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        urls = objects
        verdicts = [:]
        // Empty means the pasteboard could not be read. Fall back to pin
        // mode (the providers load later), so dropping apps still works.
        mode = urls.allSatisfy({ PinnedApp(appURL: $0) != nil }) ? .pin : .open
        dropLogger.info("drag over strip: \(self.urls.count) item(s), mode \(self.mode == .pin ? "pin" : "open", privacy: .public)")
    }

    func end() {
        urls = []
        verdicts = [:]
        mode = .open
    }

    /// True if `app` can open every dragged item. Finder always takes
    /// folders (it opens them in a window).
    func canOpen(with app: PinnedApp) -> Bool {
        if let cached = verdicts[app.id] { return cached }
        let started = CACurrentMediaTime()
        let appURL = app.url.resolvingSymlinksInPath().standardizedFileURL
        let verdict = !urls.isEmpty && urls.allSatisfy { url in
            if app.bundleIdentifier == "com.apple.finder", url.hasDirectoryPath || Self.isDirectory(url) { return true }
            let candidates = NSWorkspace.shared.urlsForApplications(toOpen: url)
            if candidates.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == appURL.path }) {
                return true
            }
            // Same app at another path (a copy, or a stale saved path).
            guard let id = app.bundleIdentifier else { return false }
            return candidates.contains { Bundle(url: $0)?.bundleIdentifier == id }
        }
        verdicts[app.id] = verdict
        let ms = (CACurrentMediaTime() - started) * 1000
        dropLogger.info("\(app.displayName, privacy: .public) can open: \(verdict) (\(ms, format: .fixed(precision: 2))ms)")
        return verdict
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
