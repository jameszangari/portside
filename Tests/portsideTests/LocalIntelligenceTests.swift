import XCTest
@testable import portside

/// Waits (bounded) for something another task does. Test-only.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<400 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition never became true", file: file, line: line)
}

@MainActor
final class ModelRouterTests: XCTestCase {
    private func router(_ fake: FakeLocalModelProvider, timeout: Duration = .seconds(5), availabilityTimeout: Duration = .seconds(5)) -> ModelRouter {
        ModelRouter(provider: fake, requestTimeout: timeout, availabilityTimeout: availabilityTimeout)
    }

    private func activated(_ fake: FakeLocalModelProvider, timeout: Duration = .seconds(5)) async -> ModelRouter {
        let router = router(fake, timeout: timeout)
        router.activate()
        await router.refreshAvailability()
        return router
    }

    func testDisabledReadsAndRunsNothing() async {
        let fake = FakeLocalModelProvider()
        let router = router(fake)
        XCTAssertEqual(router.state, .disabled)
        let refreshed = await router.refreshAvailability()
        XCTAssertEqual(refreshed, .disabled)
        let outcome = await router.respond(to: "hello")
        XCTAssertEqual(outcome, .disabled)
        let reads = await fake.availabilityReads
        let requests = await fake.requests
        XCTAssertEqual(reads, 0, "nothing is read while off")
        XCTAssertTrue(requests.isEmpty)
    }

    func testActivateChecksThenReady() async {
        let fake = FakeLocalModelProvider()
        let router = router(fake)
        router.activate()
        XCTAssertEqual(router.state, .checking)
        let state = await router.refreshAvailability()
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(router.state, .ready)
    }

    func testCompletedAnswerIsCappedToTheLimit() async {
        let fake = FakeLocalModelProvider(replies: [.answer("abcdef")])
        let router = await activated(fake)
        let outcome = await router.respond(to: "spell", maxOutputCharacters: 3)
        XCTAssertEqual(outcome, .completed(LocalModelResponse(text: "abc")))
        let requests = await fake.requests
        XCTAssertEqual(requests, [LocalModelRequest(prompt: "spell", maxOutputCharacters: 3)])
        XCTAssertEqual(router.state, .ready)
    }

    func testUnavailableStatesAreReportedAndNeverInfer() async {
        let cases: [(LocalModelAvailability, IntelligenceState, IntelligenceOutcome)] = [
            (.unsupported("old Mac"), .unsupported("old Mac"), .unsupported("old Mac")),
            (.unavailable("turned off"), .unavailable("turned off"), .unavailable("turned off")),
            (.notReady("preparing"), .notReady("preparing"), .notReady("preparing")),
        ]
        for (availability, state, outcome) in cases {
            let fake = FakeLocalModelProvider(availability: availability)
            let router = await activated(fake)
            XCTAssertEqual(router.state, state)
            let result = await router.respond(to: "hello")
            XCTAssertEqual(result, outcome)
            let requests = await fake.requests
            XCTAssertTrue(requests.isEmpty, "\(availability) must not reach the model")
            XCTAssertEqual(router.state, state)
        }
    }

    func testAvailabilityIsCheckedAtUseTimeAndTransitions() async {
        let fake = FakeLocalModelProvider(availability: .notReady("preparing"))
        let router = await activated(fake)
        XCTAssertEqual(router.state, .notReady("preparing"))
        await fake.setAvailability(.available)
        let ready = await router.respond(to: "hello")
        XCTAssertEqual(ready, .completed(LocalModelResponse(text: "ok")))
        XCTAssertEqual(router.state, .ready)
        // Turned off outside Portside after the last check.
        await fake.setAvailability(.unavailable("Apple Intelligence is off."))
        let off = await router.respond(to: "hello")
        XCTAssertEqual(off, .unavailable("Apple Intelligence is off."))
        XCTAssertEqual(router.state, .unavailable("Apple Intelligence is off."))
    }

