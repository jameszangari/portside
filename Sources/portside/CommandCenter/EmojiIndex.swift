import Foundation

/// One emoji and its Unicode name.
struct EmojiEntry: Equatable, Sendable {
    let character: String
    /// Lowercase Unicode name, such as "grinning face".
    let name: String

    var scalarKey: String {
        character.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
    }

    /// "Grinning face".
    var title: String { name.prefix(1).uppercased() + name.dropFirst() }
}

/// Searchable emoji built from the Unicode data in the standard library
/// (`Unicode.Scalar.Properties`): single code point emoji that default to
/// emoji presentation, named by their Unicode names. No private API, no
/// network, no file read. Flags, skin tones and joined sequences have no
/// single name there, so they are not offered.
struct EmojiIndex: Sendable {
    let entries: [EmojiEntry]

    static let shared = EmojiIndex(entries: build())

    init(entries: [EmojiEntry]) {
        self.entries = entries
    }

    /// A query is `emoji smile` or `:smile`. nil when it is neither, so an
    /// ordinary query never costs a search. The text may be empty.
    static func searchText(in query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(":") { return String(trimmed.dropFirst()) }
        let lowered = trimmed.lowercased()
        if lowered == "emoji" { return "" }
        if lowered.hasPrefix("emoji ") { return String(trimmed.dropFirst(6)) }
        return nil
    }

    static let resultLimit = 8

    /// Entries whose name has a word starting with every term, best first:
    /// the whole name, then a name that starts with the text, then word
    /// order, then code point. Empty text finds nothing.
    func search(_ text: String, limit: Int = EmojiIndex.resultLimit) -> [EmojiEntry] {
        let terms = CommandCenterRanker.terms(text)
        guard !terms.isEmpty else { return [] }
        let joined = terms.joined(separator: " ")
        var scored: [(rank: Int, position: Int, entry: EmojiEntry)] = []
        for (position, entry) in entries.enumerated() {
            let words = CommandCenterRanker.words(entry.name)
            guard terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) else { continue }
            let name = words.joined(separator: " ")
            let rank = name == joined ? 0 : name.hasPrefix(joined) ? 1 : 2
            scored.append((rank, position, entry))
        }
        scored.sort { ($0.rank, $0.position) < ($1.rank, $1.position) }
        return scored.prefix(limit).map(\.entry)
    }

    private static func build() -> [EmojiEntry] {
        var entries: [EmojiEntry] = []
        // Emoji code points start at U+203C and end by U+1FAFF.
        for value in UInt32(0x203C)...UInt32(0x1FAFF) {
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                  // Regional indicators and skin tone modifiers are parts of sequences.
                  !(0x1F1E6...0x1F1FF).contains(value), !(0x1F3FB...0x1F3FF).contains(value),
                  let name = scalar.properties.name else { continue }
            entries.append(EmojiEntry(character: String(Character(scalar)), name: name.lowercased()))
        }
        return entries
    }
}
