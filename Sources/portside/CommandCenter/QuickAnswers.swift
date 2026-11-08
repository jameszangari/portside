import Foundation

/// Rows computed from the query itself: a calculator result and emoji
/// matches (P2-CMD-06). Nothing is stored or indexed; each row copies its
/// text through the `commandCenter.copyText` registry command. They rank
/// first for exactly the query that produced them (`answers`), and are
/// session only, so they never enter history.
@MainActor
struct QuickAnswers {
    var locale: Locale = .current
    var emoji: EmojiIndex = .shared

    func items(query: String, copy: CommandDescriptor?) -> [CommandCenterItem] {
        let reason = copy.map { $0.unavailableReason() } ?? "This build cannot copy."
        let key = CommandCenterRanker.answerKey(query)
        if let search = EmojiIndex.searchText(in: query) {
            return emoji.search(search).enumerated().map { order, entry in
                emojiItem(entry, order: order, key: key, reason: reason)
            }
        }
        return calculatorItem(query, key: key, reason: reason).map { [$0] } ?? []
    }

    private func calculatorItem(_ query: String, key: String, reason: String?) -> CommandCenterItem? {
        let invocation: CommandInvocation
        let title: String
        let copyValue: String
        let problem: String?
        switch ArithmeticCalculator.evaluate(query, locale: locale) {
        case .success(let answer):
            guard answer.isOperation else { return nil }
            let text = ArithmeticCalculator.format(answer.value, locale: locale)
            title = text.display
            copyValue = text.copy
            problem = nil
            invocation = CommandInvocation(command: CommandCenterModule.copyTextCommand, input: .string(text.copy))
        case .failure(let failure):
            guard let message = failure.message else { return nil }
            title = "Cannot calculate"
            copyValue = ""
            problem = message
            invocation = CommandInvocation(command: CommandCenterModule.copyTextCommand)
        }
        var item = CommandCenterItem(
            id: .calculation, kind: .calculation, title: title, subtitle: "Calculator",
            symbolName: "equal.square", keywords: [], unavailableReason: problem ?? reason,
            invocation: invocation, primaryTitle: "Copy Result", copyValue: copyValue, copyTitle: "Copy Result"
        )
        item.answers = key
        if problem == nil { item.card = CommandCenterCard(input: Self.prettify(query), output: title) }
        return item
    }

    /// The expression as typed, with the division and multiplication signs.
    static func prettify(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "÷")
            .replacingOccurrences(of: "*", with: "×")
    }

    private func emojiItem(_ entry: EmojiEntry, order: Int, key: String, reason: String?) -> CommandCenterItem {
        var item = CommandCenterItem(
            id: .emoji(entry.scalarKey), kind: .emoji, title: entry.title, subtitle: "Emoji",
            symbolName: "face.smiling", keywords: [], unavailableReason: reason,
            invocation: CommandInvocation(command: CommandCenterModule.copyTextCommand, input: .string(entry.character)),
            primaryTitle: "Copy Emoji", copyValue: entry.character, copyTitle: "Copy Emoji"
        )
        item.glyph = entry.character
        item.answers = key
        item.answerOrder = order
        return item
    }
}