    func testRefusalAndFailureAreDistinct() async {
        let fake = FakeLocalModelProvider(replies: [.refuse("guardrail"), .fail("context too long")])
        let router = await activated(fake)
        let refused = await router.respond(to: "one")
        XCTAssertEqual(refused, .refused("guardrail"))
        let failed = await router.respond(to: "two")
        XCTAssertEqual(failed, .failed("context too long"))
        XCTAssertEqual(router.state, .ready)
    }

    func testInvalidRequestsNeverReachTheProvider() async {
        let fake = FakeLocalModelProvider()
        let router = await activated(fake)
        let empty = await router.respond(to: "  \n")
        XCTAssertEqual(empty, .invalidRequest("The request is empty."))
        let long = await router.respond(to: String(repeating: "a", count: LocalModelRequest.maxPromptCharacters + 1))
        XCTAssertEqual(long, .invalidRequest("The request is longer than \(LocalModelRequest.maxPromptCharacters) characters."))
        let limit = await router.respond(to: "hi", maxOutputCharacters: 0)
        guard case .invalidRequest = limit else { return XCTFail("expected invalid request, got \(limit)") }
        let requests = await fake.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOneRequestAtATimeThenCancel() async {
        let fake = FakeLocalModelProvider(replies: [.hang])
        let router = await activated(fake)
        let first = Task { await router.respond(to: "first") }
        await eventually { await fake.requests.count == 1 }
        XCTAssertEqual(router.state, .busy)
        let second = await router.respond(to: "second")
        XCTAssertEqual(second, .busy)
        let refreshed = await router.refreshAvailability()
        XCTAssertEqual(refreshed, .busy, "a recheck while busy leaves the request alone")
        router.cancel()
        let outcome = await first.value
        XCTAssertEqual(outcome, .canceled)
        XCTAssertEqual(router.state, .ready)
        await eventually { await fake.cancellations == 1 }
        let requests = await fake.requests
        XCTAssertEqual(requests.map(\.prompt), ["first"], "the busy request never reached the provider")
    }

    func testCancelingTheCallerCancels() async {
        let fake = FakeLocalModelProvider(replies: [.hang])
        let router = await activated(fake)
        let task = Task { await router.respond(to: "hello") }
        await eventually { await fake.requests.count == 1 }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .canceled)
        await eventually { await fake.cancellations == 1 }
        XCTAssertEqual(router.state, .ready)
    }

