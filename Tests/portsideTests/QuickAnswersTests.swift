import Combine
import XCTest
@testable import portside

/// P2-CMD-06: restricted arithmetic, locale formatting, emoji search and
/// the rows both produce.
@MainActor
final class QuickAnswersTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    private func value(_ text: String, _ locale: Locale? = nil) -> Double? {
        if case .success(let answer) = ArithmeticCalculator.evaluate(text, locale: locale ?? us) { return answer.value }
        return nil
    }

    private func failure(_ text: String, _ locale: Locale? = nil) -> ArithmeticCalculator.Failure? {
        if case .failure(let failure) = ArithmeticCalculator.evaluate(text, locale: locale ?? us) { return failure }
        return nil
    }

    func testPrecedenceAssociativityAndSigns() {
        XCTAssertEqual(value("2+3*4"), 14)
        XCTAssertEqual(value("(2+3)*4"), 20)
        XCTAssertEqual(value("2^3^2"), 512, "power is right associative")
        XCTAssertEqual(value("-2^2"), -4)
        XCTAssertEqual(value("2^-1"), 0.5)
        XCTAssertEqual(value("10 - 4 - 3"), 3)
        XCTAssertEqual(value("8/4/2"), 1)
        XCTAssertEqual(value("6 × 7"), 42)
        XCTAssertEqual(value("9 ÷ 3"), 3)
        XCTAssertEqual(value("= 1+1"), 2)
        XCTAssertEqual(value("--3+1"), 4)
        XCTAssertEqual(value("1.5*2"), 3)
        XCTAssertEqual(value(".5+.5"), 1)
    }

    func testDivideByZeroAndOverflowAreNamedNotCrashes() {
        XCTAssertEqual(failure("1/0"), .divideByZero)
        XCTAssertEqual(failure("0/0"), .divideByZero)
        XCTAssertEqual(failure("5/(2-2)"), .divideByZero)
        XCTAssertEqual(failure("0^-1"), .divideByZero)
        XCTAssertEqual(failure("10^400"), .overflow)
        XCTAssertEqual(failure("9^9^9"), .overflow)
        XCTAssertEqual(ArithmeticCalculator.Failure.divideByZero.message, "Cannot divide by zero.")
        XCTAssertNil(ArithmeticCalculator.Failure.syntax.message)
    }

    func testMalformedInputIsSyntaxAndNeverEvaluatesText() {
        for text in ["", " ", "2+", "*3", "(1+2", "1+2)", "2 2", "1..2", "1.2.3", "abc", "2+x", "sqrt(4)", "1e3", "$(echo 1)",
                     "`ls`", "1;2", "2**3", "()", "5173:80", "0x10", "1,000+1"] {
            XCTAssertEqual(failure(text), .syntax, text)
        }
        XCTAssertEqual(failure(String(repeating: "1+", count: 200) + "1"), .syntax, "over the length cap")
        XCTAssertEqual(failure(String(repeating: "1", count: 31)), .syntax, "over the digit cap")
    }

    func testDeepNestingIsBoundedNotAStackOverflow() {
        let deep = String(repeating: "(", count: 90) + "1" + String(repeating: ")", count: 90)
        XCTAssertEqual(failure(deep), .syntax)
        XCTAssertEqual(failure(String(repeating: "-", count: 150) + "1"), .syntax)
        let fine = String(repeating: "(", count: 30) + "1" + String(repeating: ")", count: 30)
        XCTAssertEqual(value(fine), 1)
    }

    func testBareNumberIsNotAnOperation() {
        guard case .success(let number) = ArithmeticCalculator.evaluate("5173", locale: us) else { return XCTFail() }
        XCTAssertFalse(number.isOperation)
        guard case .success(let signed) = ArithmeticCalculator.evaluate("-5", locale: us) else { return XCTFail() }
        XCTAssertFalse(signed.isOperation)
        guard case .success(let sum) = ArithmeticCalculator.evaluate("1+1", locale: us) else { return XCTFail() }
        XCTAssertTrue(sum.isOperation)
    }

    func testLocaleDecimalMarkIsReadAndWritten() {
        XCTAssertEqual(value("1,5+2", german), 3.5)
        XCTAssertEqual(value("1.5+2", german), 3.5, "a dot is a decimal mark in every locale")
        XCTAssertEqual(failure("1,5+2", us), .syntax, "a comma is not a decimal mark in en_US")
        XCTAssertEqual(ArithmeticCalculator.format(3.5, locale: german).display, "3,5")
        XCTAssertEqual(ArithmeticCalculator.format(3.5, locale: us).display, "3.5")
    }

    func testFormatGroupsForDisplayAndCopiesPlainDigits() {
        XCTAssertEqual(ArithmeticCalculator.format(1_000_000, locale: us).display, "1,000,000")
        XCTAssertEqual(ArithmeticCalculator.format(1_000_000, locale: us).copy, "1000000")
        XCTAssertEqual(ArithmeticCalculator.format(1234567.5, locale: german).display, "1.234.567,5")
        XCTAssertEqual(ArithmeticCalculator.format(1234567.5, locale: german).copy, "1234567,5")
        XCTAssertEqual(ArithmeticCalculator.format(0.1 + 0.2, locale: us).copy, "0.3", "binary noise is rounded away")
        XCTAssertEqual(ArithmeticCalculator.format(-0.0, locale: us).copy, "0")
        XCTAssertEqual(ArithmeticCalculator.format(1e20, locale: us).copy, ArithmeticCalculator.format(1e20, locale: us).display)
        XCTAssertTrue(ArithmeticCalculator.format(1e20, locale: us).display.contains("E"))
    }

    // MARK: Emoji

    func testEmojiTriggersNeedEmojiWordOrColon() {
        XCTAssertEqual(EmojiIndex.searchText(in: "emoji smile"), "smile")
        XCTAssertEqual(CommandCenterRanker.terms(EmojiIndex.searchText(in: "  Emoji  smile ") ?? ""), ["smile"])
        XCTAssertEqual(EmojiIndex.searchText(in: ":rocket"), "rocket")
        XCTAssertEqual(EmojiIndex.searchText(in: "emoji"), "")
        XCTAssertNil(EmojiIndex.searchText(in: "emojis"))
        XCTAssertNil(EmojiIndex.searchText(in: "smile"))
        XCTAssertNil(EmojiIndex.searchText(in: "safari"))
    }

    func testEmojiIndexHasUnicodeNamesAndSearchesWordPrefixes() {
        let index = EmojiIndex.shared
        XCTAssertGreaterThan(index.entries.count, 800)
        XCTAssertTrue(index.entries.allSatisfy { !$0.character.isEmpty && $0.name == $0.name.lowercased() })
        XCTAssertEqual(index.search("rocket").first?.character, "🚀")
        XCTAssertEqual(index.search("grinning face").first?.name, "grinning face", "whole name first")
        XCTAssertEqual(index.search("GRIN FA").first?.character, "😀", "case and word prefixes")
        XCTAssertTrue(index.search("zzzz").isEmpty)
        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertLessThanOrEqual(index.search("face").count, EmojiIndex.resultLimit)
        XCTAssertFalse(index.entries.contains { $0.name.contains("regional indicator") || $0.name.contains("emoji modifier") })
    }

    func testEmojiSearchIsDeterministic() {
        let index = EmojiIndex.shared
        XCTAssertEqual(index.search("face"), index.search("face"))
        XCTAssertEqual(EmojiEntry(character: "😀", name: "grinning face").scalarKey, "1f600")
        XCTAssertEqual(EmojiEntry(character: "😀", name: "grinning face").title, "Grinning face")
    }

    func testEmojiSearchWithInjectedEntriesOrdersWholeNamePrefixThenWords() {
        let index = EmojiIndex(entries: [
            EmojiEntry(character: "A", name: "big smile eyes"),
            EmojiEntry(character: "B", name: "smile"),
            EmojiEntry(character: "C", name: "smile with sun"),
        ])
        XCTAssertEqual(index.search("smile").map(\.character), ["B", "C", "A"])
    }

    // MARK: Rows

    private let copyDescriptor = CommandDescriptor(id: CommandCenterModule.copyTextCommand, title: "Copy Text", input: .string(maxLength: 256)) { _ in .success(nil) }

    private func rows(_ query: String, locale: Locale? = nil, copy: CommandDescriptor? = nil) -> [CommandCenterItem] {
        QuickAnswers(locale: locale ?? us, emoji: EmojiIndex.shared).items(query: query, copy: copy ?? copyDescriptor)
    }

    func testCalculatorRowCopiesPlainResultAndRanksAsTheAnswer() throws {
        let item = try XCTUnwrap(rows("1000*1000").first)
        XCTAssertEqual(item.id, .calculation)
        XCTAssertEqual(item.kind, .calculation)
        XCTAssertEqual(item.title, "1,000,000")
        XCTAssertEqual(item.invocation, CommandInvocation(command: CommandCenterModule.copyTextCommand, input: .string("1000000")))
        XCTAssertEqual(item.primaryTitle, "Copy Result")
        XCTAssertNil(item.unavailableReason)
        XCTAssertEqual(item.answers, CommandCenterRanker.answerKey("1000*1000"))
        XCTAssertEqual(CommandCenterRanker.match(item, terms: CommandCenterRanker.terms("1000*1000"))?.tier, .answer)
    }

    func testCalculatorRowAppearsOnlyForArithmetic() {
        XCTAssertTrue(rows("5173").isEmpty)
        XCTAssertTrue(rows("port 5173").isEmpty)
        XCTAssertTrue(rows("safari").isEmpty)
        XCTAssertTrue(rows("2+").isEmpty, "unfinished input shows nothing")
        XCTAssertTrue(rows("").isEmpty)
        XCTAssertEqual(rows("(1+2)*3").first?.title, "9")
    }

    func testCalculatorCardShowsExpressionAndAnswer() throws {
        let card = try XCTUnwrap(rows("= 2/2 * 3").first?.card)
        XCTAssertEqual(card, CommandCenterCard(input: "2÷2 × 3", output: "3"))
        XCTAssertNil(rows("1/0").first?.card)
    }

    func testDivideByZeroRowIsUnavailableWithReason() throws {
        let item = try XCTUnwrap(rows("1/0").first)
        XCTAssertEqual(item.unavailableReason, "Cannot divide by zero.")
        XCTAssertEqual(item.title, "Cannot calculate")
    }

    func testGermanRowUsesCommaInTitleAndCopy() throws {
        let item = try XCTUnwrap(rows("1,5*2000", locale: german).first)
        XCTAssertEqual(item.title, "3.000")
        XCTAssertEqual(item.invocation.input, .string("3000"))
        let half = try XCTUnwrap(rows("1/2", locale: german).first)
        XCTAssertEqual(half.invocation.input, .string("0,5"))
    }

    func testEmojiRowsCopyTheCharacterInSearchOrder() throws {
        let found = rows("emoji rocket")
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.kind, .emoji)
        XCTAssertEqual(first.glyph, "🚀")
        XCTAssertEqual(first.invocation.input, .string("🚀"))
        XCTAssertEqual(first.id, .emoji("1f680"))
        XCTAssertEqual(found.map(\.answerOrder), Array(0..<found.count))
        XCTAssertEqual(rows(":rocket").first?.glyph, "🚀")
        XCTAssertTrue(rows("emoji").isEmpty)
    }

    func testEmojiRowsRankInSearchOrderUnderTheSameQuery() {
        let found = rows("emoji face")
        let ids = CommandCenterRanker.rank(found, query: "emoji face")
        XCTAssertEqual(ids, found.map(\.id), "answerOrder, not title, decides")
    }

    func testUnavailableCopyCommandMarksRows() {
        XCTAssertEqual(rows("1+1", copy: copyDescriptorOff).first?.unavailableReason, "off")
        let none = QuickAnswers(locale: us).items(query: "1+1", copy: nil)
        XCTAssertEqual(none.first?.unavailableReason, "This build cannot copy.")
    }

    private var copyDescriptorOff: CommandDescriptor {
        CommandDescriptor(id: CommandCenterModule.copyTextCommand, title: "Copy Text", input: .string(maxLength: 256),
                          unavailableReason: { "off" }) { _ in .success(nil) }
    }

    func testQuickAnswersHaveNoSeparateCopyAction() throws {
        var state = CommandCenterState()
        let item = try XCTUnwrap(rows("2+2").first)
        _ = state.send(.open([item]))
        let actions = state.actions(for: item).map(\.kind)
        XCTAssertFalse(actions.contains(.copyID))
        XCTAssertEqual(state.actions(for: item).map(\.kind), [.run, .showDetails])
    }

    // MARK: Copy command

    func testCopyTextCommandCopiesOnlyThroughTheInjectedAction() async throws {
        var copied: [String] = []
        var actions = CommandCenterActions.none
        actions.copyText = { copied.append($0); return true }
        let module = CommandCenterModule(center: CommandCenter(commands: CommandRegistry(), moduleTitle: { _ in nil }),
                                         chords: Just(nil).eraseToAnyPublisher(), actions: actions)
        let descriptor = try XCTUnwrap(module.commands().first { $0.id == CommandCenterModule.copyTextCommand })
        XCTAssertEqual(descriptor.input, .string(maxLength: 256))
        let result = await descriptor.handler(.string("🚀"))
        XCTAssertEqual(copied, ["🚀"])
        if case .failure = result { XCTFail() }
        if case .success = await descriptor.handler(.string("")) { XCTFail("empty text") }
        XCTAssertEqual(copied, ["🚀"])
    }
}
