import AppKit
import Foundation
import SQLite3
import os.log

/// Pulls live agent sessions from host apps that do not run Claude/Codex hooks.
///
/// T3 Code stores run status in `~/.t3/userdata/statev2.sqlite`. OpenCode keeps
/// busy/idle timestamps in `~/.local/share/opencode/opencode.db`. Both are
/// read-only, local, and need no tokens. Hook-fed Claude/Codex files stay the
/// primary source for CLI agents.
enum AgentSessionDiscovery {
    private static let log = Logger(subsystem: "com.james.portside", category: "Widgets")

    /// Active and recently finished T3 runs, plus busy/recent OpenCode sessions.
    /// `existing` are hook sessions already loaded; used to skip OpenCode rows
    /// that T3 already surfaces for the same project folder.
    static func discover(existing: [AgentSession] = []) -> [AgentSession] {
        // Isolated test homes must not read the developer's real T3/OpenCode DBs.
        if let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], fixed.hasPrefix("/tmp/") {
            return []
        }
        var next: [AgentSession] = []
        next.append(contentsOf: t3Sessions())
        let coveredProjects = Set((existing + next).compactMap(\.project))
        next.append(contentsOf: openCodeSessions(excludingProjects: coveredProjects))
        return next
    }

    // MARK: - T3 Code

    private static var t3Database: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/statev2.sqlite")
    }

    private static let t3Working: Set<String> = [
        "running", "waiting", "queued", "starting", "preparing"
    ]

    private static func t3Sessions() -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: t3Database.path) else { return [] }
        let hostPID = pid(ofBundleIDs: ["com.t3tools.t3code"])
        // Read through the WAL so a busy writer does not block us; ignore lock failures.
        // T3 stores ISO-8601 (`2026-11-04T04:40:51.869Z`). Normalize before
        // comparing to SQLite's `datetime('now')` (`2026-11-04 04:40:51`).
        let sql = """
        SELECT r.run_id, r.thread_id, r.provider, r.status, r.requested_at, r.completed_at,
               t.title,
               json_extract(t.payload_json, '$.worktreePath') AS worktree,
               p.worktree_path
        FROM orchestration_v2_projection_runs r
        LEFT JOIN orchestration_v2_projection_threads t ON t.thread_id = r.thread_id
        LEFT JOIN projection_threads p ON p.thread_id = r.thread_id
        WHERE t.deleted_at IS NULL
          AND (
            r.status IN ('running','waiting','queued','starting','preparing')
            OR (
              r.completed_at IS NOT NULL
              AND replace(replace(substr(r.completed_at,1,19),'T',' '),'Z','')
                  >= datetime('now', '-30 minutes')
            )
            OR (
              r.status IN ('interrupted','failed','cancelled')
              AND replace(replace(substr(r.requested_at,1,19),'T',' '),'Z','')
                  >= datetime('now', '-30 minutes')
            )
          )
        ORDER BY r.requested_at DESC
        LIMIT 40;
        """
        var rows: [[String: String]] = []
        let status = query(sql, database: t3Database) { rows.append($0) }
        if status != SQLITE_OK {
            log.error("t3 agents: sqlite \(status)")
            return []
        }

        var seenThreads = Set<String>()
        var sessions: [AgentSession] = []
        for row in rows {
            let thread = row["thread_id"] ?? ""
            guard !thread.isEmpty, seenThreads.insert(thread).inserted else { continue }
            let providerID = row["provider"] ?? "unknown"
            let statusName = row["status"] ?? ""
            let worktree = firstNonEmpty(row["worktree"], row["worktree_path"])
            let project = worktree.map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
            let updated = parseISO8601(row["completed_at"] ?? "")
                ?? parseISO8601(row["requested_at"] ?? "")
                ?? Date()
            let working = t3Working.contains(statusName)
            let needsAttention = statusName == "waiting"
            sessions.append(AgentSession(
                id: "t3:\(thread)",
                provider: AgentProvider.named(providerID),
                pid: hostPID ?? 0,
                state: working ? .running : .done,
                needsAttention: needsAttention,
                ended: false,
                updated: updated,
                project: project,
                host: "T3 Code",
                focusBundleIDs: ["com.t3tools.t3code"]
            ))
        }
        return sessions
    }

    // MARK: - OpenCode

    private static var openCodeDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    private static func openCodeSessions(excludingProjects: Set<String>) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: openCodeDatabase.path) else { return [] }
        let hostPID = openCodeServerPID()
            ?? pid(ofBundleIDs: ["com.t3tools.t3code"])
        // Busy when time_busy is set and newer than time_idle (or idle is null).
        // Also keep recently idled sessions so the notch can show "Finished".
        let sql = """
        SELECT id, title, directory, time_busy, time_idle, time_updated, idle_outcome
        FROM session_v2
        WHERE time_archived IS NULL
          AND time_busy IS NOT NULL
          AND (
            time_idle IS NULL
            OR time_busy > time_idle
            OR time_idle >= CAST((strftime('%s','now') - 1800) AS INTEGER) * 1000
          )
        ORDER BY time_updated DESC
        LIMIT 30;
        """
        var rows: [[String: String]] = []
        let status = query(sql, database: openCodeDatabase) { rows.append($0) }
        if status != SQLITE_OK {
            log.error("opencode agents: sqlite \(status)")
            return []
        }

        var sessions: [AgentSession] = []
        for row in rows {
            guard let id = row["id"], !id.isEmpty else { continue }
            let directory = row["directory"] ?? ""
            let project = URL(fileURLWithPath: directory).lastPathComponent
            let projectName = project.isEmpty || project == "/" ? nil : project
            if let projectName, excludingProjects.contains(projectName) { continue }
            let busy = Int64(row["time_busy"] ?? "") ?? 0
            let idle = Int64(row["time_idle"] ?? "")
            let working = idle == nil || busy > (idle ?? 0)
            let updatedMs = Int64(row["time_updated"] ?? "")
                ?? idle ?? busy
            let updated = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000)
            let hostName: String = {
                if let app = hostPID.flatMap({ AgentFocus.hostApp(of: $0) }) {
                    return app.localizedName ?? "OpenCode"
                }
                return "OpenCode"
            }()
            sessions.append(AgentSession(
                id: "opencode:\(id)",
                provider: AgentProvider.named("opencode"),
                pid: hostPID ?? 0,
                state: working ? .running : .done,
                needsAttention: false,
                ended: false,
                updated: updated,
                project: projectName,
                host: hostName,
                focusBundleIDs: ["com.t3tools.t3code"]
            ))
        }
        return sessions
    }

    // MARK: - SQLite helpers

    private static func query(_ sql: String, database: URL, row: ([String: String]) -> Void) -> Int32 {
        var db: OpaquePointer?
        // SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let open = sqlite3_open_v2(database.path, &db, flags, nil)
        guard open == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return open
        }
        defer { sqlite3_close(db) }
        // Prefer the on-disk snapshot if a writer holds the WAL lock.
        _ = sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)

        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { return prepare }
        defer { sqlite3_finalize(statement) }

        let count = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [String: String] = [:]
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, index))
                if let text = sqlite3_column_text(statement, index) {
                    values[name] = String(cString: text)
                }
            }
            row(values)
        }
        return SQLITE_OK
    }

    private static func parseISO8601(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: text)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.isEmpty && value.lowercased() != "null"
        } ?? nil
    }

    private static func pid(ofBundleIDs ids: [String]) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { app in ids.contains(where: { app.bundleIdentifier == $0 }) }?
            .processIdentifier
    }

    /// PID from T3's OpenCode server registry, else any live `opencode-servers` entry.
    private static func openCodeServerPID() -> pid_t? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/opencode-servers")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  isAlive(pid_t(pid)) else { continue }
            return pid_t(pid)
        }
        return nil
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
