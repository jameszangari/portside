import Combine
import XCTest
@testable import portside

/// P2-CMD-02: result IDs, ranking, cancellation, quicklink URLs, history,
/// providers and execution through the registry.
@MainActor
final class CommandCenterRankingTests: XCTestCase {
    private func command(_ raw: String, _ title: String, keywords: [String] = [], usage: Double = 0) -> CommandCenterItem {
        CommandCenterItem(id: CommandID(raw)!, title: title, keywords: keywords, usage: usage)
    }

    private func app(_ name: String, bundle: String, usage: Double = 0) -> CommandCenterItem {
        var item = CommandCenterCatalog.applicationItems(
            installed: [CommandCenterApp(path: "/Applications/\(name).app", bundleIdentifier: bundle, name: name)],
            running: [], open: nil
        )[0]
        item.usage = usage
        return item
    }

    private func titles(_ items: [CommandCenterItem], _ query: String) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.title) })
        return CommandCenterRanker.rank(items, query: query)!.compactMap { byID[$0] }
    }

    func testTiersRankExactPrefixWordsKeywordsInitialsFuzzy() {
        let items = [
            command("a.fuzzy", "Visual Coder"),            // v-s-c spread out: fuzzy
            command("a.initials", "Very Smart Cat"),       // initials v s c
            command("a.keyword", "Editor", keywords: ["vsc"]),
            command("a.words", "Open VSC Panel"),
            command("a.prefix", "VSC Tools"),
            command("a.exact", "VSC"),
            command("a.none", "Terminal"),
        ]
        XCTAssertEqual(titles(items.shuffled(), "vsc"), ["VSC", "VSC Tools", "Open VSC Panel", "Editor", "Very Smart Cat", "Visual Coder"])
        XCTAssertEqual(CommandCenterRanker.match(items[0], terms: ["vsc"])?.tier, .fuzzy)
        XCTAssertEqual(CommandCenterRanker.match(items[1], terms: ["vsc"])?.tier, .initials)
    }

    func testShortQueriesDoNotFuzzyMatch() {
        let items = [command("a.one", "Activity Monitor"), command("a.two", "Mail")]
        XCTAssertEqual(titles(items, "am"), [], "two letters: prefix or word only")
        XCTAssertEqual(titles(items, "mo"), ["Activity Monitor"])
    }

    func testCaseAndDiacriticsAreIgnored() {
        let items = [command("a.cafe", "Café Menu")]
        XCTAssertEqual(titles(items, "CAFE"), ["Café Menu"])
        XCTAssertEqual(titles(items, "café m"), ["Café Menu"])
    }

    func testTieBreaksAreFrecencyThenTitleThenIDWhateverTheInputOrder() {
        let items = [
            command("b.two", "Notes"),
            command("a.one", "Notes"),
            command("c.used", "Notes Archive", usage: 3),
            command("d.zed", "notes"),
        ]
        let expected = CommandCenterRanker.rank(items, query: "no")!
        for _ in 0..<20 { XCTAssertEqual(CommandCenterRanker.rank(items.shuffled(), query: "no"), expected) }
        // All title prefixes: the used one first, then title (case-folded), then ID.
        XCTAssertEqual(expected.map(\.rawValue), ["command:c.used", "command:a.one", "command:b.two", "command:d.zed"])
        // A better tier still beats frecency.
        XCTAssertEqual(titles(items, "notes")[0], "Notes", "exact title outranks a used prefix match")
    }

    func testDefaultListShowsUsedFirstAndHidesUnusedApps() {
        let items = [
            command("p.settings", "Open Settings"),
            app("Safari", bundle: "com.apple.Safari"),
            app("Mail", bundle: "com.apple.mail", usage: 2),
            command("p.about", "About Portside", usage: 1),
        ]
        XCTAssertEqual(CommandCenterRanker.defaultOrder(items.shuffled()).map(\.title), ["Mail", "About Portside", "Open Settings"])
        XCTAssertEqual(titles(items, "saf"), ["Safari"], "apps appear once typed")
    }

    func testRankStopsWhenCanceled() {
        let items = (0..<500).map { command("f.c\($0)", "Command \($0)") }
        var checks = 0
        XCTAssertNil(CommandCenterRanker.rank(items, query: "command", isCancelled: { checks += 1; return checks > 2 }))
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "command")?.count, 500)
    }

    func testResultIDsAreStableAndPrefixed() {
        XCTAssertEqual(CommandCenterResultID.command(CommandID("portside.quit")!).rawValue, "command:portside.quit")
        XCTAssertEqual(CommandCenterResultID.application(bundleIdentifier: "com.Apple.Safari", path: "/x/Safari.app").rawValue, "app:com.apple.safari")
        XCTAssertEqual(CommandCenterResultID.application(bundleIdentifier: nil, path: "/x/Tool.app").rawValue, "app:/x/Tool.app")
        XCTAssertEqual(CommandCenterResultID.settings("dock").rawValue, "settings:dock")
        let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        XCTAssertEqual(CommandCenterResultID.quicklink(uuid).rawValue, "quicklink:e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
        XCTAssertEqual(CommandCenterResultID(rawValue: "settings:dock"), .settings("dock"))
        XCTAssertNil(CommandCenterResultID(rawValue: "file:/etc/passwd"))
        XCTAssertNil(CommandCenterResultID(rawValue: "app:"))
    }
}

