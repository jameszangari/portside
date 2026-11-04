import AppKit
import Combine
import SwiftUI
import os.log

/// Plan usage meters for coding agents: the share of each provider's limits
/// used (5 hour and weekly, or monthly for Copilot), per provider picked in
/// Settings > Widgets or the widget's right-click menu.
///
/// Sources (read on a 5 minute refresh, off the main thread):
/// - Claude: Claude Code's sign-in from the login keychain, read with
///   /usr/bin/security (the tool Claude Code stores it with, so no
///   prompt), sent to Anthropic's OAuth usage endpoint. Not a documented
///   API; any failure shows as a note instead of meters. Nothing is read
///   or sent until the user agrees (`DockModel.usageClaudeConsent`).
/// - Codex: the `rate_limits` Codex writes into its session logs under
///   ~/.codex/sessions. Local only; as fresh as the last Codex turn.
/// - Copilot: account-wide monthly quota, so it covers use in editors, the
///   CLI, and `copilot --acp` alike. ACP itself has no quota method, so this
///   asks the Copilot CLI's headless server (`account.getQuota`, marked
///   experimental by GitHub), which uses the CLI's own sign-in. Without the
///   CLI, the GitHub CLI's token goes to GitHub's Copilot user endpoint (not
///   a documented API). Nothing runs until the user agrees
///   (`DockModel.usageCopilotConsent`).
final class UsageWidget: DockWidget, DockModelWidget {
    static let kind = "usage"
    let name = "AI Usage"
    var hoverTitle: String {
        guard !usage.isEmpty else { return providers.isEmpty ? "AI Usage · No providers selected" : "AI Usage · Loading" }
        // One provider: "Session 79% · Weekly 71%". Several: "Claude 79% · 71%   Codex 12% · 30%".
        if usage.count == 1 { return usage[0].hoverText(named: false) }
        return usage.map { $0.hoverText(named: true) }.joined(separator: "   ")
    }
    let icon = Image(systemName: "gauge.with.dots.needle.67percent")
    let size = WidgetSize.large
    let refreshInterval: TimeInterval = 300

    @Published private(set) var usage: [ProviderUsage] = []
    @Published private(set) var providers: [AgentProvider] = AgentProvider.all

    private var cancellable: AnyCancellable?
    private var consentCancellable: AnyCancellable?
    private var allowed: Set<String> = []
    private var cliCancellable: AnyCancellable?
    private var allowCopilotCLI = false
    private let queue = DispatchQueue(label: "com.james.portside.usage")
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    func attach(_ model: DockModel) {
        allowCopilotCLI = model.usageCopilotCLIEnabled
        cliCancellable = model.$usageCopilotCLIEnabled.dropFirst().sink { [weak self] enabled in
            self?.allowCopilotCLI = enabled
            self?.refresh()
        }
        providers = model.usageProviders.map(AgentProvider.named)
        let allowedIDs = { AgentProvider.all.map(\.id).filter(model.usageAllowed) }
        allowed = Set(allowedIDs())
        // Published fires before the value is stored, so read after this turn.
        consentCancellable = model.$usageClaudeConsent.dropFirst().map { _ in () }
            .merge(with: model.$usageCopilotConsent.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.allowed = Set(allowedIDs())
                self?.refresh()
            }
        cancellable = model.$usageProviders.dropFirst().sink { [weak self] ids in
            self?.providers = ids.map(AgentProvider.named)
            self?.refresh()
        }
    }

