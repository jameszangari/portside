import AppKit
import UniformTypeIdentifiers
import os.log

private let dropLogger = Logger(subsystem: "com.james.portside", category: "FileDrop")

/// What a file drag over the strip can do, decided once per drag from the
/// dragged URLs.
///
/// - `.pinApps`: every item is an `.app` bundle. Dropping on the strip pins
///   them among entries (insertion gap). Dropping on a folder stack (or its
///   open grid) deposits into that folder instead.
/// - `.pinFolders`: every item is a folder (not an app). Dropping pins them
///   as folder stacks in the right section.
/// - `.pinLinks`: no files, only non-file URLs (a Network server dragged
///   from Finder, a web link). Dropping pins them as link tiles among the
///   stacks, like the native Dock's url-tile.
/// - `.open`: anything else. App tiles that can open the items highlight;
///   folder stacks accept a deposit into the folder.
///
/// In any mode the Trash tile takes the drop instead when every item can
/// be moved to the Trash (`canTrash(using:)`).
final class FileDropSession {
    enum Mode { case pinApps, pinFolders, pinLinks, open }

    /// What the strip accepts: files, plus plain URLs for link tiles.
    static let dropTypes: [UTType] = [.fileURL, .url]

    private(set) var urls: [URL] = []
    /// Non-file URLs on the drag pasteboard. Only read when there are no files.
    private(set) var links: [URL] = []
    private(set) var mode: Mode = .open
    /// Per drag: app id -> can open every dragged item.
    private var verdicts: [String: Bool] = [:]
    /// Per drag: every item can go to the Trash. Nil until asked.
    private var trashVerdict: Bool?
    /// Per drag: every item can be deposited into a folder stack.
    private var depositVerdict: Bool?

    func begin() {
        let objects = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        urls = objects
        links = []
        verdicts = [:]
        trashVerdict = nil
        depositVerdict = nil
        if urls.isEmpty {
            let all = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            links = all.filter { !$0.isFileURL && $0.scheme?.isEmpty == false }
        }
        if urls.isEmpty, !links.isEmpty {
            mode = .pinLinks
        } else if urls.isEmpty {
            mode = .pinApps
        } else if urls.allSatisfy({ PinnedApp(appURL: $0) != nil }) {
            mode = .pinApps
        } else if urls.allSatisfy(Self.isPinableFolder) {
            mode = .pinFolders
        } else {
            mode = .open
        }
        let label: String
        switch mode {
        case .pinApps: label = "pin apps"
        case .pinFolders: label = "pin folders"
        case .pinLinks: label = "pin links"
        case .open: label = "open"
        }
        let types = NSPasteboard(name: .drag).types?.map(\.rawValue).joined(separator: ",") ?? ""
        dropLogger.info("drag over strip: \(self.urls.count) file(s), \(self.links.count) link(s), mode \(label, privacy: .public), types \(types, privacy: .public)")
    }

    func end() {
        urls = []
        links = []
        verdicts = [:]
        trashVerdict = nil
        depositVerdict = nil
        mode = .open
    }

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
            guard let id = app.bundleIdentifier else { return false }
            return candidates.contains { Bundle(url: $0)?.bundleIdentifier == id }
        }
        verdicts[app.id] = verdict
        let ms = (CACurrentMediaTime() - started) * 1000
        dropLogger.info("\(app.displayName, privacy: .public) can open: \(verdict) (\(ms, format: .fixed(precision: 2))ms)")
        return verdict
    }

    func canTrash(using trash: TrashController) -> Bool {
        if let trashVerdict { return trashVerdict }
        let verdict = !urls.isEmpty && urls.allSatisfy(trash.canTrash)
        trashVerdict = verdict
        dropLogger.info("can move to Trash: \(verdict)")
        return verdict
    }

    /// True if every dragged item can be moved or copied into a folder.
    func canDeposit() -> Bool {
        if let depositVerdict { return depositVerdict }
        let verdict = !urls.isEmpty && urls.allSatisfy { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path)
        }
        depositVerdict = verdict
        return verdict
    }

    static func isPinableFolder(_ url: URL) -> Bool {
        FolderStack(folderURL: url) != nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
