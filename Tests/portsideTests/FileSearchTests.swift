import Combine
import XCTest
@testable import portside

/// P2-CMD-03: scanning, root rules, access checks, search, the index
/// service and the file commands.
@MainActor
final class FileSearchTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var outside: URL!

    override func setUp() async throws {
        let temp = try FileActionsTests.canonicalTemp("files")
        base = temp
        root = temp.appendingPathComponent("root")
        outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Unreadable test folders need their mode back before removal.
        if let enumerator = FileManager.default.enumerator(atPath: base.path) {
            for case let name as String in enumerator { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(name).path) }
        }
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func make(_ relative: String, in parent: URL? = nil, folder: Bool = false) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(relative)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    private var fileRoot: FileRoot { FileRoot(path: root.path) }

    private func names(_ result: FileScanResult) -> [String] { result.entries.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } }

    // MARK: Scanner

    func testScanListsFilesAndFoldersAndSkipsHiddenAndPackages() throws {
        try make("a.txt")
        try make("docs/b.md")
        try make(".hidden/secret.txt")
        try make(".dotfile")
        try make("Thing.app/Contents/Info.plist")
        let result = FileScanner.scan(root: fileRoot)
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(Set(names(result)), ["a.txt", "docs", "docs/b.md", "Thing.app"], "no hidden files, no package insides")
    }

    func testScanNeverFollowsOrListsSymlinks() throws {
        try make("secret.txt", in: outside)
        try make("deep/hidden.txt", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-dir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-file"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try make("real.txt")
        let result = FileScanner.scan(root: fileRoot)
        XCTAssertEqual(names(result), ["real.txt"])
    }

    func testScanLimitsEntriesDepthAndSkippedFolders() throws {
        for i in 0..<20 { try make("f\(i).txt") }
        var limits = FileScanLimits()
        limits.maxEntries = 5
        let capped = FileScanner.scan(root: fileRoot, limits: limits)
        XCTAssertEqual(capped.entries.count, 5)
        XCTAssertEqual(capped.outcome, .truncated)

        let deepRoot = root.appendingPathComponent("deep")
        try make("l1/l2/l3/l4/file.txt", in: deepRoot)
        var shallow = FileScanLimits()
        shallow.maxDepth = 2
        let result = FileScanner.scan(root: FileRoot(path: deepRoot.path), limits: shallow)
        XCTAssertEqual(result.outcome, .truncated)
        XCTAssertFalse(result.entries.contains { $0.name == "file.txt" })

        try make("node_modules/pkg/index.js")
        let skipped = FileScanner.scan(root: fileRoot)
        XCTAssertFalse(skipped.entries.contains { $0.name == "index.js" })
        XCTAssertTrue(skipped.entries.contains { $0.name == "node_modules" }, "the folder is listed, not entered")
    }

    func testScanHonorsDeadlineAndCancel() throws {
        for i in 0..<50 { try make("d\(i)/f.txt") }
        var instant = FileScanLimits()
        instant.deadline = -1
        XCTAssertEqual(FileScanner.scan(root: fileRoot, limits: instant).outcome, .truncated)
        let canceled = FileScanner.scan(root: fileRoot, isCancelled: { true })
        XCTAssertEqual(canceled.outcome, .canceled)
        XCTAssertTrue(canceled.entries.isEmpty)
    }

    func testMissingSwappedAndUnreadableRoots() throws {
        XCTAssertEqual(FileScanner.scan(root: FileRoot(path: base.appendingPathComponent("nope").path)).outcome, .missing)
        let real = try make("real", in: base, folder: true)
        let swapped = base.appendingPathComponent("swapped")
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: real)
        XCTAssertEqual(FileScanner.scan(root: FileRoot(path: swapped.path)).outcome, .missing, "a root that became a link is not followed")
        let locked = try make("locked", in: base, folder: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertEqual(FileScanner.scan(root: FileRoot(path: locked.path)).outcome, .unreadable)
    }

    // MARK: Root rules

    func testRootRulesRefuseBroadAndOverlappingFolders() throws {
        let home = NSHomeDirectory()
        for path in ["/", "/Users", "/System", "/System/Library", "/private/etc", "/Volumes", home, "relative/path"] {
            if case .success = FileRootRules.validate(path, existing: []) { XCTFail("\(path) must be refused") }
        }
        XCTAssertEqual(FileRootRules.validate(root.path + "/missing", existing: []), .failure(.notAFolder))
        let file = try make("file.txt")
        XCTAssertEqual(FileRootRules.validate(file.path, existing: []), .failure(.notAFolder))
        XCTAssertEqual(FileRootRules.validate(root.path, existing: []), .success(root.path))
        XCTAssertEqual(FileRootRules.validate(root.path, existing: [root.path]), .failure(.duplicate))
        let child = try make("child", folder: true)
        if case .failure(.insideExisting) = FileRootRules.validate(child.path, existing: [root.path]) {} else { XCTFail("inside") }
        if case .failure(.containsExisting) = FileRootRules.validate(root.path, existing: [child.path]) {} else { XCTFail("contains") }
        XCTAssertEqual(FileRootRules.validate(root.path, existing: (0..<10).map { "/tmp/x\($0)" }), .failure(.limit))
    }

    func testRootRulesResolveSymlinkedChoice() throws {
        let link = base.appendingPathComponent("link-to-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertEqual(FileRootRules.validate(link.path, existing: []), .success(root.path))
    }

    // MARK: Access

    func testAuthorizeAcceptsOnlyRealFilesUnderARoot() throws {
        let inside = try make("ok.txt")
        let secret = try make("secret.txt", in: outside)
        XCTAssertEqual(FileAccess.authorize(inside.path, roots: [root.path]), .success(inside))
        XCTAssertEqual(FileAccess.authorize(secret.path, roots: [root.path]), .failure(.outsideRoots))
        XCTAssertEqual(FileAccess.authorize(root.path, roots: [root.path]), .failure(.outsideRoots), "the root itself is not a result")
        XCTAssertEqual(FileAccess.authorize(root.path + "/../outside/secret.txt", roots: [root.path]), .failure(.badPath))
        XCTAssertEqual(FileAccess.authorize("relative.txt", roots: [root.path]), .failure(.badPath))
        XCTAssertEqual(FileAccess.authorize(root.path + "/gone.txt", roots: [root.path]), .failure(.missing))
        XCTAssertEqual(FileAccess.authorize(root.path + "/a\0b", roots: [root.path]), .failure(.badPath))
        XCTAssertEqual(FileAccess.authorize(inside.path, roots: []), .failure(.outsideRoots), "revoked root")
        XCTAssertEqual(FileAccess.authorize(root.path + "x/ok.txt", roots: [root.path]), .failure(.outsideRoots), "prefix is not containment")
    }

    func testAuthorizeBlocksSymlinkAndSymlinkedParentEscapes() throws {
        let secret = try make("secret.txt", in: outside)
        let link = root.appendingPathComponent("link-file")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertEqual(FileAccess.authorize(link.path, roots: [root.path]), .failure(.symlink))
        let dirLink = root.appendingPathComponent("link-dir")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: outside)
        XCTAssertEqual(FileAccess.authorize(dirLink.path + "/secret.txt", roots: [root.path]), .failure(.escapes))
    }

    // MARK: Search

    private func entry(_ name: String, _ folder: String = "/r") -> FileEntry {
        FileEntry(path: "\(folder)/\(name)", name: name, isDirectory: false, rootID: UUID())
    }

    func testSearchRanksWholeNamePrefixWordThenAnywhere() {
        let entries = [entry("my-report-final.pdf"), entry("report"), entry("Reporting.txt"), entry("xreportx.md"), entry("report.pdf"), entry("unrelated")]
        XCTAssertEqual(FileSearch.search(entries, query: "report").map(\.name), ["report", "report.pdf", "Reporting.txt", "my-report-final.pdf", "xreportx.md"])
        XCTAssertEqual(FileSearch.search(entries, query: "final report").map(\.name), ["my-report-final.pdf"], "term order does not matter")
        XCTAssertEqual(FileSearch.search(entries, query: "report zzz").map(\.name), [], "all terms must be in the name")
        XCTAssertEqual(FileSearch.search(entries, query: "REPORT FINAL").map(\.name), ["my-report-final.pdf"])
    }

    func testSearchIsFoldedBoundedAndNeedsTwoCharacters() {
        let entries = [entry("Café Menu.pdf")] + (0..<30).map { entry("note\($0).txt") }
        XCTAssertEqual(FileSearch.search(entries, query: "cafe").map(\.name), ["Café Menu.pdf"])
        XCTAssertEqual(FileSearch.search(entries, query: "note").count, FileSearch.resultLimit)
        XCTAssertTrue(FileSearch.search(entries, query: "n").isEmpty)
        XCTAssertTrue(FileSearch.search(entries, query: "").isEmpty)
        XCTAssertEqual(FileSearch.search(entries, query: "note"), FileSearch.search(entries.reversed(), query: "note"), "input order never matters")
    }

    // MARK: Store

    func testRootStorePersistsPrivatelyAndReadsLeniently() throws {
        let url = base.appendingPathComponent("roots.json")
        let store = FileRootStore(url: url)
        store.add(FileRoot(path: root.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(FileRootStore(url: url).roots.map(\.path), [root.path])
        let id = UUID().uuidString
        try """
        {"version":1,"roots":[{"id":"\(id)","path":"/tmp/a"},{"id":"\(id)","path":"/tmp/dup-id"},{"id":"\(UUID())","path":"relative"},{"id":"\(UUID())","path":"/"},{"id":"\(UUID())","path":"\(NSHomeDirectory())"},{"id":"bad","path":"/x"},{"path":"/y"},3]}
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileRootStore(url: url).roots.map(\.path), ["/tmp/a"])
        let first = FileRootStore(url: url)
        first.remove(id: first.roots[0].id)
        XCTAssertTrue(FileRootStore(url: url).roots.isEmpty)
    }

    // MARK: Service

    @MainActor private final class FakeWatcher: FileChangeWatching {
        var watched: [[String]] = []
        var stops = 0
        var onChange: (@MainActor ([String]) -> Void)?
        func watch(_ paths: [String], onChange: @escaping @MainActor ([String]) -> Void) { watched.append(paths); self.onChange = onChange }
        func stop() { stops += 1; onChange = nil }
    }

    private final class ScanScript: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var scans: Int { lock.withLock { count } }
        var results: @Sendable (FileRoot) -> FileScanResult = { root in
            FileScanResult(entries: [FileEntry(path: root.path + "/one.txt", name: "one.txt", isDirectory: false, rootID: root.id)], outcome: .complete)
        }
        var gate: DispatchSemaphore?
        func hit() { lock.withLock { count += 1 } }
    }

    private func service(_ script: ScanScript, watcher: FakeWatcher? = nil, roots: [String] = []) -> FileIndexService {
        let watcher = watcher ?? FakeWatcher()
        let store = FileRootStore(url: nil)
        for path in roots { store.add(FileRoot(path: path)) }
        return FileIndexService(store: store, watcher: watcher, scan: { root, _ in
            script.hit()
            script.gate?.wait()
            return script.results(root)
        })
    }

    func testIndexScansOnActivateAndOnlyStaleRootsAfter() async throws {
        let script = ScanScript(), watcher = FakeWatcher()
        let index = service(script, watcher: watcher)
        XCTAssertEqual(index.unavailableReason, "Files is turned off.")
        index.activate()
        XCTAssertEqual(index.unavailableReason, "Choose a folder to search in Settings > General > Command Center.")
        guard case .success(let added) = index.addRoot(root.path) else { return XCTFail() }
        await index.refresh().value
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.states[added.id], .indexed(1))
        XCTAssertEqual(watcher.watched.last, [root.path])
        let after = script.scans
        await index.refresh().value
        XCTAssertEqual(script.scans, after, "a fresh index is not rescanned")
        watcher.onChange?([root.path + "/sub/changed.txt"])
        XCTAssertTrue(index.isStale(added.id))
        await index.refresh().value
        XCTAssertEqual(script.scans, after + 1)
        XCTAssertFalse(index.isStale(added.id))
        index.markStale(["/somewhere/else"])
        XCTAssertFalse(index.isStale(added.id), "changes outside the roots are ignored")
        await index.refresh(force: true).value
        XCTAssertEqual(script.scans, after + 2)
    }

    func testRemovingARootPurgesAtOnceAndDropsItsInFlightScan() async throws {
        let script = ScanScript()
        let index = service(script)
        index.activate()
        guard case .success(let added) = index.addRoot(root.path) else { return XCTFail() }
        await index.refresh().value
        XCTAssertEqual(FileAccess.authorize(root.path + "/one.txt", roots: index.rootPaths).isSuccess, false, "file does not exist, but the root is current")
        index.removeRoot(id: added.id)
        XCTAssertTrue(index.entries.isEmpty)
        XCTAssertTrue(index.results(for: "one").isEmpty)
        XCTAssertTrue(index.rootPaths.isEmpty)

        let gate = DispatchSemaphore(value: 0)
        script.gate = gate
        guard case .success(let second) = index.addRoot(base.appendingPathComponent("root").path) else { return XCTFail("\(index.roots)") }
        let task = index.refresh(force: true)
        index.removeRoot(id: second.id)
        gate.signal(); gate.signal()
        await task.value
        XCTAssertTrue(index.entries.isEmpty, "a scan that finishes after removal delivers nothing")
        XCTAssertNil(index.states[second.id])
    }

    func testDeactivatePurgesEverythingAndStopsWatching() async throws {
        let script = ScanScript(), watcher = FakeWatcher()
        let index = service(script, watcher: watcher)
        index.activate()
        _ = index.addRoot(root.path)
        await index.refresh().value
        XCTAssertFalse(index.results(for: "one").isEmpty)
        let stops = watcher.stops
        let before = script.scans
        index.deactivate()
        XCTAssertTrue(index.entries.isEmpty)
        XCTAssertTrue(index.results(for: "one").isEmpty)
        XCTAssertGreaterThan(watcher.stops, stops)
        XCTAssertEqual(index.refresh(force: true) != nil, true)
        XCTAssertEqual(script.scans, before, "a stopped index never scans")
    }

    func testMissingAndUnreadableRootsShowStatesAndKeepNoEntries() async throws {
        let script = ScanScript()
        script.results = { _ in FileScanResult(entries: [], outcome: .missing) }
        let index = service(script)
        index.activate()
        guard case .success(let added) = index.addRoot(root.path) else { return XCTFail() }
        await index.refresh().value
        XCTAssertEqual(index.states[added.id], .missing)
        script.results = { _ in FileScanResult(entries: [], outcome: .unreadable) }
        await index.refresh(force: true).value
        XCTAssertEqual(index.states[added.id], .unreadable)
        script.results = { root in FileScanResult(entries: [FileEntry(path: root.path + "/a", name: "a", isDirectory: false, rootID: root.id)], outcome: .truncated) }
        await index.refresh(force: true).value
        XCTAssertEqual(index.states[added.id], .truncated(1))
        XCTAssertFalse(FileRootState.unreadable.text.isEmpty)
    }

    func testResultsAreMemoizedPerQuery() async throws {
        let script = ScanScript()
        let index = service(script)
        index.activate()
        _ = index.addRoot(root.path)
        await index.refresh().value
        XCTAssertEqual(index.results(for: "one").map(\.name), ["one.txt"])
        XCTAssertEqual(index.results(for: "one").map(\.name), ["one.txt"])
    }

    // MARK: Module and rows

    private func commands(_ index: FileIndexService, opened: @escaping (URL) -> Void = { _ in }, revealed: @escaping (URL) -> Void = { _ in }) throws -> CommandRegistry {
        let module = FilesModule(index: index, actions: FileActions(open: { opened($0); return true }, reveal: { revealed($0) }))
        let registry = CommandRegistry()
        for command in module.commands() { try registry.register(command) }
        return registry
    }

    func testOpenAndRevealRecheckThePathAgainstTheRoots() async throws {
        let inside = try make("ok.txt")
        let secret = try make("secret.txt", in: outside)
        let index = service(ScanScript())
        index.activate()
        _ = index.addRoot(root.path)
        var opened: [URL] = [], revealed: [URL] = []
        let registry = try commands(index, opened: { opened.append($0) }, revealed: { revealed.append($0) })
        let ok = await registry.execute(FilesModule.openCommand, input: .string(inside.path))
        XCTAssertEqual(ok, .success(nil))
        XCTAssertEqual(opened, [inside])
        let refused = await registry.execute(FilesModule.openCommand, input: .string(secret.path))
        XCTAssertEqual(refused, .failed(FileAccess.Denial.outsideRoots.message))
        let shown = await registry.execute(FilesModule.revealCommand, input: .string(inside.path))
        XCTAssertEqual(shown, .success(nil))
        XCTAssertEqual(revealed, [inside])
        let reveal2 = await registry.execute(FilesModule.revealCommand, input: .string(secret.path))
        if case .failed = reveal2 {} else { XCTFail("outside root") }
        XCTAssertEqual(opened.count, 1)
        let link = root.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let linked = await registry.execute(FilesModule.openCommand, input: .string(link.path))
        XCTAssertEqual(linked, .failed(FileAccess.Denial.symlink.message))
        index.removeRoot(id: index.roots[0].id)
        let revoked = await registry.execute(FilesModule.openCommand, input: .string(inside.path))
        if case .failed = revoked {} else { XCTFail("a removed root must refuse") }
        XCTAssertEqual(opened.count, 1)
    }

    func testRefreshCommandIsManualAndReportsCount() async throws {
        let script = ScanScript()
        let index = service(script)
        index.activate()
        _ = index.addRoot(root.path)
        let registry = try commands(index)
        let result = await registry.execute(FilesModule.refreshCommand)
        XCTAssertEqual(result, .success("Indexed 1 item."))
        index.deactivate()
        let off = await registry.execute(FilesModule.refreshCommand)
        if case .unavailable = off {} else { XCTFail("off: \(off)") }
    }

    func testModuleIsSensitiveAndPurgesWhenStopped() throws {
        let index = service(ScanScript())
        let module = FilesModule(index: index)
        XCTAssertTrue(module.isSensitive)
        XCTAssertFalse(module.isRequired)
        XCTAssertEqual(module.id.rawValue, "files")
        XCTAssertEqual(module.dependencies.count, 1)
    }

    func testRowsOpenByPathAndAreSessionOnly() throws {
        let open = CommandDescriptor(id: FilesModule.openCommand, title: "Open File", input: .string(maxLength: 4096)) { _ in .success(nil) }
        let reveal = CommandDescriptor(id: FilesModule.revealCommand, title: "Show in Finder", input: .string(maxLength: 4096)) { _ in .success(nil) }
        let file = FileEntry(path: root.path + "/Notes/plan.md", name: "plan.md", isDirectory: false, rootID: UUID())
        let folder = FileEntry(path: root.path + "/Notes", name: "Notes", isDirectory: true, rootID: UUID())
        let items = CommandCenterCatalog.fileItems([file, folder], open: open, reveal: reveal)
        XCTAssertEqual(items[0].id, .file(file.path))
        XCTAssertEqual(items[0].kind, .file)
        XCTAssertEqual(items[0].primaryTitle, "Open File")
        XCTAssertEqual(items[1].primaryTitle, "Open Folder")
        XCTAssertEqual(items[0].invocation, CommandInvocation(command: FilesModule.openCommand, input: .string(file.path)))
        XCTAssertEqual(items[0].moreActions.map(\.title), ["Show in Finder"])
        XCTAssertEqual(items[0].copyValue, file.path)
        XCTAssertEqual(items[0].iconPath, file.path)
        XCTAssertNil(CommandCenterResultID(rawValue: items[0].id.rawValue), "never read back from history")
        var state = CommandCenterState()
        _ = state.send(.open(items))
        _ = state.send(.key(.return))
        let outcome = state.send(.finished(items[0].id, .success(nil)))
        XCTAssertFalse(outcome.effects.contains(.recordUsage(items[0].id)), "file names are not written to history")
    }

    // MARK: Review fixes

    func testRootRulesJudgeTheCanonicalPlace() throws {
        for path in ["/etc", "/etc/ssh", "/private/etc", "/private/etc/ssh", "/var", "/var/db", "/private/var/db", "/Library",
                     "/Library/Application Support", "/usr/local", "/System/Library"] {
            switch FileRootRules.validate(path, existing: []) {
            case .failure(.tooBroad), .failure(.notAFolder): break
            default: XCTFail("\(path) must not be accepted")
            }
        }
        XCTAssertEqual(FileRootRules.validate("/etc/ssh", existing: []), .failure(.tooBroad), "a Foundation resolve returned /etc/ssh unchanged")
        // A symlink to a system folder is judged by where it leads.
        let link = base.appendingPathComponent("to-etc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/ssh"))
        XCTAssertEqual(FileRootRules.validate(link.path, existing: []), .failure(.tooBroad))
        // The per-user temp area and a normal folder are fine, stored canonical.
        XCTAssertEqual(FileRootRules.validate(root.path, existing: []), .success(root.path))
        XCTAssertTrue(root.path.hasPrefix("/private/var/folders/"))
    }

    func testStoredRootsAreCanonicalAndABroadOneIsDropped() throws {
        let url = base.appendingPathComponent("roots.json")
        let viaVar = "/var" + root.path.dropFirst("/private/var".count)
        try """
        {"version":1,"roots":[{"id":"\(UUID())","path":"\(viaVar)"},{"id":"\(UUID())","path":"/etc"},{"id":"\(UUID())","path":"/private/var/db"}]}
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileRootStore(url: url).roots.map(\.path), [root.path])
    }

    func testScanStopsWhenCanceledMidDirectory() throws {
        for i in 0..<600 { try make("f\(i).txt") }
        var calls = 0
        let result = FileScanner.scan(root: fileRoot, isCancelled: {
            calls += 1
            return calls > 1
        })
        XCTAssertEqual(result.outcome, .canceled)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertLessThan(calls, 10, "checked inside the folder, not only between folders")
    }

    func testCancelledCallerReachesTheDetachedScan() async throws {
        for i in 0..<300 { try make("d\(i)/f.txt") }
        let root = fileRoot
        let task = Task { await FileIndexService.cancellableScan(root, FileScanLimits()) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .canceled, "cancellation crossed into the detached task")
        let finished = await FileIndexService.cancellableScan(root, FileScanLimits())
        XCTAssertNotEqual(finished.outcome, .canceled)
    }

    func testRemovingARootCancelsItsRealScan() async throws {
        for i in 0..<200 { try make("d\(i)/f.txt") }
        let index = FileIndexService(store: FileRootStore(url: nil), watcher: NullWatcher2())
        index.activate()
        guard case .success(let added) = index.addRoot(root.path) else { return XCTFail() }
        let task = index.refresh(force: true)
        index.removeRoot(id: added.id)
        await task.value
        XCTAssertTrue(index.entries.isEmpty)
        XCTAssertNil(index.states[added.id])
        XCTAssertTrue(index.rootPaths.isEmpty)
    }

    @MainActor private final class NullWatcher2: FileChangeWatching {
        func watch(_ paths: [String], onChange: @escaping @MainActor ([String]) -> Void) {}
        func stop() {}
    }

    func testThumbnailsArePurgedWhenARootIsRemovedOrTheModuleStops() async throws {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let file = root.appendingPathComponent("pic.png")
        try png.write(to: file)
        let index = FileIndexService(store: FileRootStore(url: nil), watcher: NullWatcher2(), scan: { root, _ in
            FileScanResult(entries: [], outcome: .complete)
        })
        index.activate()
        guard case .success(let added) = index.addRoot(root.path) else { return XCTFail() }
        _ = await FileThumbnails.load(file, scale: 2)
        XCTAssertNotNil(FileThumbnails.cached(file.path))
        index.removeRoot(id: added.id)
        XCTAssertNil(FileThumbnails.cached(file.path), "revoking a folder drops what was drawn from it")
        XCTAssertThrowsError(try index.authorize(file.path).get(), "and the view's authorization check now fails")
        _ = index.addRoot(root.path)
        _ = await FileThumbnails.load(file, scale: 2)
        XCTAssertNotNil(FileThumbnails.cached(file.path))
        index.deactivate()
        XCTAssertNil(FileThumbnails.cached(file.path), "stopping the module drops them too")
    }

    func testOpenDropsAnIndexWhoseFolderLostAccessOrWentAway() async throws {
        let outcome = ProbeBox()
        let script = ScanScript()
        let store = FileRootStore(url: nil)
        let index = FileIndexService(store: store, watcher: NullWatcher2(), scan: { root, _ in
            script.hit()
            return script.results(root)
        }, probe: { _ in outcome.value })
        index.activate()
        guard case .success(let added) = index.addRoot(root.path) else { return XCTFail() }
        await index.refresh().value
        XCTAssertEqual(index.entries.count, 1)
        outcome.value = .complete
        await index.refresh().value
        XCTAssertEqual(index.entries.count, 1, "readable: kept")
        outcome.value = .unreadable
        await index.refresh().value
        XCTAssertTrue(index.entries.isEmpty, "access withdrawn: purged, not searchable")
        XCTAssertEqual(index.states[added.id], .unreadable)
        XCTAssertTrue(index.results(for: "one").isEmpty)
        outcome.value = .missing
        await index.refresh(force: true).value
        let scans = script.scans
        await index.refresh().value
        XCTAssertEqual(script.scans, scans, "a probe never rescans")
    }

    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = FileScanOutcome.complete
        var value: FileScanOutcome {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func testProbeReportsReadability() throws {
        XCTAssertEqual(FileScanner.probe(fileRoot), .complete)
        XCTAssertEqual(FileScanner.probe(FileRoot(path: base.appendingPathComponent("nope").path)), .missing)
        let locked = try make("locked", in: base, folder: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertEqual(FileScanner.probe(FileRoot(path: locked.path)), .unreadable)
    }

    func testAuthorizeAcceptsCanonicalPathsUnderPrivate() throws {
        let file = try make("ok.txt")
        XCTAssertTrue(file.path.hasPrefix("/private/"))
        XCTAssertEqual(FileAccess.authorize(file.path, roots: [root.path]), .success(file))
        XCTAssertFalse(FileAccess.isNormalized("/a/../b"))
        XCTAssertFalse(FileAccess.isNormalized("/a//b"))
        XCTAssertFalse(FileAccess.isNormalized("/a/./b"))
        XCTAssertFalse(FileAccess.isNormalized("/a/b/"))
        XCTAssertTrue(FileAccess.isNormalized("/a/b"))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

/// The real FSEvents stream (public API), not a fake: a write under a
/// watched root reaches the callback. Latency is 3 s, so this waits.
@MainActor
final class FSEventsWatcherTests: XCTestCase {
    func testWriteUnderWatchedRootIsReportedAndStopSilencesIt() async throws {
        let dir = try FileActionsTests.canonicalTemp("fsev")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FSEventsWatcher()
        let reported = expectation(description: "change reported")
        reported.assertForOverFulfill = false
        var paths: [String] = []
        watcher.watch([dir.path]) { changed in
            paths += changed
            reported.fulfill()
        }
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: dir.appendingPathComponent("new.txt"))
        await fulfillment(of: [reported], timeout: 10)
        XCTAssertTrue(paths.contains { $0.hasPrefix(dir.path) || $0.hasPrefix("/private" + dir.path) }, "\(paths)")
        watcher.stop()
        let count = paths.count
        try Data("y".utf8).write(to: dir.appendingPathComponent("later.txt"))
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(paths.count, count, "a stopped watch reports nothing")
    }
}