    func refresh() {
        let selected = providers
        let allowedIDs = allowed
        let allowCLI = allowCopilotCLI
        queue.async { [weak self] in
            let group = DispatchGroup()
            var results: [String: ProviderUsage] = [:]
            let lock = NSLock()
            for provider in selected {
                group.enter()
                UsageFetcher.fetch(provider, allowed: allowedIDs.contains(provider.id), allowCopilotCLI: allowCLI) { result in
                    lock.withLock { results[provider.id] = result }
                    group.leave()
                }
            }
            group.wait()
            let ordered = selected.compactMap { results[$0.id] }
            DispatchQueue.main.async {
                guard let self else { return }
                if ordered != self.usage {
                    self.usage = ordered
                    for item in ordered {
                        self.logger.info("usage \(item.provider.id, privacy: .public): \(item.windows.map { "\($0.label) \(Int($0.percent))%" }.joined(separator: ", "), privacy: .public)\(item.note.map { " (\($0))" } ?? "", privacy: .public)")
                    }
                }
            }
        }
    }

    /// Opens the first provider's usage page.
    func activate() {
        guard let provider = providers.first, let url = URL(string: provider.usagePage) else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some View {
        UsageView(usage: usage)
    }
}

/// One limit window: "5h" at 27%, resetting at `resetsAt`.
extension AgentProvider {
    /// Settings line under the provider's switch.
    var usageDetail: String {
        switch id {
        case "claude": "5-hour and weekly limits, from your Claude Code sign-in."
        case "copilot": "Monthly quota from GitHub CLI sign-in. The optional Copilot CLI source is off by default."
        default: "5-hour and weekly limits, from Codex's local session logs."
        }
    }

    var usagePage: String {
        switch id {
        case "claude": "https://claude.ai/settings/usage"
        case "copilot": "https://github.com/settings/copilot"
        default: "https://chatgpt.com/codex/settings/usage"
        }
    }
}

struct UsageWindow: Equatable {
    let label: String
    let percent: Double
    let resetsAt: Date?

    /// Data from before the window reset counts as empty, with the next
    /// reset unknown.
    init(label: String, percent: Double, resetsAt: Date?) {
        let expired = resetsAt.map { $0 < Date() } ?? false
        self.label = label
        self.resetsAt = expired ? nil : resetsAt
        self.percent = expired ? 0 : min(max(percent, 0), 100)
    }

    /// "5h", "7d" from a length in minutes.
    static func label(minutes: Int) -> String {
        minutes >= 1440 ? "\(minutes / 1440)d" : "\(max(minutes / 60, 1))h"
    }
}

struct ProviderUsage: Equatable {
    let provider: AgentProvider
    /// Short window first, then weekly.
    let windows: [UsageWindow]
    /// Why there are no meters ("Sign in to Claude Code"), when there are none.
    let note: String?

    var summary: String {
        guard !windows.isEmpty else { return "\(provider.name): \(note ?? "No data")" }
        let parts = windows.map { window in
            let reset = window.resetsAt.map { " (resets \($0.formatted(Self.resetFormat($0))))" } ?? ""
            return "\(window.label) \(Int(window.percent.rounded()))%\(reset)"
        }
        return "\(provider.name): " + parts.joined(separator: ", ")
    }

    /// Hover label: percentages only, no reset times. Single provider spells
    /// out "Session"/"Weekly"; with several, the provider name leads and the
    /// numbers stay bare so the label fits.
    func hoverText(named: Bool) -> String {
        guard !windows.isEmpty else { return "\(provider.name): \(note ?? "No data")" }
        let percent = { (w: UsageWindow) in "\(Int(w.percent.rounded()))%" }
        if named {
            return "\(provider.name) " + windows.map(percent).joined(separator: " · ")
        }
        return windows.map { window in
            let name = ["5h": "Session", "7d": "Weekly", "Prem": "Premium"][window.label] ?? window.label
            return "\(name) \(percent(window))"
        }.joined(separator: " · ")
    }

    /// Time today, weekday and time this week, date beyond that (monthly quotas).
    private static func resetFormat(_ date: Date) -> Date.FormatStyle {
        if Calendar.current.isDateInToday(date) { return .dateTime.hour().minute() }
        return date.timeIntervalSinceNow < 7 * 86400 ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.month(.abbreviated).day()
    }
}

// MARK: - Consent

enum UsageConsent {
    /// The provider is on and allowed to read and send.
    @MainActor
    static func isShown(_ id: String, in model: DockModel) -> Bool {
        model.usageProviders.contains(id) && model.usageAllowed(id)
    }

