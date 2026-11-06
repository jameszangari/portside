import AppKit
import CoreServices
import Foundation
import os.log

private let stackLogger = Logger(subsystem: "com.james.portside", category: "Stacks")

/// How an open stack lays out its items.
enum StackViewMode: String, Codable, CaseIterable, Identifiable {
    case grid, fan, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: "Grid"
        case .fan: "Fan"
        case .list: "List"
        }
    }
}

/// What orders a stack's items. `manual` is name order plus the order the
/// user set by dropping items at a chosen slot (`itemOrder`).
enum StackSortMode: String, Codable, CaseIterable, Identifiable {
    case manual, name, dateAdded, dateModified, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "Custom Order"
        case .name: "Name"
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        case .kind: "Kind"
        }
    }
}

/// A filesystem folder pinned in the dock's right section (before Trash),
/// separate from user-defined app groups. Opens as a grid, fan, or list.
struct FolderStack: Hashable, Identifiable {
    var id: String
    /// Absolute path to the folder.
    var path: String
    /// Preferred display order of child names (`lastPathComponent`). Missing
    /// names are appended (name-sorted). Empty means pure name sort. Only
    /// used while `sort` is `.manual`.
    var itemOrder: [String]
    var view: StackViewMode = .grid
    var sort: StackSortMode = .manual
    var foldersFirst = false
    var showHidden = false
    /// Tile shows the folder's own icon instead of a mini grid of contents.
    var showAsFolder = false
    /// Server URL (smb://, afp://, nfs://) of the network share the folder
    /// lives on. Nil for local folders. Clicking the tile while the share is
    /// not mounted mounts it again, like the native Dock.
    var remountURL: String?
    /// Set for a link tile instead of a folder: a server (smb://, afp://,
    /// vnc://) or web URL, like the native Dock's url-tile. `path` is empty,
    /// and clicking opens the URL instead of a grid.
    var linkURL: String?

    init(id: String = UUID().uuidString, path: String, itemOrder: [String] = []) {
        self.id = id
        self.path = (path as NSString).standardizingPath
        self.itemOrder = itemOrder
    }

    init?(folderURL: URL) {
        let url = folderURL.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        // Reject app bundles; other packages can still pin as folders.
        if url.pathExtension.lowercased() == "app" { return nil }
        self.init(path: url.path)
        remountURL = Self.remountURL(for: url)
    }

    /// A link tile for a non-file URL (a Network server from Finder, a web link).
    init?(link: URL) {
        guard !link.isFileURL, let scheme = link.scheme, !scheme.isEmpty else { return nil }
        self.init(path: "")
        linkURL = link.absoluteString
    }

    var isLink: Bool { linkURL != nil }

    var link: URL? { linkURL.flatMap(URL.init(string:)) }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// The share is gone (disconnected, or the Mac slept) but can be mounted again.
    var needsRemount: Bool {
        remountURL != nil && !FileManager.default.fileExists(atPath: path)
    }

    /// The server URL of the network volume holding `url`, or nil on a local volume.
    static func remountURL(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey])
        guard values?.volumeIsLocal == false else { return nil }
        return values?.volumeURLForRemounting?.absoluteString
    }

    var displayName: String {
        if let link { return link.host ?? link.absoluteString }
        return FileManager.default.displayName(atPath: path)
    }

    var hoverID: String { "stack:" + id }
}

extension FolderStack: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, path, itemOrder, view, sort, foldersFirst, showHidden, showAsFolder, remountURL, linkURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        itemOrder = try c.decodeIfPresent([String].self, forKey: .itemOrder) ?? []
        // Unknown values (a newer build wrote them) fall back to defaults.
        view = (try? c.decodeIfPresent(StackViewMode.self, forKey: .view)) ?? .grid
        sort = (try? c.decodeIfPresent(StackSortMode.self, forKey: .sort)) ?? .manual
        foldersFirst = (try? c.decodeIfPresent(Bool.self, forKey: .foldersFirst)) ?? false
        showHidden = (try? c.decodeIfPresent(Bool.self, forKey: .showHidden)) ?? false
        showAsFolder = (try? c.decodeIfPresent(Bool.self, forKey: .showAsFolder)) ?? false
        remountURL = try? c.decodeIfPresent(String.self, forKey: .remountURL)
        linkURL = try? c.decodeIfPresent(String.self, forKey: .linkURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        if !itemOrder.isEmpty {
            try c.encode(itemOrder, forKey: .itemOrder)
        }
        if view != .grid { try c.encode(view, forKey: .view) }
        if sort != .manual { try c.encode(sort, forKey: .sort) }
        if foldersFirst { try c.encode(true, forKey: .foldersFirst) }
        if showHidden { try c.encode(true, forKey: .showHidden) }
        if showAsFolder { try c.encode(true, forKey: .showAsFolder) }
        try c.encodeIfPresent(remountURL, forKey: .remountURL)
        try c.encodeIfPresent(linkURL, forKey: .linkURL)
    }
}

/// One entry inside a folder stack (file, folder, or app).
struct StackItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isApplication: Bool
    var dateAdded = Date.distantPast
    var dateModified = Date.distantPast
    /// Localized kind ("PDF Document", "Folder").
    var kind = ""
}

/// Lists and watches folder-stack contents. Event-driven via FSEvents; no
/// polling. Publishes each stack's raw, name-sorted listing; `items(for:)`
/// applies the stack's current sort and folders-first on read, so the
/// order always matches the settings the menu shows.
final class StackContents: ObservableObject {
    @Published private(set) var listings: [String: [StackItem]] = [:]

    private var streams: [String: FSEventStreamRef] = [:]
    private let queue = DispatchQueue(label: "com.james.portside.stacks", qos: .utility)
    private var reading = Set<String>()
    /// Stacks changed while a read was running, with their newest settings.
    private var readAgain: [String: FolderStack] = [:]

