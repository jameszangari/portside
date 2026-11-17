import Foundation

/// Restricted arithmetic for Command Center (P2-CMD-06). A hand written
/// recursive descent parser over numbers, `+ - * / ^`, unary signs and
/// parentheses. It never hands text to `NSExpression`, a shell or a script
/// engine, so nothing a person types can run as code.
enum ArithmeticCalculator {
    enum Failure: Error, Equatable {
        /// Not arithmetic (or not finished yet, like `2+`): no row is shown.
        case syntax
        case divideByZero
        case overflow

        var message: String? {
            switch self {
            case .syntax: return nil
            case .divideByZero: return "Cannot divide by zero."
            case .overflow: return "The result is too large to show."
            }
        }
    }

    struct Answer: Equatable {
        let value: Double
        /// The expression had an operator or parentheses. A bare number is
        /// not a calculation, so a port or a name never shows a result row.
        let isOperation: Bool
    }

    static let maxLength = 200
    static let maxDepth = 64
    static let maxDigits = 30

    /// `.` is always a decimal mark; the locale's own mark (`,` in German)
    /// is one too. Grouping separators are not accepted, so `1,000` is one
    /// thousand only where `,` is not the decimal mark.
    static func evaluate(_ text: String, locale: Locale = .current) -> Result<Answer, Failure> {
        var parser = Parser(text: text, decimalMarks: decimalMarks(locale))
        return parser.run()
    }

    static func decimalMarks(_ locale: Locale) -> Set<Character> {
        var marks: Set<Character> = ["."]
        if let own = locale.decimalSeparator?.first { marks.insert(own) }
        return marks
    }

    /// The answer as shown (grouped) and as copied (plain digits), both in
    /// the locale's decimal mark. Magnitudes that do not fit ten decimals
    /// use scientific notation.
    static func format(_ value: Double, locale: Locale = .current) -> (display: String, copy: String) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e15 || magnitude < 1e-10 {
            formatter.numberStyle = .scientific
            formatter.maximumSignificantDigits = 10
            let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
            return (text, text)
        }
        let display = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        formatter.usesGroupingSeparator = false
        let copy = formatter.string(from: NSNumber(value: value)) ?? display
        // A tiny negative rounds to "-0".
        return (display == "-0" ? "0" : display, copy == "-0" ? "0" : copy)
    }

    private struct Parser {
        private let chars: [Character]
        private let decimalMarks: Set<Character>
        private var index = 0
        private var depth = 0
        private var operations = 0
        private var failure: Failure?

        init(text: String, decimalMarks: Set<Character>) {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // "= 2+2" reads as 2+2.
            if trimmed.hasPrefix("=") { trimmed.removeFirst() }
            chars = Array(trimmed)
            self.decimalMarks = decimalMarks
        }

        mutating func run() -> Result<Answer, Failure> {
            guard !chars.isEmpty, chars.count <= ArithmeticCalculator.maxLength else { return .failure(.syntax) }
            guard let value = expression() else { return .failure(failure ?? .syntax) }
            skipSpaces()
            guard index == chars.count else { return .failure(.syntax) }
            guard value.isFinite else { return .failure(.overflow) }
            return .success(Answer(value: value, isOperation: operations > 0))
        }

        private mutating func skipSpaces() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        private mutating func take(_ options: [Character]) -> Character? {
            skipSpaces()
            guard index < chars.count, options.contains(chars[index]) else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = take(["+", "-", "−"]) {
                guard let rhs = term() else { return nil }
                operations += 1
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let op = take(["*", "×", "/", "÷"]) {
                guard let rhs = unary() else { return nil }
                operations += 1
                if op == "/" || op == "÷" {
                    guard rhs != 0 else {
                        failure = .divideByZero
                        return nil
                    }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func unary() -> Double? {
            if let sign = take(["-", "−", "+"]) {
                depth += 1
                defer { depth -= 1 }
                guard depth <= ArithmeticCalculator.maxDepth, let value = unary() else { return nil }
                return sign == "+" ? value : -value
            }
            return power()
        }

        /// Right associative, and the exponent may carry a sign: `2^-1`.
        private mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            guard take(["^"]) != nil else { return base }
            depth += 1
            defer { depth -= 1 }
            guard depth <= ArithmeticCalculator.maxDepth, let exponent = unary() else { return nil }
            operations += 1
            if base == 0, exponent < 0 {
                failure = .divideByZero
                return nil
            }
            let value = pow(base, exponent)
            guard value.isFinite else {
                failure = failure ?? .overflow
                return nil
            }
            return value
        }

        private mutating func primary() -> Double? {
            skipSpaces()
            guard index < chars.count else { return nil }
            if chars[index] == "(" {
                index += 1
                depth += 1
                defer { depth -= 1 }
                guard depth <= ArithmeticCalculator.maxDepth, let value = expression(), take([")"]) != nil else { return nil }
                operations += 1
                return value
            }
            return number()
        }

        private mutating func number() -> Double? {
            var text = ""
            var digits = 0
            var sawMark = false
            while index < chars.count {
                let character = chars[index]
                if character.isASCII, character.isNumber {
                    digits += 1
                    text.append(character)
                } else if decimalMarks.contains(character), !sawMark {
                    sawMark = true
                    text.append(".")
                } else {
                    break
                }
                index += 1
            }
            guard digits > 0, digits <= ArithmeticCalculator.maxDigits, let value = Double(text) else { return nil }
            return value
        }
    }
}