    /// Turns a provider on or off, asking first where it needs consent.
    /// Turning it off revokes the consent.
    @MainActor
    static func setShown(_ id: String, _ on: Bool, in model: DockModel) {
        if on, !model.usageAllowed(id) {
            guard request(id) else { return }
            model.setUsageConsent(id, granted: true)
        } else if !on {
            model.setUsageConsent(id, granted: false)
        }
        model.setUsageProvider(id, enabled: on)
    }

    /// Asks before Portside reads a provider's sign-in. True when allowed.
    @MainActor
    static func request(_ id: String) -> Bool {
        let alert = NSAlert()
        switch id {
        case "claude":
            alert.messageText = "Show Claude usage?"
            alert.informativeText = """
            To show your Claude limits, Portside reads the sign-in token Claude Code keeps in your login keychain ("Claude Code-credentials") and sends it to api.anthropic.com to ask for your 5-hour and weekly usage. This repeats every 5 minutes.

            The token is not logged, saved, or sent anywhere else. The endpoint is not a documented API and may change. You can turn this off at any time in Settings > Widgets.
            """
        case "copilot":
            alert.messageText = "Show Copilot usage?"
            alert.informativeText = """
            To show your Copilot quota, Portside gets a token from the GitHub CLI (gh auth token) and sends it to api.github.com. This repeats every 5 minutes. You can separately enable the Copilot CLI source in Widgets; it is off by default for managed Macs.

            The token is not logged, saved, or sent anywhere else. These interfaces may change. You can turn this off at any time in Settings > Widgets.
            """
        default:
            return true
        }
        // The dock panel never activates the app, so bring the alert forward.
        NSApp.activate()
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Fetching

extension UsageFetcher {
    /// `portside --print-usage [provider]`: one summary line per provider.
    static func printAll(only id: String? = nil) -> Int32 {
        let group = DispatchGroup()
        for provider in AgentProvider.all where id == nil || provider.id == id {
            group.enter()
            fetch(provider, allowed: true) { usage in
                print(usage.summary)
                group.leave()
            }
            group.wait()
        }
        return 0
    }
}

enum UsageFetcher {
    private static let logger = Logger(subsystem: "com.james.portside", category: "Widgets")
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func fetch(_ provider: AgentProvider, allowed: Bool, allowCopilotCLI: Bool = false, completion: @escaping (ProviderUsage) -> Void) {
        guard allowed else {
            return completion(ProviderUsage(provider: provider, windows: [], note: "Allow in Settings > Widgets"))
        }
        switch provider.id {
        case "claude": claude(provider, completion: completion)
        case "codex": completion(codex(provider))
        case "copilot": copilot(provider, allowCLI: allowCopilotCLI, completion: completion)
        default: completion(ProviderUsage(provider: provider, windows: [], note: "Not supported"))
        }
    }

    // MARK: Claude

    private static func claude(_ provider: AgentProvider, completion: @escaping (ProviderUsage) -> Void) {
        func fail(_ note: String) { completion(ProviderUsage(provider: provider, windows: [], note: note)) }
        guard let credentials = claudeCredentials() else { return fail("Sign in to Claude Code") }
        if let expiry = credentials.expiresAt, expiry < Date() {
            return fail("Open Claude Code to refresh its sign-in")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("usage claude: HTTP \(status)")
                return fail(status == 401 ? "Open Claude Code to refresh its sign-in" : "Usage unavailable")
            }
            let windows = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label -> UsageWindow? in
                guard let window = json[key] as? [String: Any],
                      let percent = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
                return UsageWindow(label: label, percent: percent,
                                   resetsAt: (window["resets_at"] as? String).flatMap(parseDate))
            }
            completion(ProviderUsage(provider: provider, windows: windows, note: windows.isEmpty ? "No limits reported" : nil))
        }.resume()
    }

