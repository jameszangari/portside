import CryptoKit
import XCTest
@testable import portside

/// P2-CMD-04: policy, encrypted storage, capture flow, commands and rows.
@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct FixedKey: ClipboardKeyStore {
        var data = Data(repeating: 7, count: 32)
        func key() throws -> SymmetricKey { SymmetricKey(data: data) }
    }

    private struct NoKey: ClipboardKeyStore {
        func key() throws -> SymmetricKey { throw KeychainKeyStore.Failure() }
    }

    @MainActor private final class FakeBoard: PasteboardAccess {
        var changeCount = 1
        var types: [String] = ["public.utf8-plain-text"]
        var string: String?
        var failWrite = false
        func copy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
            changeCount += 1
            string = text
            self.types = types
        }
        func write(_ text: String) -> Int? {
            guard !failWrite else { return nil }
            changeCount += 1
            string = text
            types = ["public.utf8-plain-text"]
            return changeCount
        }
    }

    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_000_000) }

    private struct Rig {
        let service: ClipboardService
        let board: FakeBoard
        let clock: Clock
        var front: Front
        var secure: Secure
    }
    @MainActor final class Front { var id: String? = "com.apple.TextEdit" }
    @MainActor final class Secure { var on = false }

    private var file: ClipboardFile { ClipboardFile(url: dir.appendingPathComponent("history.bin"), keys: FixedKey()) }

    private func rig(keys: ClipboardKeyStore = FixedKey(), prefs: Bool = true) throws -> Rig {
        let board = FakeBoard(), clock = Clock(), front = Front(), secure = Secure()
        let service = ClipboardService(
            file: ClipboardFile(url: dir.appendingPathComponent("history.bin"), keys: keys),
            prefsURL: prefs ? dir.appendingPathComponent("prefs.json") : nil,
            pasteboard: board, frontmost: { front.id }, secureInput: { secure.on }, now: { clock.date }, startsTimer: false
        )
        try service.activate()
        return Rig(service: service, board: board, clock: clock, front: front, secure: secure)
    }

    // MARK: Policy

    func testPolicySkipsEveryDocumentedCase() {
        func decide(types: [String] = ["public.utf8-plain-text"], text: String? = "hello", apps: [String?] = ["com.apple.TextEdit"],
                    user: [String] = [], paused: Bool = false, secure: Bool = false) -> ClipboardPolicy.Decision {
            ClipboardPolicy.decide(types: types, text: text, apps: apps, user: user, paused: paused, secureInput: secure)
        }
        XCTAssertEqual(decide(), .capture("hello"))
        XCTAssertEqual(decide(paused: true), .skip(.paused))
        XCTAssertEqual(decide(secure: true), .skip(.secureInput))
        for type in ClipboardPolicy.sensitiveTypes { XCTAssertEqual(decide(types: ["public.utf8-plain-text", type]), .skip(.sensitiveType), type) }
        XCTAssertEqual(decide(types: ["public.file-url", "public.utf8-plain-text"]), .skip(.filePayload))
        XCTAssertEqual(decide(text: nil), .skip(.noText))
        XCTAssertEqual(decide(text: " \n\t "), .skip(.blank))
        XCTAssertEqual(decide(text: String(repeating: "a", count: ClipboardPolicy.maxCharacters + 1)), .skip(.tooLarge))
        XCTAssertEqual(decide(text: String(repeating: "a", count: ClipboardPolicy.maxCharacters)), .capture(String(repeating: "a", count: ClipboardPolicy.maxCharacters)))
        XCTAssertEqual(decide(apps: ["com.1password.1password"]), .skip(.excludedApp))
        XCTAssertEqual(decide(apps: ["com.apple.TextEdit", "com.bitwarden.desktop"]), .skip(.excludedApp), "the previous app counts too")
        XCTAssertEqual(decide(apps: ["com.example.Mine"], user: ["com.example.mine"]), .skip(.excludedApp), "case insensitive")
        XCTAssertEqual(decide(apps: [nil]), .capture("hello"))
    }

    func testExclusionMatchesWholeBundleIDsAndDotPrefixesOnly() {
        XCTAssertTrue(ClipboardPolicy.isExcluded("com.1password.1password", user: []))
        XCTAssertTrue(ClipboardPolicy.isExcluded("com.1password", user: []))
        XCTAssertFalse(ClipboardPolicy.isExcluded("com.1passwordish.app", user: []))
        XCTAssertFalse(ClipboardPolicy.isExcluded("com.apple.TextEdit", user: []))
        XCTAssertFalse(ClipboardPolicy.isExcluded(nil, user: ["x"]))
        XCTAssertTrue(ClipboardPolicy.isBundleID("com.example.App-1"))
        XCTAssertFalse(ClipboardPolicy.isBundleID("bad id"))
        XCTAssertFalse(ClipboardPolicy.isBundleID(""))
    }

    func testPruneExpiresSortsAndBounds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = [
            ClipboardEntry(text: "old", date: now.addingTimeInterval(-7200)),
            ClipboardEntry(text: "new", date: now.addingTimeInterval(-60)),
            ClipboardEntry(text: "mid", date: now.addingTimeInterval(-1800)),
        ]
        XCTAssertEqual(ClipboardPolicy.pruned(entries, now: now, expiryHours: 1).map(\.text), ["new", "mid"])
        XCTAssertEqual(ClipboardPolicy.pruned(entries, now: now, expiryHours: 24).map(\.text), ["new", "mid", "old"])
        let many = (0..<150).map { ClipboardEntry(text: "e\($0)", date: now.addingTimeInterval(Double(-$0))) }
        XCTAssertEqual(ClipboardPolicy.pruned(many, now: now, expiryHours: 24).count, ClipboardPolicy.maxEntries)
    }

    // MARK: Encrypted file

    func testFileIsEncryptedPrivateExcludedFromBackupAndHoldsNoPlaintext() throws {
        let entries = [ClipboardEntry(text: "TOP-SECRET-PASSPHRASE-123 üñí 🚀", date: Date(timeIntervalSince1970: 1_000_000))]
        try file.write(entries)
        let data = try Data(contentsOf: file.url)
        XCTAssertTrue(data.starts(with: ClipboardFile.magic))
        XCTAssertNil(data.range(of: Data("TOP-SECRET".utf8)), "no plaintext on disk")
        XCTAssertNil(data.range(of: Data("PASSPHRASE".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(file.read(), entries)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["history.bin"], "no temp file left")
    }

    func testWrongKeyTamperedTruncatedAndForeignFilesReadAsEmpty() throws {
        try file.write([ClipboardEntry(text: "x", date: Date())])
        XCTAssertTrue(ClipboardFile(url: file.url, keys: FixedKey(data: Data(repeating: 9, count: 32))).read().isEmpty, "another key")
        var data = try Data(contentsOf: file.url)
        data[data.count - 1] ^= 0xFF
        try data.write(to: file.url)
        XCTAssertTrue(file.read().isEmpty, "tampering is detected")
        try Data(ClipboardFile.magic + Data([1, 2, 3])).write(to: file.url)
        XCTAssertTrue(file.read().isEmpty)
        try Data("plain json [{\"text\":\"x\"}]".utf8).write(to: file.url)
        XCTAssertTrue(file.read().isEmpty)
        XCTAssertTrue(ClipboardFile(url: dir.appendingPathComponent("none.bin"), keys: FixedKey()).read().isEmpty)
    }

    func testLiveKeychainKeyIsStableAndRandom() throws {
        let store = KeychainKeyStore(service: "com.james.portside.tests.\(UUID().uuidString)", account: "k")
        defer { store.delete() }
        let first: SymmetricKey
        do { first = try store.key() } catch { throw XCTSkip("keychain unavailable here: \(error)") }
        let second = try store.key()
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertEqual(first.bitCount, 256)
        let other = KeychainKeyStore(service: "com.james.portside.tests.\(UUID().uuidString)", account: "k")
        defer { other.delete() }
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, try other.key().withUnsafeBytes { Data($0) })
    }

    func testNoKeyKeepsItOffAndNeverWritesPlaintext() throws {
        let service = ClipboardService(file: ClipboardFile(url: dir.appendingPathComponent("h.bin"), keys: NoKey()), prefsURL: nil,
                                       pasteboard: FakeBoard(), startsTimer: false)
        XCTAssertThrowsError(try service.activate())
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.unavailableReason, "Clipboard History is turned off.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("h.bin").path))
        let module = ClipboardModule(service: service)
        XCTAssertThrowsError(try module.start(ModuleContext()))
        XCTAssertTrue(module.isSensitive)
        XCTAssertFalse(module.isRequired)
    }

    // MARK: Capture flow

    func testCapturesTextAndNotWhatWasThereAtStart() throws {
        let board = FakeBoard()
        board.copy("already there")
        let clock = Clock()
        let service = ClipboardService(file: file, prefsURL: nil, pasteboard: board, frontmost: { "com.apple.TextEdit" },
                                       secureInput: { false }, now: { clock.date }, startsTimer: false)
        try service.activate()
        service.tick()
        XCTAssertTrue(service.entries.isEmpty, "what was copied before it started is never captured")
        board.copy("fresh text")
        service.tick()
        XCTAssertEqual(service.entries.map(\.text), ["fresh text"])
        service.tick()
        XCTAssertEqual(service.entries.count, 1, "no change, no entry")
    }

    func testSecureInputCopyIsNeverCapturedLaterEither() throws {
        let rig = try rig()
        rig.secure.on = true
        rig.board.copy("hunter2")
        rig.service.tick()
        rig.secure.on = false
        rig.service.tick()
        rig.service.tick()
        XCTAssertTrue(rig.service.entries.isEmpty, "a skipped change is consumed, not retried")
    }

    func testAppTransitionsDoNotLeakAnExcludedAppsCopy() throws {
        let rig = try rig()
        rig.front.id = "com.1password.1password"
        rig.service.tick()
        rig.board.copy("vault secret")
        // The person switches to another app before the next look.
        rig.front.id = "com.apple.TextEdit"
        rig.service.tick()
        XCTAssertTrue(rig.service.entries.isEmpty, "the previous app was excluded")
        rig.board.copy("normal copy")
        rig.service.tick()
        XCTAssertEqual(rig.service.entries.map(\.text), ["normal copy"])
        // A user exclusion works the same way.
        XCTAssertTrue(rig.service.excludeApp("com.example.Mine"))
        rig.front.id = "com.example.Mine"
        rig.service.tick()
        rig.board.copy("mine")
        rig.service.tick()
        XCTAssertEqual(rig.service.entries.map(\.text), ["normal copy"])
    }

    func testSensitiveTypesAndFilesAreSkipped() throws {
        let rig = try rig()
        rig.board.copy("from a password manager", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        rig.service.tick()
        rig.board.copy("finder names", types: ["public.utf8-plain-text", "public.file-url"])
        rig.service.tick()
        rig.board.copy(nil, types: ["public.png"])
        rig.service.tick()
        XCTAssertTrue(rig.service.entries.isEmpty)
    }

    func testPauseStopsCaptureAndResumeIgnoresWhatWasCopiedWhilePaused() throws {
        let rig = try rig()
        rig.service.setPaused(true)
        rig.board.copy("while paused")
        rig.service.tick()
        rig.service.setPaused(false)
        rig.service.tick()
        XCTAssertTrue(rig.service.entries.isEmpty)
        rig.board.copy("after resume")
        rig.service.tick()
        XCTAssertEqual(rig.service.entries.map(\.text), ["after resume"])
        XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent("prefs.json"), encoding: .utf8).contains("after resume"), "prefs hold no text")
    }

    func testDuplicatesMoveToTheTopAndTheListIsBounded() throws {
        let rig = try rig()
        for text in ["a", "b", "a"] {
            rig.clock.date.addTimeInterval(1)
            rig.board.copy(text)
            rig.service.tick()
        }
        XCTAssertEqual(rig.service.entries.map(\.text), ["a", "b"])
        for i in 0..<130 {
            rig.clock.date.addTimeInterval(1)
            rig.board.copy("entry \(i)")
            rig.service.tick()
        }
        XCTAssertEqual(rig.service.entries.count, ClipboardPolicy.maxEntries)
        XCTAssertEqual(rig.service.entries.first?.text, "entry 129")
    }

    func testExpiryDropsEntriesOnPruneAndChangingItAppliesAtOnce() throws {
        let rig = try rig()
        rig.board.copy("soon gone")
        rig.service.tick()
        rig.clock.date.addTimeInterval(2 * 3600)
        rig.board.copy("recent")
        rig.service.tick()
        rig.service.setExpiry(hours: 1)
        XCTAssertEqual(rig.service.entries.map(\.text), ["recent"])
        rig.clock.date.addTimeInterval(2 * 3600)
        rig.service.prune()
        XCTAssertTrue(rig.service.entries.isEmpty)
        XCTAssertEqual(file.read(), [], "the file follows")
        rig.service.setExpiry(hours: 5)
        XCTAssertEqual(rig.service.prefs.expiryHours, 1, "only the offered choices")
    }

    func testPersistsEncryptedAndReloadsAndDeactivateKeepsFileButDropsMemory() throws {
        let rig = try rig()
        rig.board.copy("keep me")
        rig.service.tick()
        XCTAssertEqual(file.read().map(\.text), ["keep me"])
        rig.service.deactivate()
        XCTAssertTrue(rig.service.entries.isEmpty)
        rig.board.copy("while off")
        rig.service.tick()
        XCTAssertTrue(rig.service.entries.isEmpty, "off captures nothing")
        try rig.service.activate()
        XCTAssertEqual(rig.service.entries.map(\.text), ["keep me"])
        rig.service.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(rig.service.entries.isEmpty)
    }

    func testOwnCopiesAreNotCapturedAgain() async throws {
        let rig = try rig()
        rig.board.copy("original")
        rig.service.tick()
        let id = try XCTUnwrap(rig.service.entries.first?.id)
        XCTAssertEqual(rig.service.copy(id), .success(nil))
        XCTAssertEqual(rig.board.string, "original")
        rig.service.tick()
        XCTAssertEqual(rig.service.entries.count, 1)
        rig.board.copy("calc result")
        rig.service.noteOwnWrite(changeCount: rig.board.changeCount)
        rig.service.tick()
        XCTAssertEqual(rig.service.entries.map(\.text), ["original"], "a snippet or result Portside copied is not history")
        rig.board.failWrite = true
        XCTAssertEqual(rig.service.copy(id), .failure(CommandFailure(reason: "macOS would not take the text.")))
        XCTAssertEqual(rig.service.copy(UUID()), .failure(CommandFailure(reason: "That entry has expired or was deleted.")))
    }

    // MARK: Query and rows

    func testFilterNeedsClipOrClipboardAsTheFirstWord() {
        XCTAssertEqual(ClipboardService.filter(in: "clip"), "")
        XCTAssertEqual(ClipboardService.filter(in: "Clipboard"), "")
        XCTAssertEqual(ClipboardService.filter(in: "clip foo bar"), "foo bar")
        XCTAssertEqual(ClipboardService.filter(in: "clipboard  x"), " x")
        XCTAssertNil(ClipboardService.filter(in: "clips"))
        XCTAssertNil(ClipboardService.filter(in: "my clip"))
        XCTAssertNil(ClipboardService.filter(in: "safari"))
        XCTAssertNil(ClipboardService.filter(in: ""))
    }

    func testResultsAreNewestFirstFilteredBoundedAndOnlyForClipQueries() throws {
        let rig = try rig()
        for text in ["alpha one", "beta two", "alpha three"] {
            rig.clock.date.addTimeInterval(1)
            rig.board.copy(text)
            rig.service.tick()
        }
        XCTAssertEqual(rig.service.results(for: "clip").map(\.text), ["alpha three", "beta two", "alpha one"])
        XCTAssertEqual(rig.service.results(for: "clip ALPHA").map(\.text), ["alpha three", "alpha one"])
        XCTAssertEqual(rig.service.results(for: "clip alpha three").map(\.text), ["alpha three"])
        XCTAssertTrue(rig.service.results(for: "alpha").isEmpty, "ordinary queries never show copied text")
        for i in 0..<20 {
            rig.clock.date.addTimeInterval(1)
            rig.board.copy("more \(i)")
            rig.service.tick()
        }
        XCTAssertEqual(rig.service.results(for: "clip").count, ClipboardService.resultLimit)
        rig.service.deactivate()
        XCTAssertTrue(rig.service.results(for: "clip").isEmpty)
    }

    func testRowsCopyByIDAreSessionOnlyAndDeleteStaysOpen() throws {
        let copy = CommandDescriptor(id: ClipboardModule.copyCommand, title: "c", input: .string(maxLength: 36)) { _ in .success(nil) }
        let delete = CommandDescriptor(id: ClipboardModule.deleteCommand, title: "d", input: .string(maxLength: 36)) { _ in .success(nil) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = [ClipboardEntry(text: "\n  first line\nsecond", date: now.addingTimeInterval(-120)), ClipboardEntry(text: "second entry", date: now)]
        let items = CommandCenterCatalog.clipboardItems(entries, query: "clip", now: now, copy: copy, delete: delete)
        XCTAssertEqual(items.map(\.title), ["first line", "second entry"])
        XCTAssertEqual(items[0].kind, .clipboard)
        XCTAssertEqual(items[0].invocation, CommandInvocation(command: ClipboardModule.copyCommand, input: .string(entries[0].id.uuidString)))
        XCTAssertFalse(items[0].invocation.input == .string(entries[0].text), "the ID travels, not the text")
        XCTAssertEqual(items[0].moreActions.first?.invocation.staysOpen, true)
        XCTAssertEqual(items.map(\.answerOrder), [0, 1])
        XCTAssertNil(CommandCenterResultID(rawValue: items[0].id.rawValue), "never read from or written to history")
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "clip"), items.map(\.id))
        var state = CommandCenterState()
        _ = state.send(.open(items))
        XCTAssertFalse(state.actions(for: items[0]).contains { $0.kind == .copyID })
        _ = state.send(.key(.return))
        XCTAssertFalse(state.send(.finished(items[0].id, .success(nil))).effects.contains(.recordUsage(items[0].id)))
    }

    // MARK: Commands

    func testCommandsCopyDeletePauseResumeAndClear() async throws {
        let rig = try rig()
        let module = ClipboardModule(service: rig.service)
        let registry = CommandRegistry()
        for command in module.commands() { try registry.register(command) }
        rig.board.copy("hello")
        rig.service.tick()
        let id = try XCTUnwrap(rig.service.entries.first?.id)
        let copied = await registry.execute(ClipboardModule.copyCommand, input: .string(id.uuidString))
        XCTAssertEqual(copied, .success(nil))
        let bad = await registry.execute(ClipboardModule.copyCommand, input: .string("not-a-uuid"))
        if case .failed = bad {} else { XCTFail("\(bad)") }
        let resume = await registry.execute(ClipboardModule.resumeCommand)
        if case .unavailable = resume {} else { XCTFail("not paused: \(resume)") }
        let paused = await registry.execute(ClipboardModule.pauseCommand)
        XCTAssertEqual(paused, .success("Clipboard history paused."))
        XCTAssertTrue(rig.service.prefs.paused)
        let again = await registry.execute(ClipboardModule.pauseCommand)
        if case .unavailable = again {} else { XCTFail("already paused: \(again)") }
        _ = await registry.execute(ClipboardModule.resumeCommand)
        let deleted = await registry.execute(ClipboardModule.deleteCommand, input: .string(id.uuidString))
        XCTAssertEqual(deleted, .success("Deleted."))
        let gone = await registry.execute(ClipboardModule.deleteCommand, input: .string(id.uuidString))
        if case .failed = gone {} else { XCTFail("\(gone)") }
        rig.board.copy("again")
        rig.service.tick()
        let cleared = await registry.execute(ClipboardModule.clearCommand)
        XCTAssertEqual(cleared, .success("Clipboard history cleared."))
        XCTAssertTrue(rig.service.entries.isEmpty)
        rig.service.deactivate()
        let off = await registry.execute(ClipboardModule.copyCommand, input: .string(id.uuidString))
        if case .failed = off {} else { XCTFail("off: \(off)") }
    }

    func testPrefsPersistAndReadLeniently() throws {
        let rig = try rig()
        rig.service.setPaused(true)
        rig.service.setExpiry(hours: 168)
        XCTAssertTrue(rig.service.excludeApp("com.example.A"))
        XCTAssertFalse(rig.service.excludeApp("com.example.A"), "no duplicates")
        XCTAssertFalse(rig.service.excludeApp("bad id"))
        let reread = ClipboardService(file: file, prefsURL: dir.appendingPathComponent("prefs.json"), pasteboard: FakeBoard(), startsTimer: false)
        XCTAssertEqual(reread.prefs.paused, true)
        XCTAssertEqual(reread.prefs.expiryHours, 168)
        XCTAssertEqual(reread.prefs.excludedApps, ["com.example.A"])
        try Data(#"{"paused":"yes","excludedApps":["ok.app","bad id",7],"expiryHours":3}"#.utf8).write(to: dir.appendingPathComponent("prefs.json"))
        let lenient = ClipboardService(file: file, prefsURL: dir.appendingPathComponent("prefs.json"), pasteboard: FakeBoard(), startsTimer: false)
        XCTAssertEqual(lenient.prefs.paused, false)
        XCTAssertEqual(lenient.prefs.excludedApps, [])
        XCTAssertEqual(lenient.prefs.expiryHours, 24)
    }
}
