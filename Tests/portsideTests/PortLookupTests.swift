import Combine
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

/// lsof field output: one `node` process per port, pids from 4242.
private func listeners(_ ports: [UInt16]) -> Data {
    var text = ""
    for (index, port) in ports.enumerated() {
        text += "p\(4242 + index)\0cnode\0u501\0Ltester\0\n"
        text += "f20\0tIPv4\0PTCP\0n127.0.0.1:\(port)\0TST=LISTEN\0\n"
    }
    return Data(text.utf8)
}

private func proposal(_ kind: IntentKind, _ port: Int? = nil) -> FakeLocalModelProvider.Reply {
    .intent(RawIntentProposal(kind: kind.rawValue, port: port))
}

/// Which queries are port lookups, decided without a model.
final class PortQueryTests: XCTestCase {
    func testBarePortsAreDeterministic() {
        for query in ["5173", " 5173 ", ":5173", "5173?", "port 5173", "Port:5173", "localhost:5173", "127.0.0.1:5173", "[::1]:5173", "0.0.0.0:5173", "05173"] {
            XCTAssertEqual(PortQuery.classify(query), .port(5173), query)
        }
        XCTAssertEqual(PortQuery.classify("1"), .port(1))
        XCTAssertEqual(PortQuery.classify("65535"), .port(65535))
    }

    func testPortQuestionsGoToTheModelOnlyWithOneNumber() {
        XCTAssertEqual(PortQuery.classify("What's using port 5173?"), .interpret(port: 5173))
        XCTAssertEqual(PortQuery.classify("Show me port 3000"), .interpret(port: 3000))
        XCTAssertEqual(PortQuery.classify("what is running on localhost:8080"), .interpret(port: 8080))
        XCTAssertEqual(PortQuery.classify("What's running?"), .clarify(IntentValidator.Message.needsPort))
        XCTAssertEqual(PortQuery.classify("What's using ports 3000 and 5173?"), .clarify(IntentValidator.Message.onePort))
        XCTAssertEqual(PortQuery.classify("what's using port 70000"), .clarify(IntentValidator.Message.outOfRange))
        XCTAssertEqual(PortQuery.classify("what's using port 0"), .clarify(IntentValidator.Message.outOfRange))
    }

    func testEverythingElseIsNotALookup() {
        for query in ["", "safari", "ports", "show servers", "localhost", "70000", "0", "1password", "visual studio code", "running", "port node"] {
            XCTAssertEqual(PortQuery.classify(query), .none, query)
        }
    }
}

/// The lookup through a real `ModelRouter` and the deterministic fake provider.
@MainActor
final class PortLookupTests: XCTestCase {
    private func router(_ provider: FakeLocalModelProvider, active: Bool = true) -> ModelRouter {
        let router = ModelRouter(provider: provider, requestTimeout: .seconds(5), availabilityTimeout: .seconds(1))
        if active { router.activate() }
        return router
    }

    private func phase(_ lookup: PortLookup) -> PortLookupPhase? { lookup.current?.phase }

