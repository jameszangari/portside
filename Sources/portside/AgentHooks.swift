import Foundation
import os.log

/// Installs the hook the Agents widget reads (Settings > Widgets).
///
/// Hooks live in each user's own agent config, so every install needs this
/// once. Install writes `agent-hook.sh` next to dock.json and adds entries
/// tagged `# portside-agent-hook` to `~/.claude/settings.json` and
/// `~/.codex/hooks.json`, leaving other hooks alone. Each file is copied to
/// `<file>.portside.bak` the first time Portside changes it. Codex also
/// needs `codex_hooks = true` under `[features]` in `~/.codex/config.toml`.
enum AgentHooks {
    struct Target: Identifiable {
        let id: String
        let name: String
        /// Present when the agent is installed.
        let configDirectory: URL
        let hooksFile: URL
        let events: [String]
    }

    enum Status: Equatable {
        case notFound, notInstalled, installed
    }

    static let tag = "# portside-agent-hook"
    private static let logger = Logger(subsystem: "com.james.portside", category: "Widgets")
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let scriptURL: URL = AgentStatusWidget.directory
        .deletingLastPathComponent().appendingPathComponent("agent-hook.sh")

    static let targets: [Target] = [
        // SessionEnd removes the session; the idle-prompt Notification and
        // an interrupted tool mark it done when Stop never fires.
        Target(id: "claude", name: "Claude Code",
               configDirectory: home.appendingPathComponent(".claude"),
               hooksFile: home.appendingPathComponent(".claude/settings.json"),
               events: ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PostToolUseFailure", "SessionEnd"]),
        // Codex has no SessionEnd; the widget drops dead processes itself.
        Target(id: "codex", name: "Codex",
               configDirectory: home.appendingPathComponent(".codex"),
               hooksFile: home.appendingPathComponent(".codex/hooks.json"),
               events: ["SessionStart", "UserPromptSubmit", "Stop"]),
    ]

    static func status(_ target: Target) -> Status {
        guard FileManager.default.fileExists(atPath: target.configDirectory.path) else { return .notFound }
        let text = (try? String(contentsOf: target.hooksFile, encoding: .utf8)) ?? ""
        return text.contains(tag) && FileManager.default.fileExists(atPath: scriptURL.path) ? .installed : .notInstalled
    }

    /// Installs for every agent found. Safe to repeat.
    static func install() throws {
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writeScript()
        for target in targets where status(target) != .notFound {
            try edit(target, install: true)
        }
        if status(targets[1]) != .notFound {
            try enableCodexHooks()
        }
        logger.info("agent hooks installed")
    }

    /// Removes Portside's entries and the script. Leaves `codex_hooks` on,
    /// since other tools may use it.
    static func uninstall() throws {
        for target in targets where FileManager.default.fileExists(atPath: target.hooksFile.path) {
            try edit(target, install: false)
        }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: AgentStatusWidget.directory)
        logger.info("agent hooks removed")
    }

    /// Keeps an installed script current after a Portside update.
    static func updateScriptIfInstalled() {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) != script else { return }
        try? writeScript()
        logger.info("agent hook script updated")
    }

    private static func writeScript() throws {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        // The folder holds session payloads, which can include prompt text.
        let folder = scriptURL.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
    }

    /// Atomic writes make a new file with default permissions; put the
    /// original mode back so a 0600 config stays 0600. New files get 0600.
    private static func write(_ data: Data, to url: URL) throws {
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: url.path)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func backUp(_ url: URL) {
        let backup = URL(fileURLWithPath: url.path + ".portside.bak")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    /// Drops old Portside entries, then (when installing) adds one per event.
    private static func edit(_ target: Target, install: Bool) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: target.hooksFile), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw HookError.unreadable(target.hooksFile.path)
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var group = group
                let kept = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.contains(tag) ?? false)
                }
                guard !kept.isEmpty else { return nil }
                group["hooks"] = kept
                return group
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        if install {
            let command = "\(shellQuote(scriptURL.path)) \(target.id) \(tag)"
            for event in target.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": command]]])
                hooks[event] = groups
            }
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        backUp(target.hooksFile)
        try write(data, to: target.hooksFile)
    }

    /// Sets `codex_hooks = true` under `[features]`, line by line, so the
    /// rest of config.toml is untouched.
    private static func enableCodexHooks() throws {
        let url = home.appendingPathComponent(".codex/config.toml")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("codex_hooks") }) {
            guard !lines[index].contains("true") else { return }
            lines[index] = "codex_hooks = true"
        } else if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            lines.insert("codex_hooks = true", at: index + 1)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines += ["[features]", "codex_hooks = true", ""]
        }
        backUp(url)
        try write(Data(lines.joined(separator: "\n").utf8), to: url)
    }

    enum HookError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): "\(path) is not valid JSON, so it was left alone."
            }
        }
    }

    /// Run by Claude Code or Codex as `agent-hook.sh <provider>`. Reads the
    /// hook's JSON from stdin and writes `agents/<pid>.json` for the agent
    /// process. Must stay fast and never fail the agent: no output, exit 0.
    static let script = #"""
    #!/bin/bash
    # Portside Agents widget hook. Installed from Portside Settings > Widgets.
    umask 077
    provider="${1:-unknown}"
    dir="$HOME/Library/Application Support/com.james.portside/agents"
    payload=$(cat)
    [ -n "$payload" ] || payload='{}'

    # The agent process: climb past the hook shell to a durable ancestor.
    # Prefer a name that matches the provider; otherwise keep the highest
    # non-shell process so Portside does not delete the session when bash exits.
    agent_pid=$PPID
    pid=$PPID
    for _ in 1 2 3 4 5 6 7 8; do
      [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
      comm=$(ps -o comm= -p "$pid" 2>/dev/null)
      case "$comm" in
        *"$provider"*|*claude*|*codex*|*opencode*) agent_pid=$pid; break ;;
        -*|bash|zsh|sh|fish|dash|'') ;;
        *) agent_pid=$pid ;;
      esac
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done

    mkdir -p -m 700 "$dir" 2>/dev/null || exit 0
    tmp="$dir/.$agent_pid.$$"
    printf '{"provider":"%s","pid":%d,"time":%s,"payload":%s}\n' \
      "$provider" "$agent_pid" "$(date +%s)" "$payload" > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$dir/$agent_pid.json" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    exit 0

    """#
}