    func testAlreadyCanceledCallerNeverReachesTheProvider() async {
        let fake = FakeLocalModelProvider()
        let router = await activated(fake)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await router.respond(to: "hello")
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .canceled)
        let requests = await fake.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancelDoesNotWaitForAProviderThatIgnoresItAndDropsTheLateAnswer() async {
        let fake = FakeLocalModelProvider(replies: [.stall("late answer"), .answer("fresh")])
        let router = await activated(fake)
        let task = Task { await router.respond(to: "slow") }
        await eventually { await fake.stalledCount == 1 }
        router.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .canceled, "returns before the provider stops")
        XCTAssertEqual(router.state, .ready)
        await fake.finishStalled()
        let next = await router.respond(to: "again")
        XCTAssertEqual(next, .completed(LocalModelResponse(text: "fresh")), "the late answer never surfaces")
    }

    func testTimeoutCancelsTheProvider() async {
        let fake = FakeLocalModelProvider(replies: [.hang])
        let router = await activated(fake, timeout: .milliseconds(50))
        let outcome = await router.respond(to: "hello")
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(router.state, .ready)
        await eventually { await fake.cancellations == 1 }
    }

    func testTimeoutWithAStalledProvider() async {
        let fake = FakeLocalModelProvider(replies: [.stall("late")])
        let router = await activated(fake, timeout: .milliseconds(50))
        let outcome = await router.respond(to: "hello")
        XCTAssertEqual(outcome, .timedOut)
        await fake.finishStalled()
        XCTAssertEqual(router.state, .ready)
    }

    func testSlowAvailabilityTimesOutAsUnavailable() async {
        let fake = FakeLocalModelProvider()
        await fake.setAvailabilityDelay(.seconds(10))
        let router = router(fake, availabilityTimeout: .milliseconds(50))
        router.activate()
        let state = await router.refreshAvailability()
        XCTAssertEqual(state, .unavailable("Test provider did not answer in time."))
        let outcome = await router.respond(to: "hello")
        XCTAssertEqual(outcome, .unavailable("Test provider did not answer in time."))
        let requests = await fake.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDeactivateCancelsTheRequestAndReleases() async {
        let fake = FakeLocalModelProvider(replies: [.stall("late")])
        let router = await activated(fake)
        let task = Task { await router.respond(to: "hello") }
        await eventually { await fake.stalledCount == 1 }
        router.deactivate()
        XCTAssertEqual(router.state, .disabled)
        let outcome = await task.value
        XCTAssertEqual(outcome, .canceled)
        await eventually { await fake.releases == 1 }
        await fake.finishStalled()
        let after = await router.respond(to: "hello")
        XCTAssertEqual(after, .disabled)
        XCTAssertEqual(router.state, .disabled)
    }

    func testAReadThatLandsAfterDeactivateIsDropped() async {
        let fake = FakeLocalModelProvider()
        await fake.setAvailabilityDelay(.milliseconds(100))
        let router = router(fake)
        router.activate()
        let read = Task { await router.refreshAvailability() }
        await eventually { await fake.availabilityReads == 1 }
        router.deactivate()
        _ = await read.value
        XCTAssertEqual(router.state, .disabled)
        router.activate()
        XCTAssertEqual(router.state, .checking, "a new activation starts unchecked")
    }

    func testShippedProviderIsUnsupportedAndNeverInfers() async {
        let router = ModelRouter(provider: NoLocalModelProvider())
        router.activate()
        let state = await router.refreshAvailability()
        guard case .unsupported = state else { return XCTFail("expected unsupported, got \(state)") }
        let outcome = await router.respond(to: "hello")
        guard case .unsupported = outcome else { return XCTFail("expected unsupported, got \(outcome)") }
    }

    func testFakeIsOnlyPickedForAnIsolatedHome() {
        XCTAssertNil(FakeLocalModelProvider.fromEnvironment(["PORTSIDE_INTELLIGENCE_FAKE": "available"]))
        XCTAssertNil(FakeLocalModelProvider.fromEnvironment(["PORTSIDE_INTELLIGENCE_FAKE": "available", "CFFIXED_USER_HOME": "/Users/me"]))
        XCTAssertNil(FakeLocalModelProvider.fromEnvironment(["PORTSIDE_INTELLIGENCE_FAKE": "cloud", "CFFIXED_USER_HOME": "/tmp/x"]))
        XCTAssertNotNil(FakeLocalModelProvider.fromEnvironment(["PORTSIDE_INTELLIGENCE_FAKE": "notReady", "CFFIXED_USER_HOME": "/tmp/x"]))
    }
}

@MainActor
final class IntelligenceModuleTests: XCTestCase {
    /// Gated commands hold the module registry weakly; keep it alive.
    private var modules: ModuleRegistry?

    private func setUp(_ fake: FakeLocalModelProvider) throws -> (CommandRegistry, ModuleRegistry, ModelRouter) {
        let commands = CommandRegistry(permissions: PermissionGate())
        let modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
        let router = ModelRouter(provider: fake)
        try modules.register(PortsideCoreModule(isStarting: { false }, openSettings: {}))
        try modules.register(IntelligenceModule(router: router))
        self.modules = modules
        return (commands, modules, router)
    }