@MainActor
final class CommandCenterSearcherTests: XCTestCase {
    func testStartingASearchCancelsTheOneInFlight() async {
        let items = (0..<2000).map { CommandCenterItem(id: CommandID("f.c\($0)")!, title: "Command \($0)") }
        let searcher = CommandCenterSearcher()
        var delivered: [Int] = []
        let done = expectation(description: "latest delivered")
        for generation in 1...10 {
            searcher.start(CommandCenterSearchRequest(generation: generation, query: "command \(generation)"), items: items) { request, ids in
                delivered.append(request.generation)
                XCTAssertEqual(ids.first?.rawValue, "command:f.c\(request.generation)")
                if request.generation == 10 { done.fulfill() }
            }
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(delivered, [10], "only the latest search delivers")
    }

    func testCancelDropsTheResult() async throws {
        let searcher = CommandCenterSearcher()
        var delivered = false
        searcher.start(CommandCenterSearchRequest(generation: 1, query: "a"), items: []) { _, _ in delivered = true }
        searcher.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(delivered)
    }
}

final class QuicklinkURLTests: XCTestCase {
    private func problem(_ text: String) -> QuicklinkURL.Problem? {
        if case .failure(let problem) = QuicklinkURL.validate(text) { return problem }
        return nil
    }

    func testAllowlistedSchemesPass() {
        for text in ["https://example.com", "HTTPS://Example.com/a?b=c#d", "http://localhost:5173", "mailto:me@example.com",
                     "x-apple.systempreferences:com.apple.preference.security", "  https://padded.example  "] {
            XCTAssertNil(problem(text), text)
        }
    }

    func testOtherSchemesAreRefused() {
        XCTAssertEqual(problem("file:///etc/passwd"), .scheme("file"))
        XCTAssertEqual(problem("javascript:alert(1)"), .scheme("javascript"))
        XCTAssertEqual(problem("data:text/html,hi"), .scheme("data"))
        XCTAssertEqual(problem("ftp://example.com"), .scheme("ftp"))
        XCTAssertEqual(problem("ssh://host"), .scheme("ssh"))
        XCTAssertEqual(problem("raycast://extensions"), .scheme("raycast"))
        XCTAssertEqual(problem("Shortcuts://run-shortcut?name=x"), .scheme("shortcuts"))
    }