    /// The OAuth token Claude Code keeps in the login keychain. Never
    /// logged.
    private static func claudeCredentials() -> (token: String, expiresAt: Date?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (token, expiresAt)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Codex

    /// The newest `rate_limits` with numbers in the last two weeks of
    /// session logs (sessions/YYYY/MM/DD/*.jsonl), newest file first.
    private static func codex(_ provider: AgentProvider) -> ProviderUsage {
        let root = home.appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return ProviderUsage(provider: provider, windows: [], note: "Codex not found")
        }
        var files: [(url: URL, modified: Date)] = []
        let calendar = Calendar.current
        for daysAgo in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in items where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(20) {
            if let windows = codexWindows(in: file.url) {
                return ProviderUsage(provider: provider, windows: windows, note: nil)
            }
        }
        return ProviderUsage(provider: provider, windows: [], note: "No recent Codex usage")
    }

    /// Reads the last 512 KB of a log and parses its newest rate limits.
    private static func codexWindows(in url: URL) -> [UsageWindow]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 512_000 ? end - 512_000 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed()
        where line.contains("\"rate_limits\"") && line.contains("\"used_percent\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let limits = findRateLimits(json) else { continue }
            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let window = limits[key] as? [String: Any],
                      let percent = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? (key == "primary" ? 300 : 10080)
                let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return UsageWindow(label: UsageWindow.label(minutes: minutes), percent: percent, resetsAt: resets)
            }
            if !windows.isEmpty { return windows }
        }
        return nil
    }

    private static func findRateLimits(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let limits = dictionary["rate_limits"] as? [String: Any] { return limits }
            for child in dictionary.values {
                if let found = findRateLimits(child) { return found }
            }
        }
        return nil
    }

    // MARK: Copilot

    private struct CopilotQuota {
        let key: String
        let unlimited: Bool
        let entitlement: Double
        let percentRemaining: Double?
        let resetsAt: Date?
    }

    private static func copilot(_ provider: AgentProvider, allowCLI: Bool, completion: @escaping (ProviderUsage) -> Void) {
        func finish(_ quotas: [CopilotQuota]) {
            let windows = copilotWindows(quotas)
            let note = windows.isEmpty ? (quotas.contains(where: \.unlimited) ? "Unlimited" : "No limits reported") : nil
            completion(ProviderUsage(provider: provider, windows: windows, note: note))
        }
        let cli = copilotCLI()
        if allowCLI, let path = cli.usable, shouldTryCopilotCLI {
            if let quotas = copilotQuotasFromCLI(path) { return finish(quotas) }
            backOffCopilotCLI()
        }
        func fail(_ note: String) { completion(ProviderUsage(provider: provider, windows: [], note: note)) }
        guard let token = githubCLIToken() else {
            return fail(allowCLI && cli.isBlocked ? "macOS blocked the Copilot CLI" : "Sign in with gh auth login, or enable Copilot CLI in Widgets")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Portside", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let snapshots = json["quota_snapshots"] as? [String: [String: Any]] else {
                logger.error("usage copilot: HTTP \(status)")
                if let error = error as? URLError,
                   [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                    .serverCertificateHasBadDate, .serverCertificateNotYetValid].contains(error.code) {
                    return fail("TLS trust failed. Ask IT to check the proxy certificate for api.github.com.")
                }
                return fail(status == 401 || status == 403 ? "Sign in to Copilot CLI or GitHub CLI"
                            : status == 404 ? "No Copilot plan" : "Usage unavailable")
            }
            let reset = (json["quota_reset_date"] as? String).flatMap(parseDay)
            finish(snapshots.map { key, value in
                CopilotQuota(key: key, unlimited: value["unlimited"] as? Bool ?? false,
                             entitlement: (value["entitlement"] as? NSNumber)?.doubleValue ?? 0,
                             percentRemaining: (value["percent_remaining"] as? NSNumber)?.doubleValue,
                             resetsAt: reset)
            })
        }.resume()
    }

    /// Premium requests first, then Chat and Code. Free plans have no premium
    /// quota and paid plans usually have unlimited Chat and Code, so both
    /// kinds are left out.
    private static func copilotWindows(_ quotas: [CopilotQuota]) -> [UsageWindow] {
        [("premium_interactions", "Prem"), ("chat", "Chat"), ("completions", "Code")].compactMap { key, label in
            guard let quota = quotas.first(where: { $0.key == key }), !quota.unlimited, quota.entitlement > 0,
                  let remaining = quota.percentRemaining else { return nil }
            // The CLI can report a reset date of "now". `UsageWindow` would
            // read that as expired and show 0%, so only keep future dates.
            let resetsAt = quota.resetsAt.flatMap { $0 > Date() ? $0 : nil }
            return UsageWindow(label: label, percent: 100 - remaining, resetsAt: resetsAt)
        }
    }

    /// After a failed run the CLI is left alone for this long, and the GitHub
    /// CLI is used. macOS shows its "Not Opened" alert whenever a blocked
    /// program starts, which `isQuarantined` cannot rule out for a program the
    /// CLI starts itself; retrying every refresh would repeat the alert.
    private static let copilotCLIBackoff: TimeInterval = 6 * 3600
    private static let copilotCLILock = NSLock()
    private static var copilotCLIRetryAt = Date.distantPast

    private static var shouldTryCopilotCLI: Bool {
        copilotCLILock.withLock { Date() >= copilotCLIRetryAt }
    }

    private static func backOffCopilotCLI() {
        logger.notice("usage copilot: CLI failed, not running it again for a while")
        copilotCLILock.withLock { copilotCLIRetryAt = Date().addingTimeInterval(copilotCLIBackoff) }
    }

    /// Would Gatekeeper refuse this file? Downloaded programs keep the
    /// quarantine attribute (a Homebrew cask does) until someone approves them.
    /// A terminal with the Developer Tools permission runs them regardless, so
    /// the CLI can seem fine while Portside gets the "Not Opened" alert.
    private static func isQuarantined(_ url: URL) -> Bool {
        var value = [CChar](repeating: 0, count: 256)
        let length = getxattr(url.resolvingSymlinksInPath().path, "com.apple.quarantine", &value, value.count - 1, 0, 0)
        guard length > 0 else { return false }
        // "0083;65a1b2c3;agent;uuid". Flag 0x40 means the user approved it.
        let flags = String(cString: value).split(separator: ";").first.flatMap { UInt32($0, radix: 16) } ?? 0
        return flags & 0x40 == 0
    }

    /// The Copilot CLI, from its usual install places. A GUI app has no shell
    /// PATH to search. Quarantined copies are skipped: running one is what
    /// makes macOS offer to move it to the Trash.
    private static func copilotCLI() -> (usable: URL?, isBlocked: Bool) {
        let fm = FileManager.default
        var candidates = [
            home.appendingPathComponent(".local/bin/copilot"),
            URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            URL(fileURLWithPath: "/usr/local/bin/copilot"),
            home.appendingPathComponent(".npm-global/bin/copilot"),
            home.appendingPathComponent(".local/share/gh/copilot/copilot"),
            home.appendingPathComponent("Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot"),
        ]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        for version in (try? fm.contentsOfDirectory(atPath: nvm.path))?.sorted().reversed() ?? [] {
            candidates.append(nvm.appendingPathComponent("\(version)/bin/copilot"))
        }
        let installed = candidates.filter { fm.isExecutableFile(atPath: $0.path) }
        let usable = installed.first { !isQuarantined($0) }
        if usable == nil, !installed.isEmpty { logger.notice("usage copilot: CLI is quarantined, not running it") }
        return (usable, !installed.isEmpty && usable == nil)
    }

    /// Runs `copilot --headless --stdio` for one `account.getQuota` call, using
    /// the CLI's own sign-in. Portside never sees a token. Nil when the CLI
    /// fails, is signed out, or takes over 10 seconds.
    private static func copilotQuotasFromCLI(_ cli: URL) -> [CopilotQuota]? {
        // Its logs go to a folder of ours, so ~/.copilot/logs does not gain a
        // file every 5 minutes.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("portside-copilot-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = cli
        process.arguments = ["--headless", "--no-auto-update", "--log-level", "none", "--log-dir", scratch.path, "--stdio"]
        process.currentDirectoryURL = scratch
        // npm installs start with `env node`, and the CLI falls back to `gh`.
        var environment = ProcessInfo.processInfo.environment
        let path = [cli.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
        environment["PATH"] = path.joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A CLI that exits early must not end Portside with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        var buffer = Data()
        var result: [String: Any]?
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.withLock {
                buffer.append(chunk)
                if let reply = rpcReply(from: &buffer) { result = reply }
            }
            if chunk.isEmpty || lock.withLock({ result != nil }) {
                handle.readabilityHandler = nil
                finished.signal()
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        do { try process.run() } catch {
            logger.error("usage copilot: CLI did not start")
            return nil
        }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"account.getQuota","params":{}}"#.utf8)
        do {
            try input.fileHandleForWriting.write(contentsOf: Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
        } catch { return nil }
        guard finished.wait(timeout: .now() + 10) == .success,
              let snapshots = lock.withLock({ result })?["quotaSnapshots"] as? [String: [String: Any]] else {
            logger.error("usage copilot: no quota from CLI")
            return nil
        }
        return snapshots.map { key, value in
            CopilotQuota(key: key, unlimited: value["isUnlimitedEntitlement"] as? Bool ?? false,
                         entitlement: (value["entitlementRequests"] as? NSNumber)?.doubleValue ?? 0,
                         percentRemaining: (value["remainingPercentage"] as? NSNumber)?.doubleValue,
                         resetsAt: (value["resetDate"] as? String).flatMap(parseDate))
        }
    }

    /// Consumes complete `Content-Length` frames, returning the result of
    /// the reply to request 1 when one has arrived. An error reply returns
    /// an empty result.
    private static func rpcReply(from buffer: inout Data) -> [String: Any]? {
        let separator = Data("\r\n\r\n".utf8)
        while let gap = buffer.range(of: separator),
              let header = String(data: buffer[buffer.startIndex..<gap.lowerBound], encoding: .utf8),
              let length = header.components(separatedBy: "\r\n")
                  .first(where: { $0.lowercased().hasPrefix("content-length:") })
                  .flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }),
              buffer.distance(from: gap.upperBound, to: buffer.endIndex) >= length {
            let end = buffer.index(gap.upperBound, offsetBy: length)
            let frame = buffer[gap.upperBound..<end]
            defer { buffer = Data(buffer[end...]) }
            guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  (json["id"] as? NSNumber)?.intValue == 1 else { continue }
            return json["result"] as? [String: Any] ?? [:]
        }
        return nil
    }

    /// The GitHub CLI's token. Never logged.
    private static func githubCLIToken() -> String? {
        let fm = FileManager.default
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: fm.isExecutableFile) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// "2026-12-01".
    private static func parseDay(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }
}