    func testOffByDefaultAndHeldOffByRestrictedMode() throws {
        let (_, modules, router) = try setUp(FakeLocalModelProvider())
        modules.enableSaved(ModuleSettings())
        XCTAssertEqual(modules.state(of: IntelligenceModule.moduleID), .disabled)
        XCTAssertEqual(router.state, .disabled)
        var saved = ModuleSettings()
        saved.setEnabled(true, for: IntelligenceModule.moduleID)
        modules.enableSaved(saved, restricted: true)
        XCTAssertEqual(modules.state(of: IntelligenceModule.moduleID), .disabled)
        modules.enableSaved(saved)
        XCTAssertEqual(modules.state(of: IntelligenceModule.moduleID), .running)
    }

    func testEnableReadsAvailabilityAndDisableShutsDown() async throws {
        let fake = FakeLocalModelProvider(availability: .notReady("preparing"))
        let (_, modules, router) = try setUp(fake)
        modules.enable(IntelligenceModule.moduleID)
        XCTAssertEqual(modules.state(of: IntelligenceModule.moduleID), .running)
        await eventually { router.state == .notReady("preparing") }
        await fake.setAvailability(.available)
        await router.refreshAvailability()
        await fake.setReplies([.hang])
        let task = Task { await router.respond(to: "hello") }
        await eventually { await fake.requests.count == 1 }
        modules.disable(IntelligenceModule.moduleID)
        XCTAssertEqual(router.state, .disabled)
        XCTAssertEqual(modules.resourceCount(of: IntelligenceModule.moduleID), 0)
        let outcome = await task.value
        XCTAssertEqual(outcome, .canceled)
        await eventually { await fake.releases == 1 }
        await eventually { await fake.cancellations == 1 }
    }

    func testRepeatedCyclesLeaveNothingBehind() async throws {
        let fake = FakeLocalModelProvider()
        let (_, modules, router) = try setUp(fake)
        for _ in 0..<20 {
            modules.enable(IntelligenceModule.moduleID)
            modules.disable(IntelligenceModule.moduleID)
        }
        XCTAssertEqual(router.state, .disabled)
        XCTAssertEqual(modules.resourceCount(of: IntelligenceModule.moduleID), 0)
        await eventually { await fake.releases == 20 }
        let requests = await fake.requests
        XCTAssertTrue(requests.isEmpty, "enabling never runs inference")
    }

    func testStopAllOnQuitShutsDown() async throws {
        let fake = FakeLocalModelProvider()
        let (_, modules, router) = try setUp(fake)
        modules.enable(IntelligenceModule.moduleID)
        await eventually { router.state == .ready }
        modules.stopAll()
        XCTAssertEqual(router.state, .disabled)
        await eventually { await fake.releases == 1 }
    }

    /// Command Center needs no provider: core commands run with the module
    /// off, with no provider at all, and with an unsupported one running.
    func testCommandsWorkWithoutAProvider() async throws {
        var opened = 0
        let commands = CommandRegistry(permissions: PermissionGate())
        let modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
        try modules.register(PortsideCoreModule(isStarting: { false }, openSettings: { opened += 1 }))
        modules.enable(PortsideCoreModule.moduleID)
        self.modules = modules
        let withoutModule = await commands.execute(PortsideCoreModule.openSettingsCommand)
        XCTAssertEqual(withoutModule, .success(nil))
        let router = ModelRouter(provider: NoLocalModelProvider())
        try modules.register(IntelligenceModule(router: router))
        let moduleOff = await commands.execute(PortsideCoreModule.openSettingsCommand)
        XCTAssertEqual(moduleOff, .success(nil))
        modules.enable(IntelligenceModule.moduleID)
        await eventually { if case .unsupported = router.state { return true } else { return false } }
        let unsupported = await commands.execute(PortsideCoreModule.openSettingsCommand)
        XCTAssertEqual(unsupported, .success(nil))
        XCTAssertEqual(opened, 3)
        let items = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in nil }, sources: CommandCenterSources())
        XCTAssertNil(items.first { $0.id == .command(PortsideCoreModule.openSettingsCommand) }?.unavailableReason)
    }
}