    func testMalformedLinksAreRefusedWithAReason() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("   "), .empty)
        XCTAssertEqual(problem("example.com"), .malformed, "no scheme")
        XCTAssertEqual(problem("not a link"), .malformed)
        XCTAssertEqual(problem("https://exa mple.com"), .malformed, "inner space")
        XCTAssertEqual(problem("https://example.com/\u{0007}"), .malformed, "control character")
        XCTAssertEqual(problem("https://"), .missingHost)
        XCTAssertEqual(problem("https:///path"), .missingHost)
        XCTAssertEqual(problem("mailto:"), .missingAddress)
        XCTAssertEqual(problem("https://user:secret@example.com"), .credentials)
        XCTAssertEqual(problem("https://example.com/" + String(repeating: "a", count: QuicklinkURL.maxLength)), .tooLong)
        for case let message in [QuicklinkURL.Problem.empty, .malformed, .scheme("file"), .missingHost, .credentials].map(\.message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testQuicklinksDecodeLenientlyAndRoundTrip() throws {
        let id = UUID()
        let json = """
        {"commandCenterQuicklinks": [
          {"id": "\(id.uuidString)", "name": "Docs", "url": "https://example.com/docs"},
          {"id": "\(id.uuidString)", "name": "Duplicate", "url": "https://dup.example"},
          {"name": "No id", "url": "https://x.example"},
          {"id": "\(UUID().uuidString)", "url": "file:///tmp"},
          "not an object"
        ]}
        """
        let model = try JSONDecoder().decode(DockModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.commandCenterQuicklinks.map(\.name), ["Docs", ""], "bad entries dropped alone, duplicate id dropped")
        XCTAssertEqual(model.commandCenterQuicklinks[1].url, "file:///tmp", "a refused URL is kept as typed")
        XCTAssertEqual(model.commandCenterQuicklinks[1].title, "file:///tmp")
        let again = try JSONDecoder().decode(DockModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(again.commandCenterQuicklinks, model.commandCenterQuicklinks)
        let empty = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try JSONDecoder().decode(DockModel.self, from: Data("{}".utf8)))) as? [String: Any]
        XCTAssertNil(empty?["commandCenterQuicklinks"], "not written while empty")
        let malformed = try JSONDecoder().decode(DockModel.self, from: Data(#"{"commandCenterQuicklinks": 7}"#.utf8))
        XCTAssertEqual(malformed.commandCenterQuicklinks, [])
    }
}

@MainActor
final class CommandCenterHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let safari = CommandCenterResultID.application(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app")
    private let settings = CommandCenterResultID.settings("dock")

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-history-\(UUID().uuidString)")
            .appendingPathComponent("command-center-history.json")
    }

    func testFrecencyCountsAndDecays() {
        let history = CommandCenterHistory(url: nil)
        history.record(safari, at: now)
        history.record(safari, at: now)
        XCTAssertEqual(history.score(safari, now: now), 2, accuracy: 0.0001)
        XCTAssertEqual(history.score(safari, now: now.addingTimeInterval(14 * 86_400)), 1, accuracy: 0.0001, "half after the half-life")
        XCTAssertEqual(history.score(settings, now: now), 0)
        // One use today beats ten uses two months ago.
        let old = CommandCenterHistory.score(.init(count: 10, lastUsed: now.addingTimeInterval(-60 * 86_400)), now: now)
        let fresh = CommandCenterHistory.score(.init(count: 1, lastUsed: now), now: now)
        XCTAssertGreaterThan(fresh, old)
    }

    func testPersistsReloadsAndClearDeletesTheFile() throws {
        let url = tempURL()
        let history = CommandCenterHistory(url: url)
        history.record(safari, at: now)
        history.record(settings, at: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("app:com.apple.safari"))
        let reloaded = CommandCenterHistory(url: url)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.score(safari, now: now), 1, accuracy: 0.0001)
        reloaded.clear()
        XCTAssertTrue(reloaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(CommandCenterHistory(url: url).isEmpty, "nothing comes back after clearing")
    }

    func testUnknownOrMalformedEntriesAreSkipped() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":1,"entries":[{"id":"settings:dock","count":3,"lastUsed":1800000000},{"id":"bogus:x","count":1,"lastUsed":1},{"id":"app:x","count":0,"lastUsed":1}]}"#
        try Data(json.utf8).write(to: url)
        let history = CommandCenterHistory(url: url)
        XCTAssertEqual(Array(history.entries.keys), [settings])
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(CommandCenterHistory(url: url).isEmpty)
    }

