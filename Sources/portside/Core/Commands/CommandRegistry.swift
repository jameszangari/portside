import Foundation

/// Stable, namespaced command identifier: `module.name`, lowercase ASCII
/// letters and digits with camelCase allowed after the first character of
/// each part (for example `portside.openSettings`).
struct CommandID: Hashable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isValidPart) else { return nil }
        self.rawValue = rawValue
    }

    private static func isValidPart(_ part: Substring) -> Bool {
        guard let first = part.first, first.isASCII, first.isLowercase else { return false }
        return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    var description: String { rawValue }
}

/// What a command accepts. Validated before the handler runs, whoever the
/// caller is (UI, shortcut, or later a model).
enum CommandInputSchema: Equatable {
    case none
    case string(maxLength: Int)
    case integer(ClosedRange<Int>)
}

enum CommandInput: Equatable {
    case none
    case string(String)
    case integer(Int)
}

/// Why a command did not run or did not finish. Every case carries enough
/// text to show a person.
enum CommandResult: Equatable {
    case success(String?)
    case invalidInput(String)
    case unavailable(String)
    case unknownCommand
    case failed(String)
    case canceled
}

struct CommandDescriptor {
    let id: CommandID
    let title: String
    let keywords: [String]
    let input: CommandInputSchema
    /// nil when the command can run now, otherwise the reason it cannot.
    let unavailableReason: () -> String?
    /// Read-only executor: the handler returns an outcome and the registry
    /// owns validation, availability and cancellation.
    let handler: @MainActor (CommandInput) async -> Result<String?, CommandFailure>

    init(
        id: CommandID,
        title: String,
        keywords: [String] = [],
        input: CommandInputSchema = .none,
        unavailableReason: @escaping () -> String? = { nil },
        handler: @escaping @MainActor (CommandInput) async -> Result<String?, CommandFailure>
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.input = input
        self.unavailableReason = unavailableReason
        self.handler = handler
    }
}

struct CommandFailure: Error, Equatable {
    let reason: String
}

enum CommandRegistryError: Error, Equatable {
    case duplicateID(CommandID)
}

/// One catalog of commands and one executor. Surfaces call `execute`; none
/// of them reach a handler directly. Main actor only, so registration and
/// lookup need no locking.
@MainActor
final class CommandRegistry {
    private var commands: [CommandID: CommandDescriptor] = [:]

    nonisolated init() {}

    var descriptors: [CommandDescriptor] {
        commands.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func register(_ descriptor: CommandDescriptor) throws {
        guard commands[descriptor.id] == nil else { throw CommandRegistryError.duplicateID(descriptor.id) }
        commands[descriptor.id] = descriptor
    }

    func descriptor(for id: CommandID) -> CommandDescriptor? {
        commands[id]
    }

    /// Validates, checks availability, runs the handler, and returns exactly
    /// one result. Canceling the calling task yields `.canceled`, including
    /// when the handler finished after the cancel.
    func execute(_ id: CommandID, input: CommandInput = .none) async -> CommandResult {
        guard let command = commands[id] else { return .unknownCommand }
        if let problem = Self.validate(input, against: command.input) { return .invalidInput(problem) }
        if let reason = command.unavailableReason() { return .unavailable(reason) }
        if Task.isCancelled { return .canceled }
        let outcome = await command.handler(input)
        if Task.isCancelled { return .canceled }
        switch outcome {
        case .success(let message): return .success(message)
        case .failure(let failure): return .failed(failure.reason)
        }
    }

    static func validate(_ input: CommandInput, against schema: CommandInputSchema) -> String? {
        switch (schema, input) {
        case (.none, .none):
            return nil
        case (.string(let maxLength), .string(let value)):
            return value.count <= maxLength ? nil : "Text is longer than \(maxLength) characters."
        case (.integer(let range), .integer(let value)):
            return range.contains(value) ? nil : "Value must be \(range.lowerBound) to \(range.upperBound)."
        default:
            return "Input does not match what the command accepts."
        }
    }
}