    deinit { stopAll() }

    func sync(stacks: [FolderStack]) {
        let ids = Set(stacks.map(\.id))
        for id in streams.keys where !ids.contains(id) {
            stopWatching(id)
            publish(id, nil, reason: "removed")
        }
        // Link tiles have nothing on disk to list or watch.
        for stack in stacks where !stack.isLink {
            if streams[stack.id] == nil {
                watch(stack)
                watchedPaths[stack.id] = stack
                refresh(stack, reason: "sync")
                continue
            }
            let previous = watchedPaths[stack.id]
            watchedPaths[stack.id] = stack
            // Only the path and hidden-file filter change what is on disk;
            // sort and folders-first are applied in `items(for:)`.
            if previous?.path != stack.path || previous?.showHidden != stack.showHidden {
                refresh(stack, reason: "sync")
            }
        }
    }

    func items(for stack: FolderStack) -> [StackItem] {
        Self.arrange(listings[stack.id] ?? [], for: stack)
    }

    func refresh(_ stack: FolderStack, reason: String) {
        guard !stack.isLink else { return }
        let id = stack.id
        if reading.contains(id) {
            readAgain[id] = stack
            return
        }
        reading.insert(id)
        let url = stack.url
        let showHidden = stack.showHidden
        queue.async { [weak self] in
            let raw = Self.list(url, showHidden: showHidden)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading.remove(id)
                if let newest = self.readAgain.removeValue(forKey: id),
                   newest.showHidden != showHidden || newest.path != stack.path {
                    // Listing inputs changed; the raw result is the wrong set.
                    self.refresh(newest, reason: "\(reason) (again)")
                    return
                }
                self.publish(id, raw, reason: reason)
            }
        }
    }

    private func publish(_ id: String, _ listed: [StackItem]?, reason: String) {
        guard listings[id] != listed else { return }
        var next = listings
        next[id] = listed
        listings = next
        if let listed {
            let name = watchedPaths[id]?.displayName ?? id
            stackLogger.info("stack \(name, privacy: .public): \(listed.count) item(s) (\(reason, privacy: .public))")
        }
    }

    /// Applies the stack's sort and "folders first" to a name-sorted listing.
    static func arrange(_ listed: [StackItem], for stack: FolderStack) -> [StackItem] {
        func byName(_ a: StackItem, _ b: StackItem) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var items: [StackItem]
        switch stack.sort {
        case .manual:
            items = applyOrder(listed, order: stack.itemOrder)
        case .name:
            items = listed.sorted(by: byName)
        case .dateAdded:
            items = listed.sorted { $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : byName($0, $1) }
        case .dateModified:
            items = listed.sorted { $0.dateModified != $1.dateModified ? $0.dateModified > $1.dateModified : byName($0, $1) }
        case .kind:
            items = listed.sorted {
                let order = $0.kind.localizedStandardCompare($1.kind)
                return order != .orderedSame ? order == .orderedAscending : byName($0, $1)
            }
        }
        if stack.foldersFirst {
            items = items.filter(\.isDirectory) + items.filter { !$0.isDirectory }
        }
        return items
    }

    /// Name-sorted listing, then `order` (filenames) applied when non-empty.
    static func applyOrder(_ listed: [StackItem], order: [String]) -> [StackItem] {
        guard !order.isEmpty else { return listed }
        var remaining = Dictionary(uniqueKeysWithValues: listed.map { ($0.url.lastPathComponent, $0) })
        var result: [StackItem] = []
        result.reserveCapacity(listed.count)
        for name in order {
            if let item = remaining.removeValue(forKey: name) {
                result.append(item)
            }
        }
        let rest = remaining.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.append(contentsOf: rest)
        return result
    }

    private static func list(_ url: URL, showHidden: Bool) -> [StackItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isApplicationKey, .isPackageKey,
            .addedToDirectoryDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
        ]
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" && (showHidden || !$0.hasPrefix(".")) }
            .compactMap { name -> StackItem? in
                let itemURL = url.appendingPathComponent(name)
                let values = try? itemURL.resourceValues(forKeys: keys)
                let isApp = values?.isApplication == true || itemURL.pathExtension.lowercased() == "app"
                let isDir = values?.isDirectory == true && !isApp
                return StackItem(
                    url: itemURL,
                    name: fm.displayName(atPath: itemURL.path),
                    isDirectory: isDir,
                    isApplication: isApp,
                    dateAdded: values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast,
                    dateModified: values?.contentModificationDate ?? .distantPast,
                    kind: values?.localizedTypeDescription ?? ""
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func watch(_ stack: FolderStack) {
        let id = stack.id
        guard streams[id] == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // Re-sync is driven from the main actor via refresh ids stored
            // alongside the stream; see setEventHandler style below.
            let contents = Unmanaged<StackContents>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { contents.eventFired() }
        }
        // One stream per stack path; id is recovered in eventFired via paths.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [stack.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            stackLogger.error("can't watch \(stack.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            return
        }
        streams[id] = stream
        watchedPaths[id] = stack
    }

    /// Stack currently associated with each watch id (for event → refresh).
    private var watchedPaths: [String: FolderStack] = [:]
    private var pendingEventRefresh = false

    private func eventFired() {
        // Coalesce bursts into one pass over every watched stack.
        guard !pendingEventRefresh else { return }
        pendingEventRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingEventRefresh = false
            for stack in self.watchedPaths.values {
                self.refresh(stack, reason: "folder changed")
            }
        }
    }

    private func stopWatching(_ id: String) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        watchedPaths[id] = nil
    }

    func stopAll() {
        for id in Array(streams.keys) { stopWatching(id) }
        listings = [:]
    }
}