    func testPruningKeepsTheLimitAndDropsTheLowestScores() {
        let history = CommandCenterHistory(url: nil)
        history.record(safari, at: now)
        history.record(safari, at: now)
        for n in 0..<CommandCenterHistory.limit { history.record(.settings("pane\(n)"), at: now.addingTimeInterval(Double(n))) }
        XCTAssertEqual(history.entries.count, CommandCenterHistory.limit)
        XCTAssertNotNil(history.entries[safari], "the most used survives")
        XCTAssertNil(history.entries[.settings("pane0")], "the oldest single use goes first")
    }
}

@MainActor
final class CommandCenterProviderTests: XCTestCase {
    /// Gated commands hold the module registry weakly; keep it alive.
    private var modules: ModuleRegistry?

    private func registry(started: Bool = true, actions: CommandCenterActions = .none, openPane: @escaping (SettingsTab) -> Void = { _ in })
        throws -> (CommandRegistry, ModuleRegistry) {
        let commands = CommandRegistry(permissions: PermissionGate())
        let modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
        let center = CommandCenter(commands: commands, moduleTitle: { _ in nil }, registrar: { _, _ in NSObject() }, report: { _ in })
        try modules.register(PortsideCoreModule(isStarting: { !started }, openSettings: {}, openSettingsPane: openPane))
        try modules.register(CommandCenterModule(center: center, chords: Just(nil).eraseToAnyPublisher(), actions: actions))
        modules.enable(PortsideCoreModule.moduleID)
        modules.enable(CommandCenterModule.moduleID)
        self.modules = modules
        return (commands, modules)
    }

