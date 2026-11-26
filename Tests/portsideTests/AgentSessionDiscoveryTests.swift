import SQLite3
import XCTest
@testable import portside

/// T3 Code and OpenCode discovery against fixture databases with the
/// columns Portside reads; the real ones in the home folder are never opened.
final class AgentSessionDiscoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func database(_ name: String, _ sql: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: error!)])
        }
        return url
    }

    private static func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(offset))
    }

    private static func millis(_ offset: TimeInterval) -> Int64 {
        Int64((Date().timeIntervalSince1970 + offset) * 1000)
    }

    // MARK: T3 Code

    private static let t3Schema = """
    CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT, provider TEXT, status TEXT, requested_at TEXT, completed_at TEXT);
    CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, title TEXT, payload_json TEXT, project_id TEXT, deleted_at TEXT);
    CREATE TABLE projection_threads (thread_id TEXT, worktree_path TEXT, project_id TEXT);
    CREATE TABLE projection_projects (project_id TEXT, workspace_root TEXT);
    INSERT INTO projection_projects VALUES ('p1', '/Users/me/Developer/portside');
    """

    private func run(_ id: String, thread: String, provider: String = "claudeAgent", status: String,
                     requested: TimeInterval = -60, completed: TimeInterval? = nil) -> String {
        let done = completed.map { "'\(Self.iso($0))'" } ?? "NULL"
        return "INSERT INTO orchestration_v2_projection_runs VALUES ('\(id)', '\(thread)', '\(provider)', '\(status)', '\(Self.iso(requested))', \(done));"
    }

    private func thread(_ id: String, worktree: String? = nil, deleted: Bool = false) -> String {
        let payload = worktree.map { #"{"worktreePath":"\#($0)"}"# } ?? #"{"worktreePath":null}"#
        return "INSERT INTO orchestration_v2_projection_threads VALUES ('\(id)', 'title', '\(payload)', 'p1', \(deleted ? "'2026-01-01'" : "NULL"));"
    }

    private func t3(_ rows: [String]) throws -> [AgentSession] {
        let url = try database("statev2.sqlite", Self.t3Schema + rows.joined(separator: "\n"))
        return AgentSessionDiscovery.t3Sessions(database: url, hostPID: 42, hostName: "T3 Code (Beta)")
    }

    func testT3RunningAndWaitingRuns() throws {
        let sessions = try t3([
            thread("a", worktree: "/Users/me/.t3/worktrees/portside/feat-x"), run("r1", thread: "a", status: "running"),
            thread("b", worktree: "/Users/me/.t3/worktrees/portside/fix-y"), run("r2", thread: "b", provider: "codex", status: "waiting"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let a = try XCTUnwrap(byID["t3:a"])
        XCTAssertEqual(a.state, .running)
        XCTAssertFalse(a.needsAttention)
        XCTAssertEqual(a.project, "feat-x")
        XCTAssertEqual(a.pid, 42)
        XCTAssertEqual(a.host, "T3 Code (Beta)")
        XCTAssertEqual(a.focusBundleIDs, ["com.t3tools.t3code"])
        let b = try XCTUnwrap(byID["t3:b"])
        XCTAssertEqual(b.state, .running)
        XCTAssertTrue(b.needsAttention, "waiting means it needs you")
        XCTAssertEqual(b.provider.id, AgentProvider.named("codex").id)
    }

    func testThreadInTheProjectFolderUsesTheProjectRoot() throws {
        // No worktree: the project root names it, so it merges with the
        // hook session from the same folder instead of showing twice.
        let sessions = try t3([thread("a"), run("r1", thread: "a", status: "running")])
        XCTAssertEqual(sessions.map(\.project), ["portside"])
    }

    func testOneSessionPerThreadNewestRunWins() throws {
        let sessions = try t3([
            thread("a", worktree: "/w/x"),
            run("old", thread: "a", status: "completed", requested: -600, completed: -500),
            run("new", thread: "a", status: "running", requested: -10),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .running)
    }

    func testRecentlyFinishedShowsDoneAndOldOnesAreDropped() throws {
        let sessions = try t3([
            thread("recent", worktree: "/w/recent"), run("r1", thread: "recent", status: "completed", requested: -300, completed: -120),
            thread("old", worktree: "/w/old"), run("r2", thread: "old", status: "completed", requested: -7200, completed: -3600),
            thread("failed", worktree: "/w/failed"), run("r3", thread: "failed", status: "failed", requested: -60),
            thread("stale", worktree: "/w/stale"), run("r4", thread: "stale", status: "interrupted", requested: -7200),
        ])
        XCTAssertEqual(Set(sessions.map(\.id)), ["t3:recent", "t3:failed"])
        XCTAssertTrue(sessions.allSatisfy { $0.state == .done })
    }

    func testDeletedThreadsAreSkipped() throws {
        let sessions = try t3([thread("a", worktree: "/w/x", deleted: true), run("r1", thread: "a", status: "running")])
        XCTAssertTrue(sessions.isEmpty)
    }

    func testMissingOrForeignDatabaseReadsAsNone() throws {
        XCTAssertTrue(AgentSessionDiscovery.t3Sessions(database: directory.appendingPathComponent("none.sqlite"), hostPID: nil, hostName: "T3 Code").isEmpty)
        let other = try database("other.sqlite", "CREATE TABLE unrelated (x TEXT);")
        XCTAssertTrue(AgentSessionDiscovery.t3Sessions(database: other, hostPID: nil, hostName: "T3 Code").isEmpty)
    }

    func testDiscoveredT3RowMergesWithItsHookSession() throws {
        let discovered = try t3([thread("a"), run("r1", thread: "a", status: "running")])
        let hook = AgentSession(id: "hook:1", provider: AgentProvider.named("claudeAgent"), pid: 7, state: .running,
                                needsAttention: false, ended: false, updated: Date(), project: "portside", host: "T3 Code (Beta)")
        let merged = AgentStatusWidget.merged(hooks: [hook], discovered: discovered)
        XCTAssertEqual(merged.map(\.id), ["hook:1"], "one run, one row")
    }

    // MARK: OpenCode

    private func openCode(_ rows: [(id: String, directory: String, busy: TimeInterval?, idle: TimeInterval?, archived: Bool)],
                          excluding: Set<String> = []) throws -> [AgentSession] {
        var sql = "CREATE TABLE session_v2 (id TEXT, title TEXT, directory TEXT, time_busy INTEGER, time_idle INTEGER, time_updated INTEGER, idle_outcome TEXT, time_archived INTEGER);\n"
        for row in rows {
            let busy = row.busy.map { String(Self.millis($0)) } ?? "NULL"
            let idle = row.idle.map { String(Self.millis($0)) } ?? "NULL"
            let updated = Self.millis(max(row.busy ?? -3600, row.idle ?? -3600))
            sql += "INSERT INTO session_v2 VALUES ('\(row.id)', 't', '\(row.directory)', \(busy), \(idle), \(updated), NULL, \(row.archived ? "1" : "NULL"));\n"
        }
        let url = try database("opencode.db", sql)
        return AgentSessionDiscovery.openCodeSessions(database: url, excludingProjects: excluding, hostPID: nil, hostName: "OpenCode")
    }

    func testOpenCodeBusyIdleAndArchived() throws {
        let sessions = try openCode([
            ("busy", "/Users/me/a", -30, nil, false),
            ("busyAgain", "/Users/me/b", -10, -60, false),
            ("finished", "/Users/me/c", -300, -120, false),
            ("old", "/Users/me/d", -7200, -3600, false),
            ("archived", "/Users/me/e", -10, nil, true),
            ("neverBusy", "/Users/me/f", nil, -10, false),
        ])
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        XCTAssertEqual(Set(byID.keys), ["opencode:busy", "opencode:busyAgain", "opencode:finished"])
        XCTAssertEqual(byID["opencode:busy"]?.state, .running)
        XCTAssertEqual(byID["opencode:busyAgain"]?.state, .running)
        XCTAssertEqual(byID["opencode:finished"]?.state, .done)
        XCTAssertEqual(byID["opencode:busy"]?.project, "a")
        XCTAssertEqual(byID["opencode:busy"]?.host, "OpenCode")
    }

    func testOpenCodeSkipsProjectsT3AlreadyShows() throws {
        let sessions = try openCode([("x", "/Users/me/portside", -10, nil, false), ("y", "/", -10, nil, false)], excluding: ["portside"])
        XCTAssertEqual(sessions.map(\.id), ["opencode:y"])
        XCTAssertNil(sessions.first?.project, "the root folder has no project name")
    }

    // MARK: ChatGPT

    func testChatGPTReplyingThenDone() {
        var tracker = ChatGPTReplies.Tracker()
        let start = Date()
        tracker.update(replying: ["Vocal Suggestions", "Trip plan"], now: start)
        let replying = Dictionary(uniqueKeysWithValues: tracker.sessions(hostPID: 7, hostName: "ChatGPT").map { ($0.id, $0) })
        XCTAssertEqual(Set(replying.keys), ["chatgpt:Vocal Suggestions", "chatgpt:Trip plan"])
        let chat = replying["chatgpt:Vocal Suggestions"]
        XCTAssertEqual(chat?.state, .running)
        XCTAssertEqual(chat?.project, "Vocal Suggestions", "the window title finds the window on click")
        XCTAssertEqual(chat?.provider.id, "chatgpt")
        XCTAssertEqual(chat?.pid, 7)
        XCTAssertEqual(chat?.focusBundleIDs, ["com.openai.codex"])

        let later = start.addingTimeInterval(60)
        tracker.update(replying: ["Trip plan"], now: later)
        let done = Dictionary(uniqueKeysWithValues: tracker.sessions(hostPID: 7, hostName: "ChatGPT").map { ($0.id, $0) })
        XCTAssertEqual(done["chatgpt:Vocal Suggestions"]?.state, .done)
        XCTAssertEqual(done["chatgpt:Vocal Suggestions"]?.updated, later)
        XCTAssertEqual(done["chatgpt:Trip plan"]?.updated, start, "a reply keeps the time it started")

        tracker.update(replying: ["Vocal Suggestions"], now: later.addingTimeInterval(5))
        XCTAssertEqual(tracker.sessions(hostPID: 7, hostName: "ChatGPT").first { $0.id == "chatgpt:Vocal Suggestions" }?.state,
                       .running, "a new reply in a finished chat is working again")

        tracker.update(replying: [], now: later.addingTimeInterval(2000))
        XCTAssertEqual(tracker.sessions(hostPID: 7, hostName: "ChatGPT").map(\.id), ["chatgpt:Vocal Suggestions"],
                       "finished chats drop after 30 minutes")
    }

    func testIsolatedHomeNeverReadsRealDatabases() {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.hasPrefix("/tmp/") == true else {
            return
        }
        XCTAssertTrue(AgentSessionDiscovery.discover().isEmpty)
    }
}
