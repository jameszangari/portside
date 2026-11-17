import AppKit
import CoreServices
import Foundation
import os.log

/// Tells the index that something under a root changed. The live one is
/// FSEvents (a public API, one stream for the chosen roots, kernel
/// coalesced); tests drive a fake. It carries no file names the index uses:
/// a change only marks the root stale, and the next scan reads the disk.
@MainActor
protocol FileChangeWatching: AnyObject {
    /// Replaces any earlier watch. `onChange` gets the changed paths.
    func watch(_ paths: [String], onChange: @escaping @MainActor ([String]) -> Void)
    func stop()
}

@MainActor
final class FSEventsWatcher: FileChangeWatching {
    private final class Box {
        let onChange: @MainActor ([String]) -> Void
        init(_ onChange: @escaping @MainActor ([String]) -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?
    private let queue = DispatchQueue(label: "com.james.portside.file-events", qos: .utility)

    func watch(_ paths: [String], onChange: @escaping @MainActor ([String]) -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        let retained = Unmanaged.passRetained(Box(onChange))
        var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let changed = Array(paths.prefix(count))
            DispatchQueue.main.async { MainActor.assumeIsolated { box.onChange(changed) } }
        }
        // 3 s latency: a burst of writes is one callback. Root watching
        // reports a root that moved or went away.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            retained.release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            retained.release()
            return
        }
        self.stream = stream
        box = retained
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        box?.release()
        box = nil
    }
}

/// The roots a person chose, in `command-center-file-roots.json` next to
/// dock.json (mode 0600). Paths only; the index itself is never written.
@MainActor
final class FileRootStore {
    private(set) var roots: [FileRoot] = []
    private let url: URL?
    private let logger = Logger(subsystem: "com.james.portside", category: "CommandCenter")

    init(url: URL?) {
        self.url = url
        roots = url.flatMap(Self.read) ?? []
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.james.portside").appendingPathComponent("command-center-file-roots.json")
    }

    func add(_ root: FileRoot) {
        roots.append(root)
        save()
    }

    func remove(id: UUID) {
        roots.removeAll { $0.id == id }
        save()
    }

    private struct File: Codable {
        var version = 1
        var roots: [FileRoot]
    }

    private struct Element: Decodable {
        let value: FileRoot?
        init(from decoder: Decoder) throws { value = try? FileRoot(from: decoder) }
    }

    private struct LenientFile: Decodable {
        var roots: [Element]
    }

    /// A malformed, relative, repeated or too broad entry (a hand edited "/")
    /// is skipped alone.
    private static func read(_ url: URL) -> [FileRoot]? {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(LenientFile.self, from: data) else { return nil }
        var seen = Set<UUID>()
        var paths = Set<String>()
        return file.roots.compactMap(\.value)
            // Canonical (a root saved by an older build may use /var for /private/var).
            .map { FileRoot(id: $0.id, path: FileAccess.realPath($0.path) ?? $0.path) }
            .filter { $0.path.hasPrefix("/") && !FileRootRules.isTooBroad($0.path, home: NSHomeDirectory()) && seen.insert($0.id).inserted && paths.insert($0.path).inserted }
            .prefix(FileRootRules.limit)
            .map { $0 }
    }

