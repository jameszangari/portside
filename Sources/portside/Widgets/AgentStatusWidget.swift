import AppKit
import SwiftUI
import os.log

/// Coding agents (Claude Code, Codex): which provider, how many are working,
/// and whether the latest turn finished.
///
/// Fed by the hook script `AgentHooks` installs (Settings > Widgets),
/// which the agents run. It writes one JSON file per agent process into
/// `agents/` next to dock.json. A folder watch reloads on every write; the
/// slow timer only drops sessions whose process quit without a SessionEnd
/// hook.
final class AgentStatusWidget: DockWidget {
    static let kind = "agents"
    let name = "Agents"
    var hoverTitle: String { Self.summary(sessions) }
    let icon = Image(systemName: "sparkles")
    let size = WidgetSize.medium
    let refreshInterval: TimeInterval = 10

    @Published private(set) var sessions: [AgentSession] = []

    private var watcher: DispatchSourceFileSystemObject?
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("com.james.portside/agents", isDirectory: true)

    func start() {
        AgentHooks.updateScriptIfInstalled()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("agents: cannot watch \(Self.directory.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        AppActivity.shared.setAgentWorking(nil)
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var next: [AgentSession] = []
        for url in files where url.pathExtension == "json" {
            guard let session = AgentSession(contentsOf: url) else { continue }
            // SessionEnd, or the agent quit without one: forget it.
            if session.ended || (session.pid > 0 && !Self.isAlive(session.pid)) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            var located = session
            if located.host == nil {
                located.host = hostName(session.pid)
            }
            next.append(located)
        }
        // T3 Code / OpenCode do not fire Claude hooks; merge their local DBs.
        let discovered = AgentSessionDiscovery.discover(existing: next)
        var seen = Set(next.map(\.id))
        for session in discovered where seen.insert(session.id).inserted {
            next.append(session)
        }
        next.sort { $0.updated > $1.updated }
        AppActivity.shared.setAgentWorking(workingHosts(next))
        if next != sessions {
            sessions = next
            let running = next.filter { $0.state == .running }.count
            let done = next.filter { $0.state == .done }.count
            logger.info("agents: \(next.count) sessions, \(running) running, \(done) done")
        }
    }

    /// Focuses the window of the agent that is working (latest first),
    /// else the one that finished last.
    func activate() {
        let target = sessions.first { $0.state == .running }
            ?? sessions.first { $0.state == .done }
            ?? sessions.first
        guard let target else { return }
        AgentFocus.focus(session: target)
    }

    var body: some View {
        AgentStatusView(summary: AgentSummary(sessions))
    }

    static func summary(_ sessions: [AgentSession]) -> String {
        guard !sessions.isEmpty else { return "Agents · None running" }
        return AgentGroup.make(sessions).map { group in
            let state = group.running > 0 ? "\(group.running) working" : group.done > 0 ? "done" : "idle"
            var parts = [group.provider.name, state]
            if let first = group.projects.first {
                parts.append(group.projects.count > 1 ? "\(first) +\(group.projects.count - 1)" : first)
            }
            return parts.joined(separator: " · ")
        }.joined(separator: "   ")
    }

    /// Bundle ids of the apps hosting a running session: the agent's own
    /// app ancestor, else the app a discovered row belongs to (T3 Code).
    private func workingHosts(_ sessions: [AgentSession]) -> Set<String> {
        var ids = Set<String>()
        for session in sessions where session.state == .running {
            if session.pid > 0, let id = hostBundleID(session.pid) {
                ids.insert(id)
            } else {
                ids.formUnion(session.focusBundleIDs)
            }
        }
        return ids
    }

    private var hostBundleIDs: [pid_t: String?] = [:]

    private func hostBundleID(_ pid: pid_t) -> String? {
        if let cached = hostBundleIDs[pid] { return cached }
        let id = AgentFocus.hostApp(of: pid)?.bundleIdentifier
        hostBundleIDs[pid] = id
        return id
    }

    /// Host app per agent pid; an agent never changes host.
    private var hosts: [pid_t: String] = [:]

    private func hostName(_ pid: pid_t) -> String? {
        if let name = hosts[pid] { return name }
        let name = AgentFocus.hostApp(of: pid)?.localizedName
        hosts[pid] = name
        return name
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

enum AgentState: Equatable {
    case idle, running, done
}

/// The company behind an agent, with the desktop app whose icon stands in
/// for its logo.
struct AgentProvider: Hashable, Identifiable {
    let id: String
    let name: String
    let vendor: String
    let bundleIDs: [String]
    /// Ring and accent color in the Usage widget.
    let color: Color

    static let all = [named("claude"), named("codex"), named("copilot"), named("opencode"), named("cursor")]

    static func named(_ id: String) -> AgentProvider {
        switch id {
        case "claude", "claudeAgent":
            AgentProvider(id: "claude", name: "Claude", vendor: "Anthropic",
                          bundleIDs: ["com.anthropic.claudefordesktop", "com.t3tools.t3code"],
                          color: Color(red: 0.85, green: 0.47, blue: 0.34))
        case "codex":
            AgentProvider(id: "codex", name: "Codex", vendor: "OpenAI",
                          bundleIDs: ["com.openai.codex", "com.t3tools.t3code"],
                          color: Color(red: 0.25, green: 0.55, blue: 1.0))
        case "copilot":
            AgentProvider(id: "copilot", name: "Copilot", vendor: "GitHub",
                          bundleIDs: ["com.github.CopilotForXcode", "com.t3tools.t3code"],
                          color: Color(red: 0.62, green: 0.40, blue: 0.95))
        case "opencode":
            AgentProvider(id: "opencode", name: "OpenCode", vendor: "OpenCode",
                          bundleIDs: ["com.t3tools.t3code"],
                          color: Color(red: 0.95, green: 0.72, blue: 0.25))
        case "cursor":
            AgentProvider(id: "cursor", name: "Cursor", vendor: "Cursor",
                          bundleIDs: ["com.t3tools.t3code"],
                          color: Color(red: 0.45, green: 0.75, blue: 0.95))
        default:
            AgentProvider(id: id, name: id.capitalized, vendor: id.capitalized,
                          bundleIDs: ["com.t3tools.t3code"], color: .gray)
        }
    }

    /// Looked up once per provider, not on every render.
    var appIcon: NSImage? {
        if let cached = Self.icons[id] { return cached }
        let icon = bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.icons[id] = icon
        return icon
    }

    private static var icons: [String: NSImage?] = [:]
}

/// One agent session: a Claude/Codex hook file, or a T3 / OpenCode discovery row.
struct AgentSession: Equatable {
    let id: String
    let provider: AgentProvider
    let pid: pid_t
    let state: AgentState
    let needsAttention: Bool
    let ended: Bool
    let updated: Date
    /// Working folder name ("my-project"), used to find its window.
    let project: String?
    /// The app it runs in ("T3 Code", "Terminal"), filled in by the widget.
    var host: String?
    /// Bundle IDs to activate when `pid` is missing or not an app process.
    let focusBundleIDs: [String]

    init(id: String, provider: AgentProvider, pid: pid_t, state: AgentState,
         needsAttention: Bool, ended: Bool, updated: Date, project: String?,
         host: String?, focusBundleIDs: [String] = []) {
        self.id = id
        self.provider = provider
        self.pid = pid
        self.state = state
        self.needsAttention = needsAttention
        self.ended = ended
        self.updated = updated
        self.project = project
        self.host = host
        self.focusBundleIDs = focusBundleIDs
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int else { return nil }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let event = payload["hook_event_name"] as? String ?? ""
        needsAttention = event == "Notification" && ["permission_prompt", "elicitation_dialog"].contains(payload["notification_type"] as? String ?? "")
        provider = AgentProvider.named(json["provider"] as? String ?? "unknown")
        self.pid = pid_t(pid)
        id = "hook:\(pid)"
        updated = Date(timeIntervalSince1970: json["time"] as? TimeInterval ?? 0)
        ended = event == "SessionEnd"
        project = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        host = nil
        focusBundleIDs = []
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            state = .running
        case "Stop":
            state = .done
        case "PostToolUseFailure":
            // Esc mid-tool ends the turn without a Stop hook.
            state = payload["is_interrupt"] as? Bool == true ? .done : .running
        case "Notification":
            // Claude Code's 60s idle reminder: the turn is over. Permission
            // prompts keep the turn going.
            state = payload["notification_type"] as? String == "idle_prompt" ? .done : .running
        default:
            state = .idle
        }
    }
}

/// Sessions of one provider, for hover text.
struct AgentGroup {
    let provider: AgentProvider
    let running: Int
    let done: Int
    let projects: [String]
    let hosts: [String]

    /// Providers with work first, then by latest activity.
    static func make(_ sessions: [AgentSession]) -> [AgentGroup] {
        var order: [AgentProvider] = []
        for session in sessions where !order.contains(session.provider) {
            order.append(session.provider)
        }
        let groups = order.map { provider in
            let mine = sessions.filter { $0.provider == provider }
            return AgentGroup(provider: provider,
                              running: mine.filter { $0.state == .running }.count,
                              done: mine.filter { $0.state == .done }.count,
                              projects: AgentSummary.uniqueProjects(mine),
                              hosts: Array(Set(mine.compactMap(\.host))).sorted())
        }
        return groups.enumerated().sorted { a, b in
            (a.element.running > 0) != (b.element.running > 0) ? a.element.running > 0 : a.offset < b.offset
        }.map(\.element)
    }
}

/// What the tile draws: the provider of the latest working agent (else the
/// latest one), counts across all providers, and project names.
struct AgentSummary {
    let provider: AgentProvider?
    let running: Int
    let done: Int
    /// Working agents' projects first, then finished ones.
    let projects: [String]
    /// Apps they run in, same order.
    let hosts: [String]

    init(_ sessions: [AgentSession]) {
        let working = sessions.filter { $0.state == .running }
        let finished = sessions.filter { $0.state == .done }
        provider = working.first?.provider ?? finished.first?.provider ?? sessions.first?.provider
        running = working.count
        done = finished.count
        projects = Self.uniqueProjects(working + finished)
        hosts = Self.unique((working + finished).compactMap(\.host))
    }

    init(provider: AgentProvider?, running: Int, done: Int, projects: [String], hosts: [String]) {
        self.provider = provider
        self.running = running
        self.done = done
        self.projects = projects
        self.hosts = hosts
    }

    static func uniqueProjects(_ sessions: [AgentSession]) -> [String] {
        unique(sessions.compactMap(\.project))
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: [String] = []
        for name in names where !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }

    /// "2 working", "Done", or "Idle". Finished counts are in the hover.
    var status: String {
        if running > 0 { return "\(running) working" }
        return done > 0 ? (done > 1 ? "\(done) done" : "Done") : "Idle"
    }
}

struct AgentStatusView: View {
    let summary: AgentSummary
    @Environment(\.dockTileSize) private var tile
    @Environment(\.widgetSize) private var chosen

    var body: some View {
        let size = WidgetSize.resolved(chosen, natural: .medium)
        let inset = WidgetLayout.inset(tile)
        let side = WidgetLayout.itemSide(tile)
        WidgetTile(size: size) {
            if let provider = summary.provider {
                if size == .small {
                    AgentBadge(provider: provider, running: summary.running, done: summary.done, side: side)
                } else {
                    // The icon names the provider (hover has it in words),
                    // so the two lines are status and where it runs.
                    HStack(spacing: inset) {
                        AgentBadge(provider: provider, running: summary.running, done: summary.done, side: side)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(summary.status)
                                .font(.system(size: WidgetTypography.fontSize(6.5, tile: tile), weight: .semibold))
                            // "T3 Code +1": the name truncates, the count shows.
                            if let first = summary.hosts.first {
                                HStack(spacing: tile * 0.04) {
                                    Text(first)
                                    if summary.hosts.count > 1 {
                                        Text("+\(summary.hosts.count - 1)").fixedSize()
                                    }
                                }
                                .font(.system(size: WidgetTypography.fontSize(5.5, tile: tile)))
                                .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, inset)
                }
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: WidgetTypography.fontSize(12, tile: tile)))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Provider icon inside a spinning ring with the working count while agents
/// run, or a green check once they are done. `side` is the whole badge, so
/// it lines up with album art and usage gauges.
private struct AgentBadge: View {
    let provider: AgentProvider
    let running: Int
    let done: Int
    let side: CGFloat

    var body: some View {
        let line = max(1.5, side * 0.07)
        ProviderLogo(provider: provider, side: side - 4 * line)
            .opacity(running == 0 && done == 0 ? 0.55 : 1)
            .frame(width: side, height: side)
            .overlay {
                if running > 0 {
                    SpinningRing(color: provider.color, lineWidth: line)
                }
            }
            .overlay(alignment: .topTrailing) {
                if running > 0 {
                    CountBadge(count: running, side: side * 0.36)
                        .offset(x: side * 0.06, y: -side * 0.06)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if running == 0 && done > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .frame(width: side * 0.34, height: side * 0.34)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.name), " + (running > 0 ? "\(running) working" : done > 0 ? "done" : "idle"))
    }
}

/// A short arc circling the icon. Core Animation drives it, so a working
/// agent costs no timer. Static under Reduce Motion.
private struct SpinningRing: View {
    let color: Color
    let lineWidth: CGFloat
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
        }
        .padding(lineWidth / 2)
        .onAppear { turning = true }
    }
}

struct ProviderLogo: View {
    let provider: AgentProvider
    let side: CGFloat

    var body: some View {
        if let icon = provider.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        } else {
            Text(provider.name.prefix(1))
                .font(.system(size: side * 0.55, weight: .bold, design: .rounded))
                .frame(width: side, height: side)
                .background(Circle().fill(provider.color.opacity(0.3)))
        }
    }
}

private struct CountBadge: View {
    let count: Int
    let side: CGFloat

    var body: some View {
        Text("\(count)")
            .font(.system(size: side * 0.68, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, side * 0.2)
            .frame(minWidth: side, minHeight: side)
            .background(Capsule().fill(Color.red))
    }
}
