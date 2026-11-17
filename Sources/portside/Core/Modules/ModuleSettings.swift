import Foundation

/// Any JSON value, kept as read so settings this build does not understand
/// are written back unchanged. Numbers are Doubles (integers above 2^53 lose
/// precision, which no Portside setting uses).
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

/// The `modules` object in dock.json: one entry per module id, each an
/// object with `enabled` plus whatever settings that module adds later.
/// The whole value is kept as read, so unknown modules, unknown nested keys
/// and even a malformed value survive a save. Only `setEnabled` changes it.
struct ModuleSettings: Codable, Equatable {
    static let enabledKey = "enabled"

    private(set) var raw: JSONValue

    init(raw: JSONValue = .object([:])) { self.raw = raw }

    init(from decoder: Decoder) throws { raw = try JSONValue(from: decoder) }

    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    /// Nothing saved: no key is written.
    var isEmpty: Bool { raw == .object([:]) }

    /// The saved choice, or nil when there is none or it is not a Bool.
    func savedEnabled(_ id: ModuleID) -> Bool? {
        guard case .object(let modules) = raw,
              case .object(let entry)? = modules[id.rawValue],
              case .bool(let enabled)? = entry[Self.enabledKey] else { return nil }
        return enabled
    }

    /// Required modules always run. Optional ones run only when the user
    /// turned them on, so a module added by an update starts off.
    func isEnabled(_ id: ModuleID, required: Bool) -> Bool {
        required || savedEnabled(id) == true
    }

    /// Sets `enabled` and keeps the entry's other keys. A malformed `modules`
    /// value or entry is replaced, since it cannot hold the choice.
    mutating func setEnabled(_ enabled: Bool, for id: ModuleID) {
        var modules: [String: JSONValue] = [:]
        if case .object(let existing) = raw { modules = existing }
        var entry: [String: JSONValue] = [:]
        if case .object(let existing)? = modules[id.rawValue] { entry = existing }
        entry[Self.enabledKey] = .bool(enabled)
        modules[id.rawValue] = .object(entry)
        raw = .object(modules)
    }
}
