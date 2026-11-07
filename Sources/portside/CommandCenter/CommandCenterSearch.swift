import Foundation

/// Stable identifier of one Command Center result, unique across providers:
/// `command:<CommandID>`, `app:<bundle id, lowercased>` (`app:<path>` for an
/// app without one), `settings:<pane>`, `quicklink:<uuid, lowercased>`,
/// `server:<port>-<pid>-<start>` (see `LocalServer.key`).
/// Selection, the Action Panel, screens and history all key on it. Server
/// IDs live for one session and are never written to history.
struct CommandCenterResultID: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: String

    private init(unchecked rawValue: String) { self.rawValue = rawValue }

    /// Read back from the history file: only the four known prefixes.
    init?(rawValue: String) {
        let prefixes = ["command:", "app:", "settings:", "quicklink:"]
        guard let prefix = prefixes.first(where: rawValue.hasPrefix), rawValue.count > prefix.count else { return nil }
        self.rawValue = rawValue
    }

    static func command(_ id: CommandID) -> Self { Self(unchecked: "command:\(id.rawValue)") }

    static func application(bundleIdentifier: String?, path: String) -> Self {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return Self(unchecked: "app:\(bundleIdentifier.lowercased())") }
        return Self(unchecked: "app:\(path)")
    }

    static func settings(_ pane: String) -> Self { Self(unchecked: "settings:\(pane)") }

    static func quicklink(_ id: UUID) -> Self { Self(unchecked: "quicklink:\(id.uuidString.lowercased())") }

    static func server(_ key: String) -> Self { Self(unchecked: "server:\(key)") }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue }
}

/// What Return runs: one registry command and its input. Every result kind
/// goes through `CommandRegistry.execute`; there is no second executor.
struct CommandInvocation: Equatable, Sendable {
    let command: CommandID
    var input: CommandInput = .none
    /// Success keeps the panel open (a refresh that updates its rows).
    var staysOpen = false
}

/// A query plus the generation it belongs to. Results from an older
/// generation are dropped by the state machine.
struct CommandCenterSearchRequest: Equatable, Sendable {
    let generation: Int
    let query: String
    /// A catalog refresh re-ran the same query: keep the selected row.
    var preservesSelection = false
}

// MARK: - Ranking

/// Deterministic ranking. Match tier first, then frecency, then title, then
/// result ID, so equal input always gives the same order.
enum CommandCenterRanker {
    /// Lower is better.
    enum Tier: Int, Comparable {
        /// The whole title equals the query.
        case exact
        /// The title starts with the query.
        case titlePrefix
        /// Every query word starts a word of the title.
        case titleWords
        /// Every query word starts a word of the title or a keyword.
        case keywords
        /// The query starts the title's initials ("vsc" for Visual Studio Code).
        case initials
        /// The query's letters appear in order in the title.
        case fuzzy

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Match: Equatable {
        let tier: Tier
        /// Fuzzy only: how spread out the letters are. Lower is tighter.
        var spread = 0
    }

    /// Fuzzy and initials matching need at least this many letters, so one
    /// or two keystrokes do not match nearly everything.
    static let fuzzyMinimum = 3

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func terms(_ query: String) -> [String] {
        words(normalize(query))
    }

    static func match(_ item: CommandCenterItem, terms: [String]) -> Match? {
        guard !terms.isEmpty else { return Match(tier: .exact) }
        let title = normalize(item.title)
        let titleWords = words(title)
        let joined = terms.joined(separator: " ")
        if titleWords.joined(separator: " ") == joined { return Match(tier: .exact) }
        if titleWords.joined(separator: " ").hasPrefix(joined) { return Match(tier: .titlePrefix) }
        if terms.allSatisfy({ term in titleWords.contains { $0.hasPrefix(term) } }) { return Match(tier: .titleWords) }
        let keywordWords = item.keywords.flatMap { words(normalize($0)) }
        if terms.allSatisfy({ term in titleWords.contains { $0.hasPrefix(term) } || keywordWords.contains { $0.hasPrefix(term) } }) {
            return Match(tier: .keywords)
        }
        if item.matchesServerQueries, LocalServerText.isServerQuery(terms) { return Match(tier: .keywords) }
        // Initials and fuzzy take one word only: "vsc", not "v sc".
        guard terms.count == 1, let term = terms.first, term.count >= fuzzyMinimum else { return nil }
        if String(titleWords.compactMap(\.first)).hasPrefix(term) {
            return Match(tier: .initials)
        }
        if let spread = subsequenceSpread(of: term, in: titleWords.joined()) {
            return Match(tier: .fuzzy, spread: spread)
        }
        return nil
    }

