import Foundation

/// Stable, namespaced command identifier: `module.name`, lowercase ASCII
/// letters and digits with camelCase allowed after the first character of
/// each part (for example `portside.openSettings`).
struct CommandID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isValidPart) else { return nil }
        self.rawValue = rawValue
    }

    static func isValidPart<S: StringProtocol>(_ part: S) -> Bool {
        guard let first = part.first, first.isASCII, first.isLowercase else { return false }
        return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The part before the dot; for module commands, the owning module's ID.
    var namespace: String { String(rawValue.prefix { $0 != "." }) }

    var description: String { rawValue }
}

/// What a command accepts. Validated before the handler runs, whoever the
/// caller is (UI, shortcut, or later a model).
enum CommandInputSchema: Equatable {
    case none
    case string(maxLength: Int)
    case integer(ClosedRange<Int>)
}

enum CommandInput: Equatable, Sendable {
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
    /// SF Symbol shown beside the title in Command Center. nil uses a generic one.
    let symbolName: String?
    let input: CommandInputSchema
    /// nil when the command can run now, otherwise the reason it cannot.
    let unavailableReason: () -> String?
    /// Scopes that must be granted at validation and again just before the handler.
    let requiredPermissions: [PermissionScope]
    /// Read-only executor: the handler returns an outcome and the registry
    /// owns validation, availability and cancellation.
    let handler: @MainActor (CommandInput) async -> Result<String?, CommandFailure>

    init(
        id: CommandID,
        title: String,
        keywords: [String] = [],
        symbolName: String? = nil,
        input: CommandInputSchema = .none,
        unavailableReason: @escaping () -> String? = { nil },
        requiredPermissions: [PermissionScope] = [],
        handler: @escaping @MainActor (CommandInput) async -> Result<String?, CommandFailure>
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.symbolName = symbolName
        self.input = input
        self.unavailableReason = unavailableReason
        self.requiredPermissions = requiredPermissions
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

    private let permissions: PermissionGate

    nonisolated init(permissions: PermissionGate = PermissionGate()) {
        self.permissions = permissions
    }

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

    /// Validates, checks permissions and availability, runs the handler, and returns exactly
    /// one result. Canceling the calling task yields `.canceled`, including
    /// when the handler finished after the cancel.
    func execute(_ id: CommandID, input: CommandInput = .none) async -> CommandResult {
        guard let command = commands[id] else { return .unknownCommand }
        if let problem = Self.validate(input, against: command.input) { return .invalidInput(problem) }
        let ticket: PermissionTicket
        switch permissions.prepare(command.requiredPermissions) {
        case .failure(let denial): return .unavailable(denial.reason)
        case .success(let issued): ticket = issued
        }
        if let reason = command.unavailableReason() { return .unavailable(reason) }
        if Task.isCancelled { return .canceled }
        // Permission can be revoked after validation; read it again now.
        if let denial = permissions.authorizeExecution(ticket) { return .unavailable(denial.reason) }
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