    func testSnapshotHasEveryProviderWithStableUniqueIDs() throws {
        let (commands, _) = try registry()
        let link = Quicklink(name: "Docs", url: "https://example.com")
        let sources = CommandCenterSources(
            quicklinks: { [link] },
            runningApps: { [CommandCenterApp(path: "/Applications/Mail.app", bundleIdentifier: "com.apple.mail", name: "Mail")] }
        )
        let items = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in "Portside" }, sources: sources)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "IDs are unique across providers")
        XCTAssertEqual(Set(items.map(\.kind)), [.command, .settings, .quicklink, .application])
        XCTAssertFalse(items.contains { $0.id == .command(CommandCenterModule.openAppCommand) }, "commands with input have no row of their own")
        XCTAssertFalse(items.contains { $0.id == .command(PortsideCoreModule.openSettingsPaneCommand) })
        XCTAssertTrue(items.contains { $0.id == .command(PortsideCoreModule.quitCommand) })
        XCTAssertEqual(items.filter { $0.kind == .settings }.count, SettingsTab.allCases.count)
        let again = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in "Portside" }, sources: sources)
        XCTAssertEqual(again.map(\.id), items.map(\.id))
    }

    func testUnavailableRowsExplainWhy() throws {
        let (commands, modules) = try registry(started: false)
        let links = [Quicklink(name: "Local file", url: "file:///etc/hosts"), Quicklink(name: "Half typed", url: "https://")]
        var items = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in nil }, sources: CommandCenterSources(quicklinks: { links }))
        let reasons = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.unavailableReason) })
        XCTAssertEqual(reasons["Dock Settings"], "Portside is still starting.")
        XCTAssertEqual(reasons["Local file"], QuicklinkURL.Problem.scheme("file").message)
        XCTAssertEqual(reasons["Half typed"], QuicklinkURL.Problem.missingHost.message)
        modules.disable(CommandCenterModule.moduleID)
        items = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in nil }, sources: CommandCenterSources(
            runningApps: { [CommandCenterApp(path: "/Applications/Mail.app", bundleIdentifier: "com.apple.mail", name: "Mail")] }
        ))
        XCTAssertEqual(items.first { $0.kind == .application }?.unavailableReason, "Command Center is turned off.")
    }

    func testRunningAndInstalledAppsMerge() {
        let installed = [
            CommandCenterApp(path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari", name: "Safari"),
            CommandCenterApp(path: "/Applications/Notes.app", bundleIdentifier: "com.apple.Notes", name: "Notes"),
        ]
        let running = [
            CommandCenterApp(path: "/Applications/Safari.app", bundleIdentifier: "com.apple.safari", name: "Safari"),
            CommandCenterApp(path: "/Users/me/Build/Tool.app", bundleIdentifier: nil, name: "Tool"),
        ]
        let items = CommandCenterCatalog.applicationItems(installed: installed, running: running, open: nil)
        XCTAssertEqual(items.map(\.title), ["Safari", "Notes", "Tool"])
        XCTAssertEqual(items.map(\.subtitle), ["Running", "Application", "Running"])
        XCTAssertEqual(items[0].primaryTitle, "Switch to App")
        XCTAssertEqual(items[2].id.rawValue, "app:/Users/me/Build/Tool.app")
        XCTAssertEqual(items[2].copyTitle, "Copy Path")
        XCTAssertEqual(items[1].invocation, CommandInvocation(command: CommandCenterModule.openAppCommand, input: .string("/Applications/Notes.app")))
        XCTAssertEqual(items[0].iconPath, "/Applications/Safari.app")
    }

    func testHistoryRanksSnapshotRows() throws {
        let (commands, _) = try registry()
        let history = CommandCenterHistory(url: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        history.record(.settings("general"), at: now)
        let items = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in nil },
                                               sources: CommandCenterSources(history: history, now: { now }))
        XCTAssertEqual(CommandCenterRanker.defaultOrder(items).first?.id, .settings("general"))
    }

    func testAppScanFindsTopLevelAndNestedAppsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portside-apps-\(UUID().uuidString)")
        func makeApp(_ relative: String, bundle: String?) throws {
            let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            if let bundle {
                try (["CFBundleIdentifier": bundle] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            }
        }
        try makeApp("Zeta.app", bundle: "com.example.zeta")
        try makeApp("Suite/Alpha.app", bundle: "com.example.alpha")
        try makeApp("Suite/Deeper/Hidden.app", bundle: "com.example.deep")
        try makeApp("Copy of Zeta.app", bundle: "com.example.ZETA")
        try makeApp("Bare.app", bundle: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".Secret.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let apps = CommandCenterAppIndex.scan([root, root.appendingPathComponent("Missing")])
        XCTAssertEqual(apps.map(\.name).sorted(), ["Alpha", "Bare", "Copy of Zeta"].sorted(),
                       "one folder down only, hidden skipped, first copy of a bundle ID wins")
        XCTAssertEqual(apps.first { $0.name == "Bare" }?.bundleIdentifier, nil)
    }
}

/// Every row runs a registry command; these check the commands themselves.
@MainActor
final class CommandCenterExecutionTests: XCTestCase {
    private var opened: [URL] = []
    private var launched: [URL] = []
    private var panes: [SettingsTab] = []
    private var links: [Quicklink] = []
    private var launchFailure: String?
    /// Gated commands hold the module registry weakly; keep it alive.
    private var modules: ModuleRegistry?

    private func registry() throws -> CommandRegistry {
        let commands = CommandRegistry(permissions: PermissionGate())
        let modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
        let center = CommandCenter(commands: commands, moduleTitle: { _ in nil }, registrar: { _, _ in NSObject() }, report: { _ in })
        let actions = CommandCenterActions(
            openApplication: { [unowned self] url in launched.append(url); return launchFailure },
            openURL: { [unowned self] url in opened.append(url); return true },
            quicklinks: { [unowned self] in links },
            bundleExists: { $0.hasPrefix("/Applications/") }
        )
        try modules.register(PortsideCoreModule(isStarting: { false }, openSettings: {}, openSettingsPane: { [unowned self] in panes.append($0) }))
        try modules.register(CommandCenterModule(center: center, chords: Just(nil).eraseToAnyPublisher(), actions: actions))
        modules.enable(PortsideCoreModule.moduleID)
        modules.enable(CommandCenterModule.moduleID)
        self.modules = modules
        return commands
    }

