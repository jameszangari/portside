import XCTest
@testable import portside

/// Install and remove against a temporary home; the real `~/.claude` and
/// `~/.codex` are never read or written.
final class AgentHooksTests: XCTestCase {
    private var home: URL!
    private var savedHome: URL!
    private var savedScript: URL!
    private let files = FileManager.default

    override func setUpWithError() throws {
        home = files.temporaryDirectory.appendingPathComponent("agent-hooks-\(UUID().uuidString)")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        savedHome = AgentHooks.home
        savedScript = AgentHooks.scriptURL
        AgentHooks.home = home
        AgentHooks.scriptURL = home.appendingPathComponent("Library/Application Support/com.james.portside/agent-hook.sh")
    }

    override func tearDownWithError() throws {
        AgentHooks.home = savedHome
        AgentHooks.scriptURL = savedScript
        try? files.removeItem(at: home)
    }

    private var claude: AgentHooks.Target { AgentHooks.targets[0] }
    private var codex: AgentHooks.Target { AgentHooks.targets[1] }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func commands(_ url: URL, _ event: String) throws -> [String] {
        let hooks = try json(url)["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    private let userSettings = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#

    func testMissingAgentsAreNotFoundAndLeftAlone() throws {
        XCTAssertEqual(AgentHooks.status(claude), .notFound)
        try AgentHooks.install()
        XCTAssertFalse(files.fileExists(atPath: claude.hooksFile.path))
        XCTAssertFalse(files.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    func testInstallAddsOneEntryPerEventAndKeepsTheUsersHooks() throws {
        try files.createDirectory(at: claude.configDirectory, withIntermediateDirectories: true)
        try Data(userSettings.utf8).write(to: claude.hooksFile)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claude.hooksFile.path)
        XCTAssertEqual(AgentHooks.status(claude), .notInstalled)

        try AgentHooks.install()
        XCTAssertEqual(AgentHooks.status(claude), .installed)
        for event in claude.events {
            XCTAssertEqual(try commands(claude.hooksFile, event).filter { $0.contains(AgentHooks.tag) }.count, 1, event)
        }
        XCTAssertEqual(try commands(claude.hooksFile, "Stop").first, "say done", "the user's own hook stays first")
        XCTAssertEqual(try json(claude.hooksFile)["model"] as? String, "opus")
        XCTAssertEqual(try mode(claude.hooksFile), 0o644, "the file keeps its mode")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: claude.hooksFile.path + ".portside.bak"), encoding: .utf8), userSettings)
        XCTAssertEqual(try mode(AgentHooks.scriptURL), 0o700)
        XCTAssertEqual(try mode(AgentHooks.scriptURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(AgentHooks.status(codex), .notFound)
    }

    func testInstallTwiceDoesNotDuplicateOrReplaceTheBackup() throws {
        try files.createDirectory(at: claude.configDirectory, withIntermediateDirectories: true)
        try Data(userSettings.utf8).write(to: claude.hooksFile)
        try AgentHooks.install()
        try AgentHooks.install()
        XCTAssertEqual(try commands(claude.hooksFile, "SessionStart").count, 1)
        XCTAssertEqual(try commands(claude.hooksFile, "Stop").count, 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: claude.hooksFile.path + ".portside.bak"), encoding: .utf8),
                       userSettings, "the first original survives")
    }

    func testUninstallRemovesOnlyPortsideEntries() throws {
        try files.createDirectory(at: claude.configDirectory, withIntermediateDirectories: true)
        try Data(userSettings.utf8).write(to: claude.hooksFile)
        try AgentHooks.install()
        try files.createDirectory(at: AgentHooks.sessionsDirectory, withIntermediateDirectories: true)
        try AgentHooks.uninstall()
        XCTAssertEqual(try commands(claude.hooksFile, "Stop"), ["say done"])
        XCTAssertNil((try json(claude.hooksFile)["hooks"] as? [String: Any])?["SessionStart"], "emptied events are dropped")
        XCTAssertFalse(files.fileExists(atPath: AgentHooks.scriptURL.path))
        XCTAssertFalse(files.fileExists(atPath: AgentHooks.sessionsDirectory.path))
        XCTAssertEqual(AgentHooks.status(claude), .notInstalled)
    }

    func testUnreadableConfigIsLeftAlone() throws {
        try files.createDirectory(at: claude.configDirectory, withIntermediateDirectories: true)
        let broken = Data("{ \"hooks\": ".utf8)
        try broken.write(to: claude.hooksFile)
        XCTAssertThrowsError(try AgentHooks.install()) { error in
            XCTAssertTrue(error.localizedDescription.contains("not valid JSON"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: claude.hooksFile), broken)
    }

    func testCodexHooksAndFeatureFlag() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        let cases: [(before: String, after: String)] = [
            ("model = \"gpt\"\n", "model = \"gpt\"\n\n[features]\ncodex_hooks = true\n"),
            ("[features]\nother = 1\n", "[features]\ncodex_hooks = true\nother = 1\n"),
            ("[features]\ncodex_hooks = false\n", "[features]\ncodex_hooks = true\n"),
            ("[features]\ncodex_hooks = true\n", "[features]\ncodex_hooks = true\n"),
        ]
        for (before, after) in cases {
            try? files.removeItem(at: codex.configDirectory)
            try files.createDirectory(at: codex.configDirectory, withIntermediateDirectories: true)
            try Data(before.utf8).write(to: config)
            try AgentHooks.install()
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), after, before)
            XCTAssertEqual(AgentHooks.status(codex), .installed)
            XCTAssertEqual(try commands(codex.hooksFile, "Stop").count, 1)
            XCTAssertEqual(try mode(codex.hooksFile), 0o600, "a new hooks file is private")
        }
    }

    func testScriptWritesAPrivateSessionFileAndStaysSilent() throws {
        try files.createDirectory(at: claude.configDirectory, withIntermediateDirectories: true)
        try AgentHooks.install()
        let process = Process()
        process.executableURL = AgentHooks.scriptURL
        process.arguments = ["claude"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","cwd":"/tmp/x"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "no output into the agent")

        let agents = home.appendingPathComponent("Library/Application Support/com.james.portside/agents")
        let written = try files.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let file = try XCTUnwrap(written.first)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(try mode(file), 0o600)
        let record = try json(file)
        XCTAssertEqual(record["provider"] as? String, "claude")
        XCTAssertEqual((record["payload"] as? [String: Any])?["hook_event_name"] as? String, "Stop")
        XCTAssertNotNil(record["pid"] as? Int)
    }
}
