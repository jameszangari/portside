import XCTest
@testable import portside

@MainActor
final class PermissionGateTests: XCTestCase {
    private final class Switch {
        var state: PermissionState
        var reads = 0
        var requests = 0
        init(_ state: PermissionState) { self.state = state }
    }

    private func adapter(_ name: String, _ box: Switch) -> AppPermissionAdapter {
        AppPermissionAdapter(
            name: name,
            state: { box.reads += 1; return box.state },
            request: { _ in box.requests += 1; return true }
        )
    }

    private func command(_ raw: String, needs: [PermissionScope], ran: @escaping () -> Void = {},
                         unavailable: @escaping () -> String? = { nil }) throws -> CommandDescriptor {
        CommandDescriptor(
            id: try XCTUnwrap(CommandID(raw)), title: raw, unavailableReason: unavailable,
            requiredPermissions: needs, handler: { _ in ran(); return .success("ok") }
        )
    }

    func testRegisteringReadsAndRequestsNothing() {
        let box = Switch(.notRequested)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        gate.register(AccessibilityPermissionAdapter())
        XCTAssertEqual(box.reads, 0)
        XCTAssertEqual(box.requests, 0)
    }

    func testCheckingNeverRequests() {
        let box = Switch(.notRequested)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        _ = gate.prepare([.app("files")])
        XCTAssertEqual(box.requests, 0)
        XCTAssertTrue(gate.request(.app("files"), forFeature: "test"))
        XCTAssertEqual(box.requests, 1)
    }

    func testOnlyGrantedPasses() {
        let box = Switch(.granted)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        for blocked in [PermissionState.notRequested, .denied, .unavailable, .restrictedOrUnknown] {
            box.state = blocked
            XCTAssertEqual(gate.firstDenial(for: [.app("files")])?.state, blocked)
        }
        box.state = .granted
        XCTAssertNil(gate.firstDenial(for: [.app("files")]))
    }

    func testUnregisteredScopeIsUnavailable() {
        XCTAssertEqual(PermissionGate().state(of: .app("nope")), .unavailable)
        XCTAssertFalse(PermissionGate().request(.accessibility, forFeature: "x"))
    }

    func testRevokedBetweenPrepareAndExecute() {
        let box = Switch(.granted)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        guard case .success(let ticket) = gate.prepare([.app("files")]) else { return XCTFail("expected ticket") }
        box.state = .denied
        XCTAssertEqual(gate.authorizeExecution(ticket)?.state, .denied)
    }

    func testRegistryBlocksDeniedAndNeverRunsHandler() async throws {
        let box = Switch(.denied)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        let registry = CommandRegistry(permissions: gate)
        var ran = 0
        try registry.register(command("portside.scan", needs: [.app("files")], ran: { ran += 1 }))
        let result = await registry.execute(try XCTUnwrap(CommandID("portside.scan")))
        guard case .unavailable(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.contains("files"))
        XCTAssertEqual(ran, 0)
    }

    func testRegistryBlocksMissingAdapter() async throws {
        let registry = CommandRegistry()
        var ran = 0
        try registry.register(command("portside.ax", needs: [.accessibility], ran: { ran += 1 }))
        let result = await registry.execute(try XCTUnwrap(CommandID("portside.ax")))
        guard case .unavailable = result else { return XCTFail("\(result)") }
        XCTAssertEqual(ran, 0)
    }

    func testRegistryRevocationAfterValidationBlocksHandler() async throws {
        let box = Switch(.granted)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        let registry = CommandRegistry(permissions: gate)
        var ran = 0
        // The availability check runs after the permission precheck and before the handler.
        try registry.register(command("portside.scan", needs: [.app("files")], ran: { ran += 1 },
                                      unavailable: { box.state = .denied; return nil }))
        let result = await registry.execute(try XCTUnwrap(CommandID("portside.scan")))
        guard case .unavailable(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.contains("revoked"))
        XCTAssertEqual(ran, 0)
    }

    func testGrantedCommandRunsOnce() async throws {
        let box = Switch(.granted)
        let gate = PermissionGate()
        gate.register(adapter("files", box))
        let registry = CommandRegistry(permissions: gate)
        var ran = 0
        try registry.register(command("portside.scan", needs: [.app("files")], ran: { ran += 1 }))
        let result = await registry.execute(try XCTUnwrap(CommandID("portside.scan")))
        XCTAssertEqual(result, .success("ok"))
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(box.requests, 0)
    }
}