    func testQuestionIsReadByTheModelAndOnlyAValidatedPortWantsTheListing() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        var changes = 0
        lookup.onChange = { changes += 1 }
        let query = "What's using port 5173?"
        lookup.update(query, serversUnavailable: nil)
        XCTAssertEqual(phase(lookup), .interpreting(port: 5173))
        XCTAssertFalse(lookup.wantsListing(query), "nothing lists before validation")
        XCTAssertFalse(CommandCenter.wantsServers(query, lookup: lookup))
        await eventually { lookup.current?.phase == .port(5173, interpreted: true) }
        XCTAssertTrue(lookup.wantsListing(query))
        XCTAssertTrue(CommandCenter.wantsServers(query, lookup: lookup))
        XCTAssertFalse(lookup.wantsListing("What's using port 3000?"), "only for the query it answers")
        XCTAssertEqual(changes, 1)
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.prompt), [query], "the request text, nothing else")
    }

    func testShowMePortIsTheSameFlow() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 3000)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("Show me port 3000", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .port(3000, interpreted: true) }
    }

    func testBarePortAndClarificationsNeverRunTheModel() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("5173", serversUnavailable: nil)
        XCTAssertEqual(phase(lookup), .port(5173, interpreted: false))
        XCTAssertTrue(lookup.wantsListing("5173"))
        lookup.update("What's running?", serversUnavailable: nil)
        XCTAssertEqual(phase(lookup), .clarify(IntentValidator.Message.needsPort))
        XCTAssertFalse(CommandCenter.wantsServers("What's running?", lookup: lookup))
        lookup.update("What's using ports 3000 and 5173?", serversUnavailable: nil)
        XCTAssertEqual(phase(lookup), .clarify(IntentValidator.Message.onePort))
        XCTAssertFalse(CommandCenter.wantsServers("What's using ports 3000 and 5173?", lookup: lookup), "no scan for an ambiguous request")
        lookup.update("safari", serversUnavailable: nil)
        XCTAssertNil(lookup.current)
        try? await Task.sleep(for: .milliseconds(30))
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty, "deterministic queries need no inference")
    }

    func testNumericSearchWorksWithIntelligenceOffOrAbsent() async {
        let provider = FakeLocalModelProvider()
        for lookup in [PortLookup(router: router(provider, active: false), settle: .zero), PortLookup(router: nil, settle: .zero)] {
            lookup.update("5173", serversUnavailable: nil)
            XCTAssertEqual(lookup.current?.phase, .port(5173, interpreted: false))
            lookup.update("What's using port 5173?", serversUnavailable: nil)
            XCTAssertEqual(lookup.current?.phase, .unavailable(PortLookup.Message.off, port: 5173), "explains and offers the number")
        }
        let reads = await provider.availabilityReads
        let requests = await provider.requests
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(requests.isEmpty)
    }

    func testModelAmbiguityAndUnsupportedRequests() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.ambiguous), proposal(.unsupported)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("which server is on 5173 or so", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .clarify(IntentValidator.Message.needsPort) }
        lookup.update("stop the server on port 5173", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .unsupported(IntentValidator.Message.unsupported) }
        XCTAssertFalse(lookup.wantsListing("stop the server on port 5173"))
    }

    func testInventedPortIsRejectedAndTheTypedNumberIsOffered() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 4242), proposal(.findPortOwner, nil)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("What's using port 5173?", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .failed(IntentValidator.Message.notInRequest, port: 5173) }
        XCTAssertFalse(lookup.wantsListing("What's using port 5173?"), "an invented port lists nothing")
        lookup.update("What is using port 5173", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .failed(IntentValidator.Message.missingPort, port: 5173) }
    }

    func testUnavailableProviderExplainsAndOffersNumericSearch() async {
        for (availability, reason) in [
            (LocalModelAvailability.unavailable("Apple Intelligence is turned off in System Settings."), "Apple Intelligence is turned off in System Settings."),
            (.notReady("The test model is still preparing."), "The test model is still preparing."),
            (.unsupported("The test model does not run on this Mac."), "The test model does not run on this Mac."),
        ] {
            let provider = FakeLocalModelProvider(availability: availability, replies: [proposal(.findPortOwner, 5173)])
            let lookup = PortLookup(router: router(provider), settle: .zero)
            lookup.update("What's using port 5173?", serversUnavailable: nil)
            await eventually { lookup.current?.phase == .unavailable(reason, port: 5173) }
            let requests = await provider.requests
            XCTAssertTrue(requests.isEmpty, "availability is read; nothing is inferred")
        }
    }

    func testLocalServersOffSkipsTheModel() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("What's using port 5173?", serversUnavailable: "Local Servers is turned off.")
        XCTAssertEqual(phase(lookup), .serversUnavailable("Local Servers is turned off."))
        lookup.update("5173", serversUnavailable: "Local Servers is turned off.")
        XCTAssertEqual(phase(lookup), .serversUnavailable("Local Servers is turned off."))
        try? await Task.sleep(for: .milliseconds(30))
        let reads = await provider.availabilityReads
        XCTAssertEqual(reads, 0)
    }

    func testANewQueryCancelsInferenceInFlight() async {
        let provider = FakeLocalModelProvider(replies: [.hang, proposal(.findPortOwner, 3000)])
        let router = router(provider)
        let lookup = PortLookup(router: router, settle: .zero)
        lookup.update("What's using port 5173?", serversUnavailable: nil)
        await eventually { await provider.requests.count == 1 }
        lookup.update("What's using port 3000?", serversUnavailable: nil)
        XCTAssertEqual(phase(lookup), .interpreting(port: 3000))
        await eventually { await provider.cancellations == 1 }
        await eventually { lookup.current?.phase == .port(3000, interpreted: true) }
        XCTAssertEqual(lookup.current?.key, "what s using port 3000", "the old answer never lands")
    }

    func testClosingCancelsInferenceAndForgetsTheQuery() async {
        let provider = FakeLocalModelProvider(replies: [.hang])
        let router = router(provider)
        let lookup = PortLookup(router: router, settle: .zero)
        var changes = 0
        lookup.onChange = { changes += 1 }
        lookup.update("What's using port 5173?", serversUnavailable: nil)
        await eventually { router.state == .busy }
        lookup.end()
        XCTAssertNil(lookup.current)
        await eventually { await provider.cancellations == 1 }
        await eventually { router.state == .ready }
        XCTAssertEqual(changes, 0, "a canceled request reports nothing")
    }

    func testStaleProposalIsDropped() async {
        // The first provider call ignores cancellation and answers late.
        let provider = FakeLocalModelProvider(replies: [.stallIntent(RawIntentProposal(kind: "findPortOwner", port: 5173)), proposal(.findPortOwner, 3000)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("What's using port 5173?", serversUnavailable: nil)
        await eventually { await provider.stalledCount == 1 }
        lookup.update("What's using port 3000?", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .port(3000, interpreted: true) }
        await provider.finishStalled()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(lookup.current?.phase, .port(3000, interpreted: true), "the late 5173 never replaces 3000")
    }

    func testTypingRunsTheModelOnceAfterTheQueryRests() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let lookup = PortLookup(router: router(provider), settle: .milliseconds(60))
        for query in ["what's using port 5", "what's using port 51", "what's using port 517", "what's using port 5173"] {
            lookup.update(query, serversUnavailable: nil)
        }
        await eventually { lookup.current?.phase == .port(5173, interpreted: true) }
        let prompts = await provider.requests.map(\.prompt)
        XCTAssertEqual(prompts, ["what's using port 5173"])
    }

    func testSameQueryKeyKeepsTheLookup() async {
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let lookup = PortLookup(router: router(provider), settle: .zero)
        lookup.update("What's using port 5173", serversUnavailable: nil)
        await eventually { lookup.current?.phase == .port(5173, interpreted: true) }
        lookup.update("what's using port 5173?", serversUnavailable: nil)
        XCTAssertEqual(lookup.current?.phase, .port(5173, interpreted: true), "case and punctuation do not ask again")
        let count = await provider.requests.count
        XCTAssertEqual(count, 1)
    }

    func testEveryOutcomeMapsToFixedText() {
        let cases: [(IntentOutcome, PortLookupPhase)] = [
            (.proposed(.findPortOwner(port: 80)), .port(80, interpreted: true)),
            (.needsDetail("d"), .clarify("d")),
            (.unsupportedIntent("u"), .unsupported("u")),
            (.invalidIntent("i"), .failed("i", port: 80)),
            (.stopped(.disabled), .unavailable(PortLookup.Message.off, port: 80)),
            (.stopped(.notReady("n")), .unavailable("n", port: 80)),
            (.stopped(.busy), .failed(PortLookup.Message.busy, port: 80)),
            (.stopped(.timedOut), .failed(PortLookup.Message.timedOut, port: 80)),
            (.stopped(.canceled), .failed(PortLookup.Message.stopped, port: 80)),
            (.stopped(.refused("r")), .failed("r", port: 80)),
            (.stopped(.failed("f")), .failed("f", port: 80)),
        ]
        for (outcome, expected) in cases { XCTAssertEqual(PortLookup.phase(for: outcome, port: 80), expected, "\(outcome)") }
    }

    func testLookupSourceStaysLocalAndReadOnly() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/portside/CommandCenter/PortLookup.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let banned = ["URLSession", "URLRequest", "Process(", "NSTask", "posix_spawn", "/bin/", "http:", "https:", "kill(", "SIGTERM", "SIGKILL",
                      "environment", "NSAppleScript", "dlopen"]
        for word in banned { XCTAssertFalse(source.contains(word), "PortLookup.swift contains \(word)") }
    }
}