    private func save() {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(roots: roots))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = url.deletingLastPathComponent().appendingPathComponent(".file-roots-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        } catch {
            logger.error("file roots not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum FileRootState: Equatable {
    case notScanned
    case scanning
    case indexed(Int)
    case truncated(Int)
    case missing
    case unreadable
    /// The Files module is off.
    case off

    var text: String {
        switch self {
        case .off: return "Not indexed (Files is off)"
        case .notScanned: return "Not indexed yet"
        case .scanning: return "Indexing…"
        case .indexed(let count): return count == 1 ? "1 item" : "\(count) items"
        case .truncated(let count): return "\(count) items (stopped at the limit)"
        case .missing: return "Not found. Check that the folder and its drive are there."
        case .unreadable: return "macOS did not let Portside read it. Allow it in Privacy & Security > Files and Folders."
        }
    }
}

/// The file index for Command Center (P2-CMD-03). In memory only, built in
/// the background from the chosen roots, bounded (entries, depth, time),
/// and gone the moment a root is removed or the module stops. FSEvents only
/// marks a root stale; stale roots are rescanned when Command Center opens
/// or on Refresh, never in a loop. Nothing scans the disk outside a root.
@MainActor
final class FileIndexService: ObservableObject {
    static let shared = FileIndexService(store: FileRootStore(url: FileRootStore.defaultURL))

    @Published private(set) var roots: [FileRoot] = []
    @Published private(set) var states: [UUID: FileRootState] = [:]
    /// The `files` module runs.
    @Published private(set) var isActive = false
    private(set) var entries: [FileEntry] = []

    private let store: FileRootStore
    private let watcher: any FileChangeWatching
    private let limits: FileScanLimits
    private let scan: @Sendable (FileRoot, FileScanLimits) async -> FileScanResult
    private let probe: @Sendable (FileRoot) async -> FileScanOutcome
    private var perRoot: [UUID: [FileEntry]] = [:]
    private var stale = Set<UUID>()
    private var generation: [UUID: Int] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var memo: (query: String, count: Int, rows: [FileEntry])?
    /// Runs after any change to what is indexed (Command Center re-reads).
    var onChange: (@MainActor () -> Void)?

    init(
        store: FileRootStore,
        watcher: (any FileChangeWatching)? = nil,
        limits: FileScanLimits = FileScanLimits(),
        scan: @escaping @Sendable (FileRoot, FileScanLimits) async -> FileScanResult = { root, limits in
            await FileIndexService.cancellableScan(root, limits)
        },
        probe: @escaping @Sendable (FileRoot) async -> FileScanOutcome = { root in
            await Task.detached(priority: .utility) { FileScanner.probe(root) }.value
        }
    ) {
        self.store = store
        self.watcher = watcher ?? FSEventsWatcher()
        self.limits = limits
        self.scan = scan
        self.probe = probe
        roots = store.roots
    }

    /// A detached scan does not inherit its caller's cancellation, so this
    /// forwards it: removing a root or stopping the module stops the walk at
    /// its next check instead of letting it run to its limits.
    static func cancellableScan(_ root: FileRoot, _ limits: FileScanLimits) async -> FileScanResult {
        let inner = Task.detached(priority: .utility) {
            FileScanner.scan(root: root, limits: limits, isCancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
    }

    var unavailableReason: String? {
        if !isActive { return "Files is turned off." }
        if roots.isEmpty { return "Choose a folder to search in Settings > General > Command Center." }
        return nil
    }

    var isEmptyOfRoots: Bool { roots.isEmpty }
    var rootPaths: [String] { roots.map(\.path) }

    // MARK: Module

    func activate() {
        isActive = true
        startWatching()
    }

    func deactivate() {
        isActive = false
        watcher.stop()
        cancelAll()
        purge()
        FileThumbnails.purge()
        for root in roots { states[root.id] = .notScanned }
        onChange?()
    }

    // MARK: Roots

    func addRoot(_ path: String) -> Result<FileRoot, FileRootRules.Problem> {
        switch FileRootRules.validate(path, existing: rootPaths) {
        case .failure(let problem): return .failure(problem)
        case .success(let resolved):
            let root = FileRoot(path: resolved)
            store.add(root)
            roots = store.roots
            states[root.id] = .notScanned
            stale.insert(root.id)
            if isActive {
                startWatching()
                refresh()
            }
            return .success(root)
        }
    }

    /// Revoking a folder purges its entries at once and stops any scan of it.
    func removeRoot(id: UUID) {
        generation[id, default: 0] += 1
        tasks[id]?.cancel()
        tasks[id] = nil
        store.remove(id: id)
        roots = store.roots
        perRoot[id] = nil
        states[id] = nil
        stale.remove(id)
        FileThumbnails.purge()
        rebuild()
        if isActive { startWatching() }
        onChange?()
    }

    // MARK: Index

    /// Scans every root that has never been read or has changed since, or
    /// all of them when `force`. Returns when those scans finish.
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never> {
        guard isActive else { return Task {} }
        var running: [Task<Void, Never>] = []
        for root in roots {
            if !force, let inFlight = tasks[root.id] {
                // Already scanning: wait for that one instead of starting over.
                running.append(inFlight)
            } else if force || stale.contains(root.id) || perRoot[root.id] == nil {
                running.append(scanRoot(root))
            } else if perRoot[root.id]?.isEmpty == false {
                // Not rescanned: still check, on open, that it can be read.
                running.append(probeRoot(root))
            }
        }
        return Task { for task in running { await task.value } }
    }

    /// A fresh index whose folder went away or whose access macOS withdrew
    /// (Files and Folders in Privacy & Security) is dropped, not kept searchable.
    private func probeRoot(_ root: FileRoot) -> Task<Void, Never> {
        let mine = generation[root.id] ?? 0
        let probe = probe
        return Task { [weak self] in
            let outcome = await probe(root)
            guard let self, outcome != .complete, outcome != .canceled, self.isActive,
                  self.generation[root.id] == mine, self.tasks[root.id] == nil,
                  self.roots.contains(where: { $0.id == root.id }) else { return }
            self.perRoot[root.id] = []
            self.states[root.id] = outcome == .unreadable ? .unreadable : .missing
            FileThumbnails.purge()
            self.rebuild()
            self.onChange?()
        }
    }

    private func scanRoot(_ root: FileRoot) -> Task<Void, Never> {
        tasks[root.id]?.cancel()
        let mine = (generation[root.id] ?? 0) + 1
        generation[root.id] = mine
        states[root.id] = .scanning
        stale.remove(root.id)
        let budget = max(5_000, limits.maxEntries / max(roots.count, 1))
        var limits = limits
        limits.maxEntries = budget
        let scan = scan
        let task = Task { [weak self] in
            let result = await scan(root, limits)
            self?.finishScan(root, result, generation: mine)
        }
        tasks[root.id] = task
        return task
    }

    private func finishScan(_ root: FileRoot, _ result: FileScanResult, generation mine: Int) {
        // A removed root, a newer scan or a stopped module drops this one.
        guard isActive, generation[root.id] == mine, roots.contains(where: { $0.id == root.id }) else { return }
        tasks[root.id] = nil
        switch result.outcome {
        case .canceled:
            return
        case .missing:
            perRoot[root.id] = []
            states[root.id] = .missing
        case .unreadable:
            perRoot[root.id] = []
            states[root.id] = .unreadable
        case .complete:
            perRoot[root.id] = result.entries
            states[root.id] = .indexed(result.entries.count)
        case .truncated:
            perRoot[root.id] = result.entries
            states[root.id] = .truncated(result.entries.count)
        }
        rebuild()
        onChange?()
    }

    private func rebuild() {
        entries = roots.flatMap { perRoot[$0.id] ?? [] }
        memo = nil
    }

    private func purge() {
        perRoot = [:]
        stale = []
        entries = []
        memo = nil
    }

    private func cancelAll() {
        for (id, task) in tasks {
            task.cancel()
            generation[id, default: 0] += 1
        }
        tasks = [:]
    }

    // MARK: Watching

    private func startWatching() {
        guard isActive, !roots.isEmpty else {
            watcher.stop()
            return
        }
        watcher.watch(rootPaths) { [weak self] changed in self?.markStale(changed) }
    }

    /// A change under a root (or to the root itself) marks it stale.
    func markStale(_ changed: [String]) {
        for root in roots where changed.contains(where: { $0 == root.path || $0.hasPrefix(root.path + "/") || root.path.hasPrefix($0 + "/") }) {
            stale.insert(root.id)
        }
    }

    func isStale(_ id: UUID) -> Bool { stale.contains(id) }

    /// The file's URL when it may be acted on now (see `FileAccess`).
    func authorize(_ path: String) -> Result<URL, CommandFailure> {
        if let reason = unavailableReason { return .failure(CommandFailure(reason: reason)) }
        return FileAccess.authorize(path, roots: rootPaths).mapError { CommandFailure(reason: $0.message) }
    }

    // MARK: Query

    /// Results for a query; nothing while off or without a folder.
    func results(for query: String) -> [FileEntry] {
        guard unavailableReason == nil else { return [] }
        if let memo, memo.query == query, memo.count == entries.count { return memo.rows }
        let rows = FileSearch.search(entries, query: query)
        memo = (query, entries.count, rows)
        return rows
    }
}

/// The optional `files` module: file name search over folders the person
/// chose. Off by default and held off by restricted mode (it indexes).
@MainActor
final class FilesModule: PortsideModule {
    static let moduleID = ModuleID("files")!
    static let openCommand = CommandID("files.open")!
    static let revealCommand = CommandID("files.reveal")!
    static let refreshCommand = CommandID("files.refresh")!
    static let openWithCommand = CommandID("files.openWith")!
    /// Separates the app path from the file path in `files.openWith` input.
    static let openWithSeparator: Character = "\u{1F}"

    let id = FilesModule.moduleID
    let title = "Files"
    let summary = "Searches the names of files and folders inside the folders you choose in Settings > General > Command Center, from Command Center. Names only, no contents, no full-disk scan, symbolic links are not followed. The index lives in memory, is rebuilt in the background when a chosen folder changed, and is dropped when you remove the folder or turn this off."
    let fallback = "Command Center, Spotlight and Finder search work the same without it."
    let dependencies: [ModuleDependency] = [.module(CommandCenterModule.moduleID)]

    let index: FileIndexService
    private let actions: FileActions

    init(index: FileIndexService, actions: FileActions = .none) {
        self.index = index
        self.actions = actions
    }

    func commands() -> [CommandDescriptor] {
        let path = CommandInputSchema.string(maxLength: 4096)
        return [
            CommandDescriptor(
                id: Self.openCommand,
                title: "Open File",
                symbolName: "doc",
                input: path,
                handler: { [index, actions] input in
                    Self.authorized(input, index).flatMap { url in
                        actions.open(url) ? .success(nil) : .failure(CommandFailure(reason: "macOS could not open \(url.lastPathComponent)."))
                    }
                }
            ),
            CommandDescriptor(
                id: Self.openWithCommand,
                title: "Open File With…",
                symbolName: "arrow.up.forward.app",
                input: .string(maxLength: 8300),
                handler: { [index, actions] input in
                    // "<app path><US><file path>": the app must be a real .app bundle, the
                    // file is checked against the roots like any other.
                    guard case .string(let text) = input,
                          let split = text.firstIndex(of: Self.openWithSeparator) else { return .failure(CommandFailure(reason: "No app given.")) }
                    let appPath = String(text[..<split]), filePath = String(text[text.index(after: split)...])
                    var isDirectory: ObjCBool = false
                    guard appPath.hasPrefix("/"), appPath.hasSuffix(".app"), !appPath.contains("\0"),
                          FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                        return .failure(CommandFailure(reason: "That app is no longer there."))
                    }
                    return Self.authorized(.string(filePath), index).flatMap { url in
                        actions.openWith(url, URL(fileURLWithPath: appPath))
                            ? .success(nil)
                            : .failure(CommandFailure(reason: "macOS could not open \(url.lastPathComponent) with that app."))
                    }
                }
            ),
            CommandDescriptor(
                id: Self.revealCommand,
                title: "Show in Finder",
                symbolName: "folder",
                input: path,
                handler: { [index, actions] input in
                    Self.authorized(input, index).map { url in
                        actions.reveal(url)
                        return nil
                    }
                }
            ),
            CommandDescriptor(
                id: Self.refreshCommand,
                title: "Refresh File Index",
                keywords: ["files", "index", "search"],
                symbolName: "arrow.clockwise",
                unavailableReason: { [index] in index.unavailableReason },
                handler: { [index] _ in
                    await index.refresh(force: true).value
                    let total = index.entries.count
                    return .success(total == 1 ? "Indexed 1 item." : "Indexed \(total) items.")
                }
            ),
        ]
    }

    private static func authorized(_ input: CommandInput, _ index: FileIndexService) -> Result<URL, CommandFailure> {
        guard case .string(let path) = input else { return .failure(CommandFailure(reason: "No file given.")) }
        if let reason = index.unavailableReason { return .failure(CommandFailure(reason: reason)) }
        return FileAccess.authorize(path, roots: index.rootPaths).mapError { CommandFailure(reason: $0.message) }
    }

    func start(_ context: ModuleContext) throws {
        index.activate()
        context.onStop { [index] in
            MainActor.assumeIsolated { index.deactivate() }
        }
    }
}

/// What the file commands do outside Portside. Injected so tests never open a file.
struct FileActions {
    var open: @MainActor (URL) -> Bool
    var reveal: @MainActor (URL) -> Void
    var openWith: @MainActor (URL, URL) -> Bool = { _, _ in false }

    static let live = FileActions(
        open: { NSWorkspace.shared.open($0) },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        openWith: { file, app in
            // Fire and forget: macOS reports a launch failure through the handler only.
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
    )

    static let none = FileActions(open: { _ in false }, reveal: { _ in })
}