    func testOpenAppValidatesThePathFirst() async throws {
        let commands = try registry()
        let open = CommandCenterModule.openAppCommand
        let ok = await commands.execute(open, input: .string("/Applications/Notes.app"))
        XCTAssertEqual(ok, .success(nil))
        XCTAssertEqual(launched, [URL(fileURLWithPath: "/Applications/Notes.app")])
        let notApp = await commands.execute(open, input: .string("/bin/sh"))
        XCTAssertEqual(notApp, .failed("Not an app."))
        let relative = await commands.execute(open, input: .string("Notes.app"))
        XCTAssertEqual(relative, .failed("Not an app."))
        let gone = await commands.execute(open, input: .string("/Volumes/Old/Gone.app"))
        XCTAssertEqual(gone, .failed("Gone is no longer at /Volumes/Old."))
        let wrongInput = await commands.execute(open)
        XCTAssertEqual(wrongInput, .invalidInput("Input does not match what the command accepts."))
        XCTAssertEqual(launched.count, 1, "nothing invalid reached the launcher")
        launchFailure = "The application is damaged."
        let failed = await commands.execute(open, input: .string("/Applications/Broken.app"))
        XCTAssertEqual(failed, .failed("The application is damaged."))
    }

    func testOpenQuicklinkOnlyOpensSavedAllowedLinks() async throws {
        let commands = try registry()
        let good = Quicklink(name: "Docs", url: "https://example.com/docs")
        let bad = Quicklink(name: "Script", url: "javascript:alert(1)")
        links = [good, bad]
        let open = CommandCenterModule.openQuicklinkCommand
        let ok = await commands.execute(open, input: .string(good.id.uuidString))
        XCTAssertEqual(ok, .success(nil))
        XCTAssertEqual(opened, [URL(string: "https://example.com/docs")!])
        let refused = await commands.execute(open, input: .string(bad.id.uuidString))
        XCTAssertEqual(refused, .failed(QuicklinkURL.Problem.scheme("javascript").message))
        let unknown = await commands.execute(open, input: .string(UUID().uuidString))
        XCTAssertEqual(unknown, .failed("That quicklink was removed."))
        let url = await commands.execute(open, input: .string("https://evil.example"))
        XCTAssertEqual(url, .failed("That quicklink was removed."), "a raw URL is never opened")
        XCTAssertEqual(opened.count, 1)
    }

    func testOpenSettingsPaneRefusesUnknownPanes() async throws {
        let commands = try registry()
        let ok = await commands.execute(PortsideCoreModule.openSettingsPaneCommand, input: .string("general"))
        XCTAssertEqual(ok, .success(nil))
        let unknown = await commands.execute(PortsideCoreModule.openSettingsPaneCommand, input: .string("secrets"))
        XCTAssertEqual(unknown, .failed("There is no such Settings pane."))
        XCTAssertEqual(panes, [.general])
    }

    func testRowsRunTheirInvocationThroughTheRegistry() async throws {
        let commands = try registry()
        links = [Quicklink(name: "Docs", url: "https://example.com")]
        let items = CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in nil }, sources: CommandCenterSources(
            quicklinks: { [unowned self] in links },
            runningApps: { [CommandCenterApp(path: "/Applications/Mail.app", bundleIdentifier: "com.apple.mail", name: "Mail")] }
        ))
        for kind in [CommandCenterItem.Kind.settings, .quicklink, .application] {
            let item = try XCTUnwrap(items.first { $0.kind == kind })
            let result = await commands.execute(item.invocation.command, input: item.invocation.input)
            XCTAssertEqual(result, .success(nil), "\(kind)")
        }
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(launched, [URL(fileURLWithPath: "/Applications/Mail.app")])
    }
}