/// The lookup row and the server cards through the real registries and store.
@MainActor
final class PortLookupCatalogTests: XCTestCase {
    private lazy var commands = CommandRegistry(permissions: PermissionGate())
    private lazy var modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
    private var center: CommandCenter?

    private func install(_ ports: [UInt16], servers: Bool = true) throws -> LocalServerStore {
        let source = FixtureListenerSource(stdout: listeners(ports), inspector: FakeProcessInspector.owning([4242, 4243, 4244]))
        let store = LocalServerStore(service: ListenerService(source: source))
        let center = CommandCenter(commands: commands, moduleTitle: { _ in nil }, registrar: { _, _ in NSObject() }, report: { _ in })
        self.center = center
        try modules.register(CommandCenterModule(center: center, chords: Just(nil).eraseToAnyPublisher()))
        try modules.register(LocalServersModule(store: store))
        modules.enable(CommandCenterModule.moduleID)
        if servers { modules.enable(LocalServersModule.moduleID) }
        return store
    }

    private func items(_ store: LocalServerStore, _ lookup: PortLookup?) -> [CommandCenterItem] {
        CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in "Local Servers" }, sources: CommandCenterSources(servers: store, portLookup: lookup))
    }

    private func serversUnavailable() -> String? {
        commands.descriptor(for: LocalServersModule.refreshCommand)?.unavailableReason()
    }

    func testQuestionShowsTheSameServerCardAsTheNumericSearch() async throws {
        let store = try install([3000, 5173])
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let router = ModelRouter(provider: provider)
        router.activate()
        let lookup = PortLookup(router: router, settle: .zero)
        let query = "What's using port 5173?"
        lookup.update(query, serversUnavailable: serversUnavailable())
        let reading = try XCTUnwrap(items(store, lookup).first { $0.id == .portLookup })
        XCTAssertEqual(reading.title, "Reading your request…")
        XCTAssertEqual(reading.queryReplacement, "5173", "Return skips the model")
        await eventually { lookup.current?.phase == .port(5173, interpreted: true) }
        XCTAssertEqual(items(store, lookup).first { $0.id == .portLookup }?.title, "Looking up port 5173…")
        _ = await commands.execute(LocalServersModule.refreshCommand)

        let rows = items(store, lookup)
        let ranked = try XCTUnwrap(CommandCenterRanker.rank(rows, query: query))
        let card = try XCTUnwrap(rows.first { $0.id == ranked.first })
        XCTAssertEqual(card.kind, .server, "the server card is first")
        XCTAssertEqual(card.title, "Port 5173 · node")
        XCTAssertEqual(ranked[1], .portLookup)
        XCTAssertFalse(ranked.prefix(2).contains { $0.rawValue.hasPrefix("server:3000") }, "only the asked port answers")
        let row = try XCTUnwrap(rows.first { $0.id == .portLookup })
        XCTAssertEqual(row.title, "Port 5173: 1 server visible to you")
        XCTAssertTrue(row.detail?.hasPrefix("Test provider read the port on this Mac; the process facts come from lsof.") == true)
        XCTAssertNil(row.queryReplacement)
        XCTAssertEqual(row.invocation, CommandInvocation(command: LocalServersModule.refreshCommand, staysOpen: true))

        // The numeric search builds the identical card from the same snapshot.
        let numeric = PortLookup(router: nil)
        numeric.update("5173", serversUnavailable: serversUnavailable())
        let numericRows = items(store, numeric)
        let numericCard = try XCTUnwrap(numericRows.first { $0.id == card.id })
        XCTAssertEqual(numericCard.facts, card.facts, "every fact comes from the listing, never the model")
        XCTAssertEqual(numericCard.detail, card.detail)
        XCTAssertEqual(numericCard.invocation, card.invocation)
        XCTAssertEqual(numericCard.moreActions, card.moreActions)
        XCTAssertEqual(card.facts.first { $0.label == "PID" }?.value, "4243")
        XCTAssertEqual(CommandCenterRanker.rank(numericRows, query: "5173")?.first, card.id)
    }

    func testNoVisibleListenerSaysResultsAreThisUsersOnly() async throws {
        let store = try install([3000])
        let lookup = PortLookup(router: nil)
        lookup.update("5173", serversUnavailable: serversUnavailable())
        _ = await commands.execute(LocalServersModule.refreshCommand)
        let rows = items(store, lookup)
        let row = try XCTUnwrap(rows.first { $0.id == .portLookup })
        XCTAssertEqual(row.title, "Nothing visible to you on port 5173")
        XCTAssertTrue(row.detail?.contains("Only processes your account can see are listed; other users' and system processes are not shown.") == true)
        XCTAssertEqual(CommandCenterRanker.rank(rows, query: "5173")?.first, .portLookup)
    }

    func testOffModulesSayWhyAndRunNothing() async throws {
        let store = try install([5173], servers: false)
        let provider = FakeLocalModelProvider(replies: [proposal(.findPortOwner, 5173)])
        let router = ModelRouter(provider: provider)
        router.activate()
        let lookup = PortLookup(router: router, settle: .zero)
        lookup.update("What's using port 5173?", serversUnavailable: serversUnavailable())
        let row = try XCTUnwrap(items(store, lookup).first { $0.id == .portLookup })
        XCTAssertEqual(row.unavailableReason, "Local Servers is turned off.")
        XCTAssertFalse(CommandCenter.shouldListServers("5173", store: store, alreadyRequested: false, lookup: lookup))
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(store.snapshot)
    }

    func testUnavailableModelRowOffersTheNumericSearch() throws {
        let store = try install([5173])
        let lookup = PortLookup(router: nil)
        lookup.update("What's using port 5173?", serversUnavailable: serversUnavailable())
        let row = try XCTUnwrap(items(store, lookup).first { $0.id == .portLookup })
        XCTAssertEqual(row.title, "Search port 5173 instead")
        XCTAssertEqual(row.detail, PortLookup.Message.off)
        XCTAssertEqual(row.primaryTitle, "Search Port 5173")
        XCTAssertEqual(row.queryReplacement, "5173")
        XCTAssertNil(row.unavailableReason)
    }

    func testClarificationRowNeedsMoreDetail() throws {
        let store = try install([5173])
        let lookup = PortLookup(router: nil)
        lookup.update("What's using ports 3000 and 5173?", serversUnavailable: serversUnavailable())
        let row = try XCTUnwrap(items(store, lookup).first { $0.id == .portLookup })
        XCTAssertEqual(row.title, "Which port?")
        XCTAssertEqual(row.unavailableReason, IntentValidator.Message.onePort)
        XCTAssertEqual(CommandCenterRanker.rank(items(store, lookup), query: "What's using ports 3000 and 5173?")?.first, .portLookup)
    }

    func testServerQueriesStillListAsBefore() throws {
        let store = try install([5173])
        let lookup = PortLookup(router: nil)
        XCTAssertTrue(CommandCenter.shouldListServers("ports", store: store, alreadyRequested: false, lookup: lookup))
        XCTAssertTrue(CommandCenter.shouldListServers("5173", store: store, alreadyRequested: false, lookup: lookup))
        XCTAssertFalse(CommandCenter.shouldListServers("safari", store: store, alreadyRequested: false, lookup: lookup))
        XCTAssertTrue(CommandCenter.shouldListServers("what's using port 5173", store: store, alreadyRequested: false, lookup: nil),
                      "without a lookup a server word lists, as in DEV-02")
    }
}

