import Foundation
import os.log

/// A user-made block of text Command Center copies (P2-CMD-05). Plain text
/// only: it is put on the pasteboard as typed and never run, expanded,
/// templated or opened.
struct Snippet: Codable, Equatable, Identifiable, Sendable {
    static let nameLimit = 100
    static let textLimit = 10_000
    static let listLimit = 200

    var id: UUID
    var name: String
    var text: String

    init(id: UUID = UUID(), name: String = "", text: String = "") {
        self.id = id
        self.name = String(name.prefix(Self.nameLimit))
        self.text = String(text.prefix(Self.textLimit))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "",
            text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        )
    }

    /// The row title: the name, else the first line of the text.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let line = firstLine
        return line.isEmpty ? "Untitled Snippet" : line
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var firstLine: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// One line for the row: the text with line breaks folded, cut at `limit`.
    func preview(limit: Int = 80) -> String {
        let folded = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
        return folded.count <= limit ? folded : String(folded.prefix(limit - 1)) + "…"
    }
}

/// Snippets on this Mac, in `command-center-snippets.json` next to
/// dock.json, mode 0600. Kept out of dock.json on purpose: snippet text can
/// be private, and dock.json is exported, backed up and copied for support.
/// Never logged. Unreadable or malformed entries are skipped; an unreadable
/// file reads as empty and is left untouched until the next save.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore(url: SnippetStore.defaultURL)

    @Published private(set) var snippets: [Snippet] = []

    private let url: URL?
    private let logger = Logger(subsystem: "com.james.portside", category: "CommandCenter")

    /// `url` nil keeps snippets in memory only (tests).
    init(url: URL?) {
        self.url = url
        snippets = url.flatMap(Self.read) ?? []
    }

    var isFull: Bool { snippets.count >= Snippet.listLimit }

    @discardableResult
    func add(name: String = "", text: String = "") -> UUID? {
        guard !isFull else { return nil }
        let snippet = Snippet(name: name, text: text)
        snippets.append(snippet)
        save()
        return snippet.id
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let bounded = Snippet(id: snippet.id, name: snippet.name, text: snippet.text)
        guard snippets[index] != bounded else { return }
        snippets[index] = bounded
        save()
    }

    func remove(id: UUID) {
        let before = snippets.count
        snippets.removeAll { $0.id == id }
        if snippets.count != before { save() }
    }

    func snippet(id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    // MARK: File

    private struct File: Codable {
        var version = 1
        var snippets: [Snippet]
    }

    /// Lenient element: one bad entry never drops the list.
    private struct Element: Decodable {
        let value: Snippet?
        init(from decoder: Decoder) throws { value = try? Snippet(from: decoder) }
    }

    private struct LenientFile: Decodable {
        var snippets: [Element]
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.james.portside").appendingPathComponent("command-center-snippets.json")
    }

    private static func read(_ url: URL) -> [Snippet]? {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(LenientFile.self, from: data) else { return nil }
        var seen = Set<UUID>()
        return file.snippets.compactMap(\.value)
            .filter { seen.insert($0.id).inserted }
            .prefix(Snippet.listLimit)
            .map { Snippet(id: $0.id, name: $0.name, text: $0.text) }
    }

    private func save() {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(snippets: snippets))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Created 0600 from the start, then swapped in: the text is never
            // readable by others, not even briefly.
            let temp = url.deletingLastPathComponent().appendingPathComponent(".snippets-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        } catch {
            // The error text never carries snippet text.
            logger.error("snippets not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
