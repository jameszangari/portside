import AppKit
import Carbon.HIToolbox
import XCTest
@testable import portside

/// Open With, Show in Finder shortcut and the in-panel Quick Look screen.
@MainActor
final class FileActionsTests: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUp() async throws {
        base = try Self.canonicalTemp("fileactions")
        root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    /// A new temp folder by its canonical path (`/private/var/...`), the form roots use.
    static func canonicalTemp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: try XCTUnwrap(FileAccess.realPath(url.path)))
    }

    private func descriptor(_ id: CommandID) -> CommandDescriptor {
        CommandDescriptor(id: id, title: id.rawValue, input: .string(maxLength: 8300)) { _ in .success(nil) }
    }

    private func rows(apps: [URL] = [], folder: Bool = false) -> [CommandCenterItem] {
        let file = FileEntry(path: root.path + "/song.als", name: "song.als", isDirectory: folder, rootID: UUID())
        return CommandCenterCatalog.fileItems(
            [file], open: descriptor(FilesModule.openCommand), reveal: descriptor(FilesModule.revealCommand),
            openWith: descriptor(FilesModule.openWithCommand), apps: { _ in apps }
        )
    }

    // MARK: Rows and actions

    func testFileRowsOfferOpenWithQuickLookAndFinderShortcut() throws {
        let live = URL(fileURLWithPath: "/Applications/Ableton Live 12 Suite.app")
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let item = try XCTUnwrap(rows(apps: [live, preview]).first)
        XCTAssertTrue(item.previewable)
        XCTAssertEqual(item.moreActions.map(\.title), ["Show in Finder", "Open With Ableton Live 12 Suite", "Open With Preview"])
        XCTAssertEqual(item.moreActions[0].shortcut, "⌘⇧F")
        XCTAssertEqual(item.moreActions[1].invocation,
                       CommandInvocation(command: FilesModule.openWithCommand, input: .string(live.path + "\u{1F}" + item.copyValue)))
        let state = CommandCenterState()
        let panel = state.actions(for: item)
        XCTAssertEqual(panel.map(\.title), ["Open File", "Show Details", "Quick Look", "Show in Finder", "Open With Ableton Live 12 Suite", "Open With Preview", "Copy Path"])
        XCTAssertEqual(panel.first { $0.kind == .quickLook }?.shortcut, "⌘Y")
        XCTAssertEqual(panel.first { $0.title == "Show in Finder" }?.shortcut, "⌘⇧F")
    }

    func testFoldersAndUnavailableCommandsGetNoPreviewOrOpenWith() throws {
        let folder = try XCTUnwrap(rows(apps: [URL(fileURLWithPath: "/Applications/A.app")], folder: true).first)
        XCTAssertFalse(folder.previewable)
        let file = FileEntry(path: root.path + "/a.txt", name: "a.txt", isDirectory: false, rootID: UUID())
        let none = CommandCenterCatalog.fileItems([file], open: descriptor(FilesModule.openCommand), reveal: nil,
                                                  openWith: nil, apps: { _ in [URL(fileURLWithPath: "/Applications/A.app")] })
        XCTAssertFalse(none[0].moreActions.contains { $0.title.hasPrefix("Open With") })
    }

    // MARK: Keys and screens

    func testKeyMappingForQuickLookAndReveal() {
        XCTAssertEqual(CommandCenterKey(keyCode: UInt16(kVK_ANSI_Y), modifiers: .command, characters: "y", isComposing: false), .commandY)
        XCTAssertEqual(CommandCenterKey(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command, .shift], characters: "F", isComposing: false), .commandShiftF)
        XCTAssertNil(CommandCenterKey(keyCode: UInt16(kVK_ANSI_F), modifiers: .command, characters: "f", isComposing: false))
        XCTAssertNil(CommandCenterKey(keyCode: UInt16(kVK_ANSI_Y), modifiers: .command, characters: "y", isComposing: true), "IME composing")
    }

    private func opened() throws -> (CommandCenterState, CommandCenterItem) {
        var state = CommandCenterState()
        let item = try XCTUnwrap(rows(apps: [URL(fileURLWithPath: "/System/Applications/Preview.app")]).first)
        _ = state.send(.open([item]))
        _ = state.send(.query("song"))
        _ = state.send(.results(CommandCenterSearchRequest(generation: state.searchGeneration, query: "song"), [item.id]))
        return (state, item)
    }

    func testCommandYTogglesThePreviewScreenAndEscPopsIt() throws {
        var (state, item) = try opened()
        XCTAssertEqual(state.selection, item.id)
        let pushed = state.send(.key(.commandY))
        XCTAssertEqual(state.stack, [.preview(item.id)])
        XCTAssertEqual(pushed.effects, [.announce("Preview of song.als.")])
        XCTAssertEqual(state.mode, .screen)
        _ = state.send(.key(.commandY))
        XCTAssertTrue(state.stack.isEmpty, "⌘Y again closes it")
        _ = state.send(.key(.commandY))
        _ = state.send(.key(.escape))
        XCTAssertTrue(state.stack.isEmpty, "Esc pops one step")
        XCTAssertTrue(state.isVisible)
    }

    func testQuickLookFromTheActionPanelAndDetailsOnTop() throws {
        var (state, item) = try opened()
        _ = state.send(.key(.commandK))
        _ = state.send(.performAction(.quickLook))
        XCTAssertEqual(state.stack, [.preview(item.id)])
        XCTAssertNil(state.actionPanel)
        XCTAssertFalse(state.actions(for: item).contains { $0.kind == .quickLook }, "already previewing")
        XCTAssertTrue(state.actions(for: item).contains { $0.kind == .showDetails })
        _ = state.send(.key(.commandReturn))
        XCTAssertEqual(state.stack, [.preview(item.id), .details(item.id)])
    }

    func testCommandYDoesNothingOnRowsWithoutPreview() {
        var state = CommandCenterState()
        let command = CommandCenterItem(id: CommandID("a.b")!, title: "Thing")
        _ = state.send(.open([command]))
        let outcome = state.send(.key(.commandY))
        XCTAssertTrue(outcome.handled)
        XCTAssertTrue(state.stack.isEmpty)
    }

    func testCommandShiftFRunsShowInFinderOnly() throws {
        var (state, item) = try opened()
        let outcome = state.send(.key(.commandShiftF))
        XCTAssertEqual(outcome.effects, [.runAction(item.id, 0)])
        XCTAssertEqual(state.mode, .running)
        let command = CommandCenterItem(id: CommandID("a.b")!, title: "Thing")
        var other = CommandCenterState()
        _ = other.send(.open([command]))
        XCTAssertTrue(other.send(.key(.commandShiftF)).effects.isEmpty, "rows without a reveal action ignore it")
    }

    // MARK: Open With command

    private func registry(opened: @escaping (URL, URL) -> Void, files: [String]? = nil) throws -> (CommandRegistry, FileIndexService) {
        let store = FileRootStore(url: nil)
        let index = FileIndexService(store: store, watcher: NullWatcher(), scan: { _, _ in FileScanResult(entries: [], outcome: .complete) })
        index.activate()
        _ = index.addRoot(root.path)
        let module = FilesModule(index: index, actions: FileActions(open: { _ in true }, reveal: { _ in },
                                                                    openWith: { opened($0, $1); return true }))
        let registry = CommandRegistry()
        for command in module.commands() { try registry.register(command) }
        return (registry, index)
    }

    @MainActor private final class NullWatcher: FileChangeWatching {
        func watch(_ paths: [String], onChange: @escaping @MainActor ([String]) -> Void) {}
        func stop() {}
    }

    func testOpenWithRunsOnlyForARealAppAndAnAuthorizedFile() async throws {
        let file = root.appendingPathComponent("song.als")
        try Data("x".utf8).write(to: file)
        let outside = base.appendingPathComponent("outside.txt")
        try Data("x".utf8).write(to: outside)
        let app = base.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var calls: [(URL, URL)] = []
        let (registry, _) = try registry(opened: { calls.append(($0, $1)) })
        let sep = String(FilesModule.openWithSeparator)

        let ok = await registry.execute(FilesModule.openWithCommand, input: .string(app.path + sep + file.path))
        XCTAssertEqual(ok, .success(nil))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, file)
        XCTAssertEqual(calls[0].1.path, app.path)

        let cases: [String] = [
            app.path + sep + outside.path,           // file outside the roots
            "/usr/bin/true" + sep + file.path,       // not an app bundle
            base.appendingPathComponent("Gone.app").path + sep + file.path,
            "relative.app" + sep + file.path,
            file.path,                               // no separator
            app.path + sep + root.path + "/../outside.txt",
        ]
        for input in cases {
            let result = await registry.execute(FilesModule.openWithCommand, input: .string(input))
            if case .failed = result {} else { XCTFail("must refuse \(input): \(result)") }
        }
        XCTAssertEqual(calls.count, 1)
    }

    func testOpenWithRefusesARevokedRoot() async throws {
        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let app = base.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var calls = 0
        let (registry, index) = try registry(opened: { _, _ in calls += 1 })
        index.removeRoot(id: index.roots[0].id)
        let result = await registry.execute(FilesModule.openWithCommand, input: .string(app.path + String(FilesModule.openWithSeparator) + file.path))
        if case .failed = result {} else { XCTFail("\(result)") }
        XCTAssertEqual(calls, 0)
    }

    // MARK: Preview URL and app list

    func testServicePreviewAuthorizationFollowsTheRoots() async throws {
        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let (_, index) = try registry(opened: { _, _ in })
        XCTAssertEqual(try index.authorize(file.path).get(), file)
        XCTAssertThrowsError(try index.authorize(base.appendingPathComponent("outside.txt").path).get())
        index.removeRoot(id: index.roots[0].id)
        XCTAssertThrowsError(try index.authorize(file.path).get(), "revoked")
    }

    func testOpenWithAppsListDefaultFirstThenByNameAndCachesByExtension() {
        var lookups = 0
        let a = URL(fileURLWithPath: "/Applications/Zed.app"), b = URL(fileURLWithPath: "/Applications/Alpha.app")
        let c = URL(fileURLWithPath: "/Applications/Mid.app")
        let apps = OpenWithApps(lookup: { _ in lookups += 1; return (c, [a, b, c, c]) })
        let first = apps.apps(for: URL(fileURLWithPath: "/x/one.TXT"))
        XCTAssertEqual(first, [c, b, a])
        XCTAssertEqual(apps.apps(for: URL(fileURLWithPath: "/y/two.txt")), first)
        XCTAssertEqual(lookups, 1, "cached by extension")
        _ = apps.apps(for: URL(fileURLWithPath: "/y/noext"))
        _ = apps.apps(for: URL(fileURLWithPath: "/y/noext"))
        XCTAssertEqual(lookups, 3, "no extension is not cached")
        let many = OpenWithApps(lookup: { _ in (nil, (0..<20).map { URL(fileURLWithPath: "/Applications/App\($0).app") }) })
        XCTAssertEqual(many.apps(for: URL(fileURLWithPath: "/x/a.md")).count, OpenWithApps.limit)
    }
}

