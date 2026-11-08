import Combine
import XCTest
@testable import portside

/// P2-CMD-07: list parsing, the exact invocations, bounded runs, missing
/// Shortcuts, and rows that run only by explicit pick.
@MainActor
final class ShortcutsTests: XCTestCase {
    private nonisolated let a = UUID(), b = UUID()

    private nonisolated func listing(_ text: String) -> LsofRun {
        var run = LsofRun(termination: .exited(0))
        run.stdout = Data(text.utf8)
        return run
    }

    /// Records every invocation and answers from a script.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [LsofInvocation] = []
        var answer: @Sendable (LsofInvocation) -> LsofRun = { _ in LsofRun(termination: .exited(0)) }
        var invocations: [LsofInvocation] { lock.withLock { calls } }
        func record(_ invocation: LsofInvocation) { lock.withLock { calls.append(invocation) } }
    }

    private func service(_ recorder: Recorder, exists: Bool = true, active: Bool = true) -> ShortcutsService {
        let service = ShortcutsService(runner: { invocation, _ in
            recorder.record(invocation)
            return recorder.answer(invocation)
        }, exists: { exists })
        if active { service.activate() }
        return service
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    // MARK: Parser and invocations

    func testParserReadsNamesAndIdentifiers() {
        let text = """
        Open Actions (\(a.uuidString))
        What’s a shortcut? (\(b.uuidString))
        Bedroom On 🟢 (\(UUID().uuidString))
        Parens (a) (b) (\(UUID().uuidString))
        """
        let found = ShortcutListParser.parse(Data(text.utf8))
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(found.map(\.name), ["Bedroom On 🟢", "Open Actions", "Parens (a) (b)", "What’s a shortcut?"])
        XCTAssertEqual(found.first { $0.name == "Open Actions" }?.id, a)
    }

    func testParserSkipsMalformedDuplicateAndEmptyLines() {
        let text = """
        No id here
        Bad (not-a-uuid)
         (\(a.uuidString))
        Good (\(b.uuidString))
        Duplicate (\(b.uuidString))

        Trailing ( \(UUID().uuidString)
        """
        XCTAssertEqual(ShortcutListParser.parse(Data(text.utf8)).map(\.name), ["Good"])
        XCTAssertTrue(ShortcutListParser.parse(Data([0xFF, 0xFE])).isEmpty)
        XCTAssertTrue(ShortcutListParser.parse(Data()).isEmpty)
    }

    func testParserBoundsListAndNames() {
        var text = "\(String(repeating: "n", count: 500)) (\(UUID().uuidString))\n"
        for _ in 0..<600 { text += "s (\(UUID().uuidString))\n" }
        let found = ShortcutListParser.parse(Data(text.utf8))
        XCTAssertEqual(found.count, ShortcutInfo.listLimit)
        XCTAssertTrue(found.allSatisfy { $0.name.count <= ShortcutInfo.nameLimit })
    }

    func testInvocationsAreAbsoluteArgumentArraysWithAMinimalEnvironment() {
        let list = ShortcutsInvocation.list()
        XCTAssertEqual(list.executableURL.path, "/usr/bin/shortcuts")
        XCTAssertEqual(list.arguments, ["list", "--show-identifiers"])
        XCTAssertEqual(list.environment, ["LC_ALL": "C"])
        let run = ShortcutsInvocation.run(a)
        XCTAssertEqual(run.arguments, ["run", a.uuidString], "by identifier, no input or output path")
        XCTAssertEqual(ShortcutsInvocation.runLimits.deadline, .seconds(60))
        XCTAssertLessThanOrEqual(ShortcutsInvocation.runLimits.stdoutCap, 64 << 10)
    }

    // MARK: Listing

    func testRefreshListsOnceWithinTheIntervalAndReportsChange() async {
        let recorder = Recorder()
        recorder.answer = { [self] _ in listing("One (\(a.uuidString))\n") }
        let service = service(recorder)
        var changes = 0
        let now = Date()
        service.refresh(now: now) { changes += 1 }
        await settle()
        XCTAssertEqual(service.rows.map(\.name), ["One"])
        XCTAssertEqual(changes, 1)
        service.refresh(now: now.addingTimeInterval(5)) { changes += 1 }
        await settle()
        XCTAssertEqual(recorder.invocations.count, 1, "skipped inside 30 s")
        service.refresh(now: now.addingTimeInterval(31)) { changes += 1 }
        await settle()
        XCTAssertEqual(recorder.invocations.count, 2)
        XCTAssertEqual(changes, 1, "an identical list is not a change")
        XCTAssertTrue(recorder.invocations.allSatisfy { $0.arguments == ["list", "--show-identifiers"] }, "listing never runs a shortcut")
    }

    func testFailedListingKeepsTheLastListAndSaysWhy() async {
        let recorder = Recorder()
        recorder.answer = { [self] _ in listing("One (\(a.uuidString))\n") }
        let service = service(recorder)
        let now = Date()
        service.refresh(now: now) {}
        await settle()
        recorder.answer = { _ in LsofRun(termination: .exited(1)) }
        service.refresh(now: now.addingTimeInterval(40)) {}
        await settle()
        XCTAssertEqual(service.rows.count, 1)
        XCTAssertEqual(service.listFailure, "Shortcuts could not list your shortcuts.")
        recorder.answer = { _ in var run = LsofRun(termination: .exited(0)); run.stdoutTruncated = true; return run }
        service.refresh(now: now.addingTimeInterval(80)) {}
        await settle()
        XCTAssertNotNil(service.listFailure, "a truncated listing is not trusted")
    }

    func testNothingListsWhileOffOrWithoutShortcuts() async {
        let recorder = Recorder()
        let off = service(recorder, active: false)
        off.refresh {}
        let missing = service(recorder, exists: false)
        missing.refresh {}
        await settle()
        XCTAssertTrue(recorder.invocations.isEmpty)
        XCTAssertEqual(off.unavailableReason, ShortcutsService.Message.off)
        XCTAssertEqual(missing.unavailableReason, ShortcutsService.Message.missing)
        XCTAssertTrue(missing.rows.isEmpty)
    }

    func testDeactivateClearsTheListAndDropsALateListing() async {
        let recorder = Recorder()
        recorder.answer = { [self] _ in listing("One (\(a.uuidString))\n") }
        let service = service(recorder)
        service.refresh {}
        service.deactivate()
        await settle()
        XCTAssertTrue(service.shortcuts.isEmpty)
        XCTAssertTrue(service.rows.isEmpty)
    }

    // MARK: Running

    private func listed(_ recorder: Recorder) async -> ShortcutsService {
        recorder.answer = { [self] invocation in
            invocation.arguments.first == "list" ? listing("One (\(a.uuidString))\nTwo (\(b.uuidString))\n") : LsofRun(termination: .exited(0))
        }
        let service = service(recorder)
        service.refresh {}
        await settle()
        return service
    }

    func testRunUsesTheListedIdentifierOnly() async {
        let recorder = Recorder()
        let service = await listed(recorder)
        let result = await service.run(a)
        XCTAssertEqual(result, .success("Ran One."))
        XCTAssertEqual(recorder.invocations.last?.arguments, ["run", a.uuidString])
        let unlisted = await service.run(UUID())
        XCTAssertEqual(unlisted, .failure(CommandFailure(reason: ShortcutsService.Message.gone)))
        XCTAssertEqual(recorder.invocations.filter { $0.arguments.first == "run" }.count, 1)
    }

    func testRunOutcomesHaveFixedMessages() async {
        let recorder = Recorder()
        let service = await listed(recorder)
        let cases: [(LsofRun.Termination, String)] = [
            (.exited(1), "One did not finish (status 1)."),
            (.signaled(9), "One was stopped."),
            (.timedOut, "One did not finish in 60 seconds. Portside stopped waiting; Shortcuts may still be running it."),
            (.launchFailed("secret path"), ShortcutsService.Message.missing),
            (.canceled, "One was canceled. Shortcuts may still finish it."),
        ]
        for (termination, message) in cases {
            recorder.answer = { _ in LsofRun(termination: termination) }
            let result = await service.run(a)
            XCTAssertEqual(result, .failure(CommandFailure(reason: message)))
        }
    }

    func testOnlyOneRunAtATime() async {
        let recorder = Recorder()
        let service = await listed(recorder)
        let gate = DispatchSemaphore(value: 0)
        recorder.answer = { _ in
            gate.wait()
            return LsofRun(termination: .exited(0))
        }
        let first = Task { await service.run(a) }
        await settle()
        XCTAssertEqual(service.running, a)
        let second = await service.run(b)
        XCTAssertEqual(second, .failure(CommandFailure(reason: ShortcutsService.Message.busy)))
        gate.signal()
        let done = await first.value
        XCTAssertEqual(done, .success("Ran One."))
        XCTAssertNil(service.running)
    }

    func testRunRefusedWhileOffOrMissing() async {
        let recorder = Recorder()
        let off = service(recorder, active: false)
        let offResult = await off.run(a)
        XCTAssertEqual(offResult, .failure(CommandFailure(reason: ShortcutsService.Message.off)))
        let missing = service(recorder, exists: false)
        let missingResult = await missing.run(a)
        XCTAssertEqual(missingResult, .failure(CommandFailure(reason: ShortcutsService.Message.missing)))
        XCTAssertTrue(recorder.invocations.isEmpty)
    }

    // MARK: Module and rows

    func testModuleRunsThroughTheRegistryByIDOnly() async throws {
        let recorder = Recorder()
        let service = await listed(recorder)
        let module = ShortcutsModule(service: service)
        let registry = CommandRegistry()
        for command in module.commands() { try registry.register(command) }
        XCTAssertEqual(module.id.rawValue, "shortcuts")
        XCTAssertTrue(module.isSensitive, "restricted mode holds it off")
        XCTAssertFalse(module.isRequired)
        let ok = await registry.execute(ShortcutsModule.runCommand, input: .string(a.uuidString))
        XCTAssertEqual(ok, .success("Ran One."))
        let text = await registry.execute(ShortcutsModule.runCommand, input: .string("One"))
        if case .failed = text {} else { XCTFail("a name is not an identifier: \(text)") }
        let long = await registry.execute(ShortcutsModule.runCommand, input: .string(String(repeating: "a", count: 40)))
        if case .invalidInput = long {} else { XCTFail("schema caps input") }
    }

    func testModuleFailsToStartWithoutShortcutsAndStaysOff() throws {
        let service = service(Recorder(), exists: false, active: false)
        let module = ShortcutsModule(service: service)
        XCTAssertThrowsError(try module.start(ModuleContext())) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, ShortcutsService.Message.missing)
        }
        XCTAssertFalse(service.isActive)
    }

    func testRowsRunByIdentifierAndAreSearchableByName() throws {
        let descriptor = CommandDescriptor(id: ShortcutsModule.runCommand, title: "Run Shortcut", input: .string(maxLength: 36)) { _ in .success(nil) }
        let items = CommandCenterCatalog.shortcutItems([ShortcutInfo(id: a, name: "Bedroom On 🟢"), ShortcutInfo(id: b, name: "Start a workout")], run: descriptor)
        XCTAssertEqual(items[0].id, .shortcut(a))
        XCTAssertEqual(items[0].kind, .shortcut)
        XCTAssertEqual(items[0].invocation, CommandInvocation(command: ShortcutsModule.runCommand, input: .string(a.uuidString)))
        XCTAssertEqual(items[0].primaryTitle, "Run Shortcut")
        XCTAssertNil(items[0].unavailableReason)
        XCTAssertEqual(try XCTUnwrap(CommandCenterRanker.rank(items, query: "workout")), [items[1].id])
        XCTAssertEqual(CommandCenterResultID(rawValue: items[0].id.rawValue), items[0].id)
        XCTAssertEqual(CommandCenterCatalog.shortcutItems([ShortcutInfo(id: a, name: "x")], run: nil).first?.unavailableReason, "This build cannot open it.")
    }

    func testSearchNeverInvokesAnything() async throws {
        let recorder = Recorder()
        let service = await listed(recorder)
        let before = recorder.invocations.count
        let items = CommandCenterCatalog.shortcutItems(service.rows, run: nil)
        _ = CommandCenterRanker.rank(items, query: "one")
        var state = CommandCenterState()
        _ = state.send(.open(items))
        _ = state.send(.query("one"))
        XCTAssertEqual(recorder.invocations.count, before, "typing runs nothing; only Return does")
    }

    // MARK: Review fixes

    func testTurningTheModuleOffCancelsARunInFlight() async throws {
        let sawCancel = CancelFlag()
        let recorder = Recorder()
        recorder.answer = { [self] _ in listing("One (\(a.uuidString))\n") }
        let service = ShortcutsService(runner: { invocation, _ in
            if invocation.arguments.first == "list" { return recorder.answer(invocation) }
            // A child that never ends until it is told to stop.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            sawCancel.set()
            return LsofRun(termination: .canceled)
        }, exists: { true })
        service.activate()
        service.refresh {}
        await settle()
        let run = Task { await service.run(a) }
        await settle()
        XCTAssertEqual(service.running, a)
        service.deactivate()
        let result = await run.value
        XCTAssertTrue(sawCancel.value, "the runner (and so the child) was told to stop")
        XCTAssertEqual(result, .failure(CommandFailure(reason: "One was canceled. Shortcuts may still finish it.")))
        XCTAssertNil(service.running)
    }

    func testCancellingTheCallerStillStopsTheChild() async throws {
        let sawCancel = CancelFlag()
        let service = ShortcutsService(runner: { invocation, _ in
            if invocation.arguments.first == "list" {
                var listed = LsofRun(termination: .exited(0))
                listed.stdout = Data("One (\(UUID().uuidString))\n".utf8)
                return listed
            }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            sawCancel.set()
            return LsofRun(termination: .canceled)
        }, exists: { true })
        service.activate()
        service.refresh {}
        await settle()
        let id = try XCTUnwrap(service.rows.first?.id)
        let run = Task { await service.run(id) }
        await settle()
        run.cancel()
        _ = await run.value
        XCTAssertTrue(sawCancel.value)
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }
}

