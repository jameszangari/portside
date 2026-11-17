import XCTest
@testable import portside

@MainActor
final class CommandRegistryTests: XCTestCase {
    private func id(_ raw: String) throws -> CommandID { try XCTUnwrap(CommandID(raw)) }

    private func command(
        _ raw: String,
        input: CommandInputSchema = .none,
        unavailable: @escaping () -> String? = { nil },
        handler: @escaping @MainActor (CommandInput) async -> Result<String?, CommandFailure> = { _ in .success(nil) }
    ) throws -> CommandDescriptor {
        CommandDescriptor(id: try id(raw), title: raw, input: input, unavailableReason: unavailable, handler: handler)
    }

    func testIDsMustBeNamespaced() {
        XCTAssertNotNil(CommandID("portside.openSettings"))
        for bad in ["", "openSettings", "a.b.c", ".x", "x.", "Portside.open", "port side.x", "a.1b", "a.é"] {
            XCTAssertNil(CommandID(bad), bad)
        }
    }

    func testDuplicateIDRejectedAndFirstKept() async throws {
        let registry = CommandRegistry()
        let dupID = try id("portside.open")
        try registry.register(command("portside.open") { _ in .success("first") })
        XCTAssertThrowsError(try registry.register(command("portside.open") { _ in .success("second") })) {
            XCTAssertEqual($0 as? CommandRegistryError, .duplicateID(dupID))
        }
        XCTAssertEqual(registry.descriptors.count, 1)
        let result = await registry.execute(dupID)
        XCTAssertEqual(result, .success("first"))
    }

    func testUnknownCommand() async throws {
        let result = await CommandRegistry().execute(try id("portside.nope"))
        XCTAssertEqual(result, .unknownCommand)
    }

    func testInputValidatedBeforeHandlerRuns() async throws {
        let registry = CommandRegistry()
        var calls = 0
        try registry.register(command("portside.port", input: .integer(1...65535)) { _ in calls += 1; return .success(nil) })
        let portID = try id("portside.port")

        for bad in [CommandInput.integer(0), .integer(70000), .none, .string("80")] {
            let result = await registry.execute(portID, input: bad)
            guard case .invalidInput = result else { return XCTFail("\(bad) gave \(result)") }
        }
        XCTAssertEqual(calls, 0)
        let ok = await registry.execute(portID, input: .integer(3000))
        XCTAssertEqual(ok, .success(nil))
        XCTAssertEqual(calls, 1)
    }

    func testStringLengthBound() async throws {
        let registry = CommandRegistry()
        try registry.register(command("portside.say", input: .string(maxLength: 3)))
        let sayID = try id("portside.say")
        let long = await registry.execute(sayID, input: .string("abcd"))
        guard case .invalidInput = long else { return XCTFail("\(long)") }
        let short = await registry.execute(sayID, input: .string("abc"))
        XCTAssertEqual(short, .success(nil))
    }

    func testUnavailableReturnsReasonWithoutRunning() async throws {
        let registry = CommandRegistry()
        var calls = 0
        var reason: String? = "Needs Accessibility."
        try registry.register(command("portside.fit", unavailable: { reason }) { _ in calls += 1; return .success(nil) })
        let fitID = try id("portside.fit")

        let blocked = await registry.execute(fitID)
        XCTAssertEqual(blocked, .unavailable("Needs Accessibility."))
        XCTAssertEqual(calls, 0)
        reason = nil
        let allowed = await registry.execute(fitID)
        XCTAssertEqual(allowed, .success(nil))
        XCTAssertEqual(calls, 1)
    }

    func testHandlerFailureIsReported() async throws {
        let registry = CommandRegistry()
        try registry.register(command("portside.bad") { _ in .failure(CommandFailure(reason: "boom")) })
        let result = await registry.execute(try id("portside.bad"))
        XCTAssertEqual(result, .failed("boom"))
    }

    func testCancelBeforeStartNeverRunsHandler() async throws {
        let registry = CommandRegistry()
        var calls = 0
        try registry.register(command("portside.slow") { _ in calls += 1; return .success(nil) })
        let slowID = try id("portside.slow")
        let task = Task { @MainActor in
            await Task.yield()
            return await registry.execute(slowID)
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .canceled)
        XCTAssertEqual(calls, 0)
    }

    func testCancelDuringHandlerDeliversCanceled() async throws {
        let registry = CommandRegistry()
        let started = expectation(description: "handler started")
        try registry.register(command("portside.wait") { _ in
            started.fulfill()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .success("finished")
        })
        let waitID = try id("portside.wait")
        let task = Task { @MainActor in await registry.execute(waitID) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .canceled)
    }
}
