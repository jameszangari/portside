import AppKit
import Combine
import SwiftUI
import os.log

/// Plan usage meters for coding agents: the share of the short (5 hour)
/// and weekly limits used, per provider picked in Settings > Widgets.
///
/// Sources (read on a 5 minute refresh, off the main thread):
/// - Claude: Claude Code's sign-in from the login keychain, read with
///   /usr/bin/security (the tool Claude Code stores it with, so no
///   prompt), sent to Anthropic's OAuth usage endpoint. Not a documented
///   API; any failure shows as a note instead of meters. Nothing is read
///   or sent until the user agrees (`DockModel.usageClaudeConsent`).
/// - Codex: the `rate_limits` Codex writes into its session logs under
///   ~/.codex/sessions. Local only; as fresh as the last Codex turn.
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
    private var claudeConsent = false
    private let queue = DispatchQueue(label: "com.james.portside.usage")
    private let logger = Logger(subsystem: "com.james.portside", category: "Widgets")

    func attach(_ model: DockModel) {
        providers = model.usageProviders.map(AgentProvider.named)
        claudeConsent = model.usageClaudeConsent
        consentCancellable = model.$usageClaudeConsent.dropFirst().sink { [weak self] granted in
            self?.claudeConsent = granted
            self?.refresh()
        }
        cancellable = model.$usageProviders.dropFirst().sink { [weak self] ids in
            self?.providers = ids.map(AgentProvider.named)
            self?.refresh()
        }
    }

    func refresh() {
        let selected = providers
        let claudeAllowed = claudeConsent
        queue.async { [weak self] in
            let group = DispatchGroup()
            var results: [String: ProviderUsage] = [:]
            let lock = NSLock()
            for provider in selected {
                group.enter()
                UsageFetcher.fetch(provider, claudeAllowed: claudeAllowed) { result in
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
        guard let provider = providers.first else { return }
        let page = provider.id == "claude"
            ? "https://claude.ai/settings/usage"
            : "https://chatgpt.com/codex/settings/usage"
        if let url = URL(string: page) { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        UsageView(usage: usage)
    }
}

/// One limit window: "5h" at 27%, resetting at `resetsAt`.
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
            let name = window.label == "5h" ? "Session" : window.label == "7d" ? "Weekly" : window.label
            return "\(name) \(percent(window))"
        }.joined(separator: " · ")
    }

    /// Time today, weekday and time later.
    private static func resetFormat(_ date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
    }
}

// MARK: - Consent

enum UsageConsent {
    /// Asks before Portside reads Claude Code's token. True when allowed.
    @MainActor
    static func requestClaude() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Show Claude usage?"
        alert.informativeText = """
        To show your Claude limits, Portside reads the sign-in token Claude Code keeps in your login keychain ("Claude Code-credentials") and sends it to api.anthropic.com to ask for your 5-hour and weekly usage. This repeats every 5 minutes.

        The token is not logged, saved, or sent anywhere else. The endpoint is not a documented API and may change. You can turn this off at any time in Settings > Widgets.
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Fetching

extension UsageFetcher {
    /// `portside --print-usage`: one summary line per provider.
    static func printAll() -> Int32 {
        let group = DispatchGroup()
        for provider in AgentProvider.all {
            group.enter()
            fetch(provider, claudeAllowed: true) { usage in
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

    static func fetch(_ provider: AgentProvider, claudeAllowed: Bool, completion: @escaping (ProviderUsage) -> Void) {
        switch provider.id {
        case "claude":
            guard claudeAllowed else {
                return completion(ProviderUsage(provider: provider, windows: [], note: "Allow in Settings > Widgets"))
            }
            claude(provider, completion: completion)
        case "codex": completion(codex(provider))
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
        let shown = Array(usage.prefix(2))
        WidgetTile(size: size) {
            if shown.isEmpty {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: WidgetTypography.fontSize(12, tile: tile)))
                    .foregroundStyle(.tertiary)
            } else if size == .small {
                // One ring per provider, short window only.
                ConcentricUsage(usage: shown, side: side)
            } else if size == .medium && shown.count > 1 {
                // No text: gauges spaced evenly.
                EvenRow {
                    ForEach(shown, id: \.provider.id) { UsageGauge(usage: $0, side: side) }
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