// MARK: - Views

struct UsageView: View {
    let usage: [ProviderUsage]
    @Environment(\.dockTileSize) private var tile
    @Environment(\.widgetSize) private var chosen

    var body: some View {
        let size = WidgetSize.resolved(chosen, natural: .large)
        let inset = WidgetLayout.inset(tile)
        let side = WidgetLayout.itemSide(tile)
        let shown = usage
        WidgetTile(size: size) {
            if shown.isEmpty {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: WidgetTypography.fontSize(12, tile: tile)))
                    .foregroundStyle(.tertiary)
            } else if size == .small {
                // One ring per provider, short window only.
                ConcentricUsage(usage: shown, side: side)
            } else if size == .medium && shown.count > 1 || shown.count > 2 {
                // No text: gauges spaced evenly. Three only fit in Wide when smaller.
                let gauge = size == .medium && shown.count > 2 ? side * 0.72 : side
                EvenRow {
                    ForEach(shown, id: \.provider.id) { UsageGauge(usage: $0, side: gauge) }
                }
            } else if shown.count == 1 {
                // One provider (Wide or Extra Wide): gauge, then labeled
                // percentages, like System Stats.
                HStack(spacing: inset) {
                    UsageGauge(usage: shown[0], side: side)
                    UsageText(usage: shown[0], labeled: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, inset)
            } else {
                // Two providers: each gauge with its percentages (outer ring
                // first), the pairs spaced evenly. Labels are in the hover.
                EvenRow {
                    ForEach(shown, id: \.provider.id) { item in
                        HStack(spacing: inset) {
                            UsageGauge(usage: item, side: side)
                            UsageText(usage: item, labeled: false)
                        }
                    }
                }
            }
        }
    }
}