/// Media preview pieces and row thumbnails.
@MainActor
final class MediaPreviewTests: XCTestCase {
    func testMediaKindFollowsTheFileType() {
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/song.wav")), .audio)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/song.MP3")), .audio)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/clip.mov")), .video)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/clip.mp4")), .video)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/pic.png")), .other)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/doc.pdf")), .other)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/noext")), .other)
        XCTAssertEqual(MediaKind.of(URL(fileURLWithPath: "/a/x.als")), .other)
    }

    func testClockFormatting() {
        XCTAssertEqual(MediaPlayerModel.clock(0), "0:00")
        XCTAssertEqual(MediaPlayerModel.clock(3.9), "0:03")
        XCTAssertEqual(MediaPlayerModel.clock(65), "1:05")
        XCTAssertEqual(MediaPlayerModel.clock(3725), "1:02:05")
        XCTAssertEqual(MediaPlayerModel.clock(.nan), "0:00")
        XCTAssertEqual(MediaPlayerModel.clock(-1), "0:00")
    }

    func testPlayerModelStartsStopsAndClosesWithoutAFile() {
        let model = MediaPlayerModel(url: URL(fileURLWithPath: "/nonexistent/none.wav"))
        model.start()
        XCTAssertTrue(model.isPlaying)
        model.toggle()
        XCTAssertFalse(model.isPlaying)
        model.seek(to: 0.5)
        XCTAssertEqual(model.progress, 0, "nothing to seek in before the duration is known")
        model.close()
        model.close()
    }

    func testThumbnailOfARealImageIsGeneratedAndCached() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent("orange.png")
        try png.write(to: url)
        XCTAssertNil(FileThumbnails.cached(url.path))
        let made = await FileThumbnails.load(url, scale: 2)
        XCTAssertNotNil(made, "Quick Look drew a thumbnail")
        XCTAssertNotNil(FileThumbnails.cached(url.path))
        let missing = await FileThumbnails.load(dir.appendingPathComponent("gone.png"), scale: 2)
        XCTAssertNil(missing)
    }
}
