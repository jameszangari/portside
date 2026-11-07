import Foundation
import os.log

/// Recent and frequent Command Center picks, for ranking. Stores only result
/// IDs, a use count and the last use time (never the query or a link's URL)
/// in `command-center-history.json` next to dock.json, mode 0600. Cleared
/// from Settings > General.
@MainActor
final class CommandCenterHistory: ObservableObject {
    static let shared = CommandCenterHistory(url: CommandCenterHistory.defaultURL)

    struct Entry: Equatable {
        var count: Int
        var lastUsed: Date
    }

    /// Entries kept; the lowest scores are dropped past this.
    nonisolated static let limit = 200
    /// A use counts half as much after this many days.
    nonisolated static let halfLifeDays: Double = 14
    /// Counts above this stop adding, so one habit cannot bury everything.
    nonisolated static let countCap = 100

    @Published private(set) var entries: [CommandCenterResultID: Entry] = [:]

    private let url: URL?
    private let logger = Logger(subsystem: "com.james.portside", category: "CommandCenter")

    /// `url` nil keeps history in memory only (tests).
    init(url: URL?) {
        self.url = url
        entries = url.flatMap(Self.read) ?? [:]
    }

    var isEmpty: Bool { entries.isEmpty }

    func record(_ id: CommandCenterResultID, at date: Date = Date()) {
        var entry = entries[id] ?? Entry(count: 0, lastUsed: date)
        entry.count = min(entry.count + 1, Self.countCap)
        entry.lastUsed = max(entry.lastUsed, date)
        entries[id] = entry
        if entries.count > Self.limit {
            // Lowest score first, then oldest, then ID, so pruning is repeatable.
            let ordered = entries.sorted { lhs, rhs in
                let left = Self.score(lhs.value, now: date), right = Self.score(rhs.value, now: date)
                if left != right { return left < right }
                if lhs.value.lastUsed != rhs.value.lastUsed { return lhs.value.lastUsed < rhs.value.lastUsed }
                return lhs.key < rhs.key
            }
            for (key, _) in ordered.prefix(entries.count - Self.limit) { entries[key] = nil }
        }
        save()
    }

    /// Deletes every entry and the file.
    func clear() {
        entries = [:]
        guard let url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            logger.info("command center history cleared")
        } catch {
            logger.error("command center history not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func score(_ id: CommandCenterResultID, now: Date) -> Double {
        entries[id].map { Self.score($0, now: now) } ?? 0
    }

    /// Frecency: the use count, halved every `halfLifeDays` since the last use.
    nonisolated static func score(_ entry: Entry, now: Date) -> Double {
        let days = max(now.timeIntervalSince(entry.lastUsed), 0) / 86_400
        return Double(min(entry.count, countCap)) * pow(0.5, days / halfLifeDays)
    }

    // MARK: File

    private struct File: Codable {
        struct Item: Codable {
            let id: String
            let count: Int
            let lastUsed: Double
        }
        var version = 1
        var entries: [Item]
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.james.portside").appendingPathComponent("command-center-history.json")
    }

    /// Unknown IDs and malformed items are skipped; an unreadable file reads as empty.
    private static func read(_ url: URL) -> [CommandCenterResultID: Entry]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var result: [CommandCenterResultID: Entry] = [:]
        for item in file.entries.prefix(limit) {
            guard let id = CommandCenterResultID(rawValue: item.id), item.count > 0, item.lastUsed.isFinite else { continue }
            result[id] = Entry(count: min(item.count, countCap), lastUsed: Date(timeIntervalSince1970: item.lastUsed))
        }
        return result
    }

    private func save() {
        guard let url else { return }
        let items = entries.sorted { $0.key < $1.key }.map {
            File.Item(id: $0.key.rawValue, count: $0.value.count, lastUsed: $0.value.lastUsed.timeIntervalSince1970.rounded())
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(entries: items))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("command center history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