    /// Characters between the first and last matched letter, greedy from
    /// the left. Nil when `needle` is not a subsequence.
    static func subsequenceSpread(of needle: String, in haystack: String) -> Int? {
        var remaining = needle[...]
        var first: Int?
        var last = 0
        for (index, character) in haystack.enumerated() {
            guard let next = remaining.first else { break }
            if character == next {
                if first == nil { first = index }
                last = index
                remaining = remaining.dropFirst()
            }
        }
        guard remaining.isEmpty, let first else { return nil }
        return last - first + 1 - needle.count
    }

    /// The ranked IDs for `query`, or nil when `isCancelled` turned true
    /// part way (checked every 64 items). An empty query is the default list.
    static func rank(
        _ items: [CommandCenterItem],
        query: String,
        isCancelled: () -> Bool = { false }
    ) -> [CommandCenterResultID]? {
        let terms = terms(query)
        if terms.isEmpty { return defaultOrder(items).map(\.id) }
        var scored: [(match: Match, item: CommandCenterItem)] = []
        for (index, item) in items.enumerated() {
            if index % 64 == 0, isCancelled() { return nil }
            if let match = match(item, terms: terms) { scored.append((match, item)) }
        }
        if isCancelled() { return nil }
        scored.sort { lhs, rhs in
            if lhs.match.tier != rhs.match.tier { return lhs.match.tier < rhs.match.tier }
            if lhs.match.spread != rhs.match.spread { return lhs.match.spread < rhs.match.spread }
            return precedes(lhs.item, rhs.item)
        }
        return scored.map(\.item.id)
    }

    /// Empty query: used results by frecency, then every result that is not
    /// an app (commands, Settings, quicklinks) by title. Apps appear once
    /// typed or used, so the first screen is not a list of every app.
    static func defaultOrder(_ items: [CommandCenterItem]) -> [CommandCenterItem] {
        items.filter { $0.usage > 0 || $0.kind != .application }.sorted { lhs, rhs in
            let leftUsed = lhs.usage > 0, rightUsed = rhs.usage > 0
            if leftUsed != rightUsed { return leftUsed }
            return precedes(lhs, rhs)
        }
    }

    /// Frecency, then case-insensitive title, then ID: never hash or input order.
    static func precedes(_ lhs: CommandCenterItem, _ rhs: CommandCenterItem) -> Bool {
        if lhs.usage != rhs.usage { return lhs.usage > rhs.usage }
        let left = lhs.title.lowercased(), right = rhs.title.lowercased()
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}

// MARK: - Searcher

/// Runs one ranking at a time off the main thread. Starting a search
/// cancels the one in flight; a canceled search never delivers, and the
/// state machine also drops any result whose generation is not the latest.
@MainActor
final class CommandCenterSearcher {
    private var task: Task<Void, Never>?

    func start(
        _ request: CommandCenterSearchRequest,
        items: [CommandCenterItem],
        deliver: @escaping @MainActor (CommandCenterSearchRequest, [CommandCenterResultID]) -> Void
    ) {
        task?.cancel()
        task = Task.detached(priority: .userInitiated) {
            guard let ranked = CommandCenterRanker.rank(items, query: request.query, isCancelled: { Task.isCancelled }) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                deliver(request, ranked)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