/// Command Center state for the lookup row.
final class PortLookupStateTests: XCTestCase {
    private func lookupRow(_ key: String, replacement: String?) -> CommandCenterItem {
        var item = CommandCenterItem(
            id: .portLookup, kind: .lookup, title: "Search port 5173 instead", subtitle: "Port Lookup",
            invocation: CommandInvocation(command: LocalServersModule.refreshCommand, staysOpen: true),
            primaryTitle: "Search Port 5173", copyValue: "", copyTitle: ""
        )
        item.answers = key
        item.queryReplacement = replacement
        return item
    }

    private let other = CommandCenterItem(id: CommandID("portside.openSettings")!, title: "Open Settings", keywords: ["port"])

    private func settle(_ state: inout CommandCenterState, _ effects: [CommandCenterEffect]) {
        for case .search(let request) in effects {
            _ = state.send(.results(request, CommandCenterRanker.rank(state.items, query: request.query)!))
        }
    }

    func testReturnOnTheOfferSearchesTheNumber() {
        let query = "What's using port 5173?"
        // Also matches the question, and is selected before it is typed.
        let both = CommandCenterItem(id: CommandID("portside.showAbout")!, title: "About", keywords: ["what", "s", "using", "port", "5173"])
        var state = CommandCenterState()
        _ = state.send(.open([both]))
        XCTAssertEqual(state.selection, both.id)
        // The lookup row arrives before the query's own ranking lands.
        _ = state.send(.query(query))
        settle(&state, state.send(.catalog([both, lookupRow(CommandCenterRanker.answerKey(query), replacement: "5173")])).effects)
        XCTAssertEqual(state.results.map(\.id), [.portLookup, both.id])
        XCTAssertEqual(state.selection, .portLookup, "a fresh query selects its first result, not the old selection")
        let effects = state.send(.key(.return)).effects
        XCTAssertEqual(state.query, "5173")
        XCTAssertNil(state.running, "nothing runs")
        XCTAssertTrue(effects.contains(.announce("Searching 5173.")))
        XCTAssertTrue(effects.contains { if case .search(let request) = $0 { return request.query == "5173" } else { return false } })
    }

    func testLookupRowHasNoCopyAndSkipsHistory() {
        let row = lookupRow("5173", replacement: nil)
        var state = CommandCenterState()
        _ = state.send(.open([row]))
        settle(&state, state.send(.query("5173")).effects)
        XCTAssertFalse(state.actions(for: row).contains { $0.kind == .copyID })
        XCTAssertEqual(state.send(.key(.return)).effects, [.run(.portLookup)])
        let done = state.send(.finished(.portLookup, .success("1 server visible to you.")))
        XCTAssertFalse(done.effects.contains(.recordUsage(.portLookup)))
        XCTAssertTrue(state.isVisible, "Refresh stays open")
    }

    func testAnswerRanksOnlyForItsQuery() {
        let row = lookupRow("what s using port 5173", replacement: nil)
        XCTAssertEqual(CommandCenterRanker.rank([other, row], query: "What's using port 5173?"), [.portLookup])
        XCTAssertEqual(CommandCenterRanker.rank([other, row], query: "What's using port 3000?"), [], "a stale answer matches nothing")
    }
}