/// Ring color: the provider's, red from 90%.
private func ringColor(_ provider: AgentProvider, _ percent: Double) -> Color {
    percent >= 90 ? .red : provider.color
}

/// Outer ring: short window. Inner ring: weekly. Provider icon in the
/// middle; a dash when there is no data (hover says why).
private struct UsageGauge: View {
    let usage: ProviderUsage
    let side: CGFloat
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        let line = max(2, side * 0.1)
        ZStack {
            ForEach(Array(usage.windows.prefix(2).enumerated()), id: \.offset) { index, window in
                let inset = CGFloat(index) * line * 1.5
                Ring(value: window.percent / 100, color: ringColor(usage.provider, window.percent),
                     lineWidth: index == 0 ? line : line * 0.7)
                    .padding(inset)
            }
            if usage.windows.isEmpty {
                Ring(value: 0, color: usage.provider.color, lineWidth: line)
            }
            if tile >= 28 {
                ProviderLogo(provider: usage.provider, side: side * 0.42)
                    .opacity(usage.windows.isEmpty ? 0.4 : 1)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Small size: one ring per provider (short window), outer first.
private struct ConcentricUsage: View {
    let usage: [ProviderUsage]
    let side: CGFloat

    var body: some View {
        let line = max(2, side * 0.1)
        ZStack {
            ForEach(Array(usage.enumerated()), id: \.offset) { index, item in
                let percent = item.windows.first?.percent ?? 0
                Ring(value: percent / 100, color: ringColor(item.provider, percent), lineWidth: line)
                    .padding(CGFloat(index) * line * 1.6)
            }
            if usage.count == 1, let percent = usage[0].windows.first?.percent {
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: side * 0.3, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: side, height: side)
    }
}

private struct Ring: View {
    let value: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Extra Wide: percentages beside a gauge, short window first. `labeled`
/// adds "5h" / "7d" when there is room (one provider).
private struct UsageText: View {
    let usage: ProviderUsage
    let labeled: Bool
    @Environment(\.dockTileSize) private var tile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if usage.windows.isEmpty {
                Text(usage.provider.name)
                    .font(.system(size: WidgetTypography.fontSize(6, tile: tile), weight: .semibold))
                Text(usage.note ?? "No data")
                    .font(.system(size: WidgetTypography.fontSize(5, tile: tile)))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(usage.windows.prefix(2).enumerated()), id: \.offset) { index, window in
                    HStack(spacing: tile * 0.05) {
                        if labeled {
                            Text(window.label)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Int(window.percent.rounded()))%")
                            .foregroundStyle(window.percent >= 90 ? AnyShapeStyle(.red)
                                             : index == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                    }
                    .font(.system(size: WidgetTypography.fontSize(index == 0 ? 6.5 : 5.5, tile: tile),
                                  weight: index == 0 ? .semibold : .regular))
                    .fixedSize()
                }
            }
        }
        .lineLimit(1)
    }
}
