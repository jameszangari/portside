import AppKit
import CoreServices
import Foundation
import os.log

private let stackLogger = Logger(subsystem: "com.james.portside", category: "Stacks")

/// A filesystem folder pinned in the dock's right section (before Trash),
/// separate from user-defined app groups. Grid view only in this slice;
/// fan and list come later.
struct FolderStack: Hashable, Identifiable {
    var id: String
    /// Absolute path to the folder.
    var path: String
    /// Preferred display order of child names (`lastPathComponent`). Missing
    /// names are appended (name-sorted). Empty means pure name sort.
    var itemOrder: [String]

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
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var displayName: String {
        FileManager.default.displayName(atPath: path)
    }

    var hoverID: String { "stack:" + id }
}

extension FolderStack: Codable {
    private enum CodingKeys: String, CodingKey { case id, path, itemOrder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        itemOrder = try c.decodeIfPresent([String].self, forKey: .itemOrder) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        if !itemOrder.isEmpty {
            try c.encode(itemOrder, forKey: .itemOrder)
        }
    }
}

/// One entry inside a folder stack (file, folder, or app).
struct StackItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isApplication: Bool
}

/// Lists and watches folder-stack contents. Event-driven via FSEvents; no
/// polling. Publishes per-stack item lists for tiles and the open grid.
final class StackContents: ObservableObject {
    @Published private(set) var items: [String: [StackItem]] = [:]

    private var streams: [String: FSEventStreamRef] = [:]
    private let queue = DispatchQueue(label: "com.james.portside.stacks", qos: .utility)
    private var reading = Set<String>()
    private var readAgain = Set<String>()

    deinit { stopAll() }

    func sync(stacks: [FolderStack]) {
        let ids = Set(stacks.map(\.id))
        for id in streams.keys where !ids.contains(id) {
            stopWatching(id)
            items[id] = nil
        }
        for stack in stacks {
            if streams[stack.id] == nil { watch(stack) }
            refresh(stack, reason: "sync")
        }
    }

    func items(for stack: FolderStack) -> [StackItem] {
        items[stack.id] ?? []
    }

    func refresh(_ stack: FolderStack, reason: String) {
        let id = stack.id
        if reading.contains(id) {
            readAgain.insert(id)
            return
        }
        reading.insert(id)
        let url = stack.url
        let order = stack.itemOrder
        queue.async { [weak self] in
            let listed = Self.applyOrder(Self.list(url), order: order)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading.remove(id)
                if self.items[id] != listed {
                    self.items[id] = listed
                    stackLogger.info("stack \(stack.displayName, privacy: .public): \(listed.count) item(s) (\(reason, privacy: .public))")
                }
                if self.readAgain.remove(id) != nil {
                    self.refresh(stack, reason: "\(reason) (again)")
                }
            }
        }
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

    private static func list(_ url: URL) -> [StackItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" && !$0.hasPrefix(".") }
            .compactMap { name -> StackItem? in
                let itemURL = url.appendingPathComponent(name)
                let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isApplicationKey, .isPackageKey])
                let isApp = values?.isApplication == true || itemURL.pathExtension.lowercased() == "app"
                let isDir = values?.isDirectory == true && !isApp
                return StackItem(
                    url: itemURL,
                    name: fm.displayName(atPath: itemURL.path),
                    isDirectory: isDir,
                    isApplication: isApp
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
        items = [:]
    }
}
