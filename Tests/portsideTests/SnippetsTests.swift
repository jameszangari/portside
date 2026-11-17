import Combine
import XCTest
@testable import portside

/// P2-CMD-05: snippet storage, rows and the copy command.
@MainActor
final class SnippetsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("snippets.json") }

    private let samples = [
        "line one\nline two\n\ttabbed  ",
        "日本語のテキスト 🚀 café é",
        "$(rm -rf ~) `ls` ; {{date}} <script>alert(1)</script> %s \\n",
        "crlf\r\nline",
    ]

    func testAddUpdateRemoveRoundTripsThroughTheFile() throws {
        let store = SnippetStore(url: fileURL)
        let id = try XCTUnwrap(store.add(name: "Sig", text: "Best,\nJames"))
        var edited = try XCTUnwrap(store.snippet(id: id))
        edited.text = "Regards,\nJames"
        store.update(edited)
        let reread = SnippetStore(url: fileURL)
        XCTAssertEqual(reread.snippets, [Snippet(id: id, name: "Sig", text: "Regards,\nJames")])
        reread.remove(id: id)
        XCTAssertTrue(SnippetStore(url: fileURL).snippets.isEmpty)
    }

    func testMultilineAndUnicodeTextSurvivesExactly() throws {
        let store = SnippetStore(url: fileURL)
        for (index, text) in samples.enumerated() { store.add(name: "s\(index)", text: text) }
        XCTAssertEqual(SnippetStore(url: fileURL).snippets.map(\.text), samples)
    }

    func testFileIsPrivateAndHoldsNoTextInTheLogPath() throws {
        let store = SnippetStore(url: fileURL)
        store.add(name: "a", text: "secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["snippets.json"], "no temp file left behind")
    }

    func testMemoryOnlyStoreWritesNothing() {
        let store = SnippetStore(url: nil)
        store.add(name: "a", text: "b")
        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLimitsAreEnforced() {
        let store = SnippetStore(url: nil)
        let id = store.add(name: String(repeating: "n", count: 500), text: String(repeating: "t", count: 20_000))!
        XCTAssertEqual(store.snippet(id: id)?.name.count, Snippet.nameLimit)
        XCTAssertEqual(store.snippet(id: id)?.text.count, Snippet.textLimit)
        for _ in 1..<Snippet.listLimit { XCTAssertNotNil(store.add()) }
        XCTAssertTrue(store.isFull)
        XCTAssertNil(store.add())
        XCTAssertEqual(store.snippets.count, Snippet.listLimit)
    }

    func testMalformedEntriesAreSkippedNotFatal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = UUID()
        let json = """
        {"version":1,"snippets":[
          {"id":"\(good.uuidString)","name":"ok","text":"hi"},
          {"name":"no id","text":"x"},
          {"id":"not-a-uuid","name":"bad","text":"x"},
          {"id":"\(good.uuidString)","name":"duplicate","text":"y"},
          {"id":"\(UUID().uuidString)"},
          7
        ]}
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = SnippetStore(url: fileURL)
        XCTAssertEqual(store.snippets.count, 2)
        XCTAssertEqual(store.snippets.first, Snippet(id: good, name: "ok", text: "hi"))
        XCTAssertEqual(store.snippets.last?.text, "", "a missing text reads as empty")
    }

    func testUnreadableFileReadsAsEmptyAndIsKeptUntilSave() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = SnippetStore(url: fileURL)
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "not json")
    }

    func testTitlePreviewAndEmptiness() {
        XCTAssertEqual(Snippet(name: "  Sig ", text: "x").title, "Sig")
        XCTAssertEqual(Snippet(name: "", text: "\n  first line  \nsecond").title, "first line")
        XCTAssertEqual(Snippet().title, "Untitled Snippet")
        XCTAssertTrue(Snippet(text: " \n\t ").isEmpty)
        XCTAssertEqual(Snippet(text: "a\nb\n\nc").preview(), "a ⏎ b ⏎ c")
        XCTAssertEqual(Snippet(text: String(repeating: "x", count: 200)).preview(limit: 10).count, 10)
    }

    // MARK: Rows

    private let copyDescriptor = CommandDescriptor(id: CommandCenterModule.copySnippetCommand, title: "Copy Snippet", input: .string(maxLength: 36)) { _ in .success(nil) }

    func testRowsCopyByIDNeverCarryingTheText() throws {
        let snippet = Snippet(name: "Sig", text: "Best,\nJames")
        let item = try XCTUnwrap(CommandCenterCatalog.snippetItems([snippet], copy: copyDescriptor).first)
        XCTAssertEqual(item.id, .snippet(snippet.id))
        XCTAssertEqual(item.kind, .snippet)
        XCTAssertEqual(item.invocation, CommandInvocation(command: CommandCenterModule.copySnippetCommand, input: .string(snippet.id.uuidString)))
        XCTAssertEqual(item.primaryTitle, "Copy Snippet")
        XCTAssertNil(item.unavailableReason)
        XCTAssertEqual(item.detail, "Best, ⏎ James")
        XCTAssertFalse(item.invocation.input == .string(snippet.text))
    }

    func testEmptySnippetAndMissingCommandAreUnavailable() {
        XCTAssertEqual(CommandCenterCatalog.snippetItems([Snippet(name: "e", text: " ")], copy: copyDescriptor).first?.unavailableReason, "This snippet is empty.")
        XCTAssertEqual(CommandCenterCatalog.snippetItems([Snippet(name: "e", text: "x")], copy: nil).first?.unavailableReason, "This build cannot open it.")
    }

    func testSnippetsSearchByNameAndHaveNoSeparateCopyAction() throws {
        let items = CommandCenterCatalog.snippetItems([Snippet(name: "Email signature", text: "x"), Snippet(name: "Address", text: "y")], copy: copyDescriptor)
        let ranked = try XCTUnwrap(CommandCenterRanker.rank(items, query: "sig"))
        XCTAssertEqual(ranked, [items[0].id])
        var state = CommandCenterState()
        _ = state.send(.open(items))
        XCTAssertEqual(state.actions(for: items[0]).map(\.kind), [.run, .showDetails])
    }

    func testSnippetIDsAreStableAndKeepHistory() {
        let id = UUID()
        let result = CommandCenterResultID.snippet(id)
        XCTAssertEqual(result.rawValue, "snippet:\(id.uuidString.lowercased())")
        XCTAssertEqual(CommandCenterResultID(rawValue: result.rawValue), result, "history can read it back")
    }

    // MARK: Command

    private func command(_ store: [Snippet], copied: @escaping (String) -> Void, ok: Bool = true) throws -> CommandDescriptor {
        var actions = CommandCenterActions.none
        actions.copyText = { copied($0); return ok }
        actions.snippets = { store }
        let module = CommandCenterModule(center: CommandCenter(commands: CommandRegistry(), moduleTitle: { _ in nil }),
                                         chords: Just(nil).eraseToAnyPublisher(), actions: actions)
        return try XCTUnwrap(module.commands().first { $0.id == CommandCenterModule.copySnippetCommand })
    }

    func testCopyCommandPutsTheExactTextOnlyForASavedID() async throws {
        var copied: [String] = []
        for text in samples {
            let snippet = Snippet(name: "s", text: text)
            let descriptor = try command([snippet]) { copied.append($0) }
            let result = await descriptor.handler(.string(snippet.id.uuidString))
            if case .failure = result { XCTFail("copy failed for \(text)") }
        }
        XCTAssertEqual(copied, samples)
    }

    func testCopyCommandRefusesUnknownIDsTextAndEmptySnippets() async throws {
        var copied: [String] = []
        let empty = Snippet(name: "e", text: "  ")
        let descriptor = try command([empty]) { copied.append($0) }
        for input in [CommandInput.string(UUID().uuidString), .string("raw text"), .string(empty.id.uuidString), .none] {
            if case .success = await descriptor.handler(input) { XCTFail("\(input) must not copy") }
        }
        XCTAssertTrue(copied.isEmpty)
        let failing = try command([Snippet(name: "a", text: "x")], copied: { _ in }, ok: false)
        if case .success = await failing.handler(.string((Snippet(name: "a", text: "x")).id.uuidString)) { XCTFail("unused id") }
    }

    func testCopyCommandRunsThroughTheRegistry() async throws {
        let snippet = Snippet(name: "Sig", text: "multi\nline 🚀")
        var copied: [String] = []
        let descriptor = try command([snippet]) { copied.append($0) }
        let registry = CommandRegistry()
        try registry.register(descriptor)
        let result = await registry.execute(CommandCenterModule.copySnippetCommand, input: .string(snippet.id.uuidString))
        XCTAssertEqual(result, .success(nil))
        XCTAssertEqual(copied, ["multi\nline 🚀"])
        let tooLong = await registry.execute(CommandCenterModule.copySnippetCommand, input: .string(String(repeating: "a", count: 40)))
        if case .invalidInput = tooLong {} else { XCTFail("schema caps the input") }
    }

    // MARK: Review fixes

    func testShortcutsAndSnippetsNeedATypedQuery() throws {
        let copy = CommandDescriptor(id: CommandCenterModule.copySnippetCommand, title: "Copy Snippet", input: .string(maxLength: 36)) { _ in .success(nil) }
        let run = CommandDescriptor(id: ShortcutsModule.runCommand, title: "Run Shortcut", input: .string(maxLength: 36)) { _ in .success(nil) }
        var items = CommandCenterCatalog.snippetItems([Snippet(name: "Signature", text: "Best,\nJames")], copy: copy)
        items += CommandCenterCatalog.shortcutItems([ShortcutInfo(id: UUID(), name: "Dangerous Thing")], run: run)
        items.append(CommandCenterItem(id: CommandID("a.b")!, title: "A Command"))
        // Even a heavily used one stays out of the empty list.
        items = items.map { var item = $0; item.usage = 50; return item }
        XCTAssertEqual(CommandCenterRanker.defaultOrder(items).map(\.title), ["A Command"])
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "")?.count, 1)
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "signa")?.count, 1, "typing finds the snippet")
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "dang")?.count, 1, "typing finds the shortcut")
        var state = CommandCenterState()
        let opened = state.send(.open(items))
        XCTAssertTrue(opened.handled)
        XCTAssertEqual(state.results.map(\.title), ["A Command"], "opening shows neither, so Return runs neither")
        _ = state.send(.query("dang"))
        _ = state.send(.results(CommandCenterSearchRequest(generation: state.searchGeneration, query: "dang"), CommandCenterRanker.rank(items, query: "dang") ?? []))
        XCTAssertEqual(state.results.map(\.title), ["Dangerous Thing"])
        _ = state.send(.key(.escape))
        XCTAssertEqual(state.results.map(\.title), ["A Command"], "clearing the query hides them again")
    }
}

