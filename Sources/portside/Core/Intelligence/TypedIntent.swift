import Foundation

/// The closed set of actions a model may propose. Adding a case here is the
/// only way to add one; nothing a model writes can extend it.
enum IntentKind: String, CaseIterable, Sendable {
    /// Which app or process is using one network port.
    case findPortOwner
    /// The request names no port or more than one.
    case ambiguous
    /// Anything Portside does not offer.
    case unsupported
}

/// What a provider returned, before validation. Untrusted: `kind` may be any
/// string and `port` any number. It has no field for a process, owner,
/// command or permission, so a model cannot supply one.
struct RawIntentProposal: Equatable, Sendable {
    let kind: String
    let port: Int?
}

/// A validated proposal. It names what to look up and nothing else: the
/// owner of the port always comes from a native service, never the model.
enum TypedIntent: Equatable, Sendable {
    case findPortOwner(port: UInt16)
}

/// The single result of one intent request. Proposals are never executed
/// here; a caller still runs the matching command through `CommandRegistry`.
enum IntentOutcome: Equatable {
    case proposed(TypedIntent)
    /// The request needs a person to say more (no port, or more than one).
    case needsDetail(String)
    /// The request asks for something Portside does not offer.
    case unsupportedIntent(String)
    /// The model's output failed validation and was dropped.
    case invalidIntent(String)
    /// The model did not run or did not finish. Never `.completed`.
    case stopped(IntelligenceOutcome)
}

/// Checks a raw proposal against the request text. Deterministic and the
/// final word: the model narrows the request, this decides. A port is
/// accepted only when it is in range, written in the request as digits, and
/// the only number there. Every message is fixed text, so nothing the model
/// writes reaches a person.
enum IntentValidator {
    static let ports: ClosedRange<Int> = 1...65535
    /// Output budget for one proposal; a kind and a port fit well inside it.
    static let maxOutputCharacters = 256

    enum Message {
        static let needsPort = "Say which port to look up, for example \"port 5173\"."
        static let onePort = "The request names more than one number. Say which one port to look up."
        static let unsupported = "Portside can only look up which app is using a port."
        static let unknownAction = "The model proposed an action Portside does not offer."
        static let missingPort = "The model proposed a port lookup without a port."
        static let outOfRange = "Ports are 1 to 65535."
        static let notInRequest = "The proposed port is not written in the request."
    }

    static func validate(_ raw: RawIntentProposal, request: String) -> IntentOutcome {
        guard let kind = IntentKind(rawValue: raw.kind) else { return .invalidIntent(Message.unknownAction) }
        switch kind {
        case .unsupported: return .unsupportedIntent(Message.unsupported)
        case .ambiguous: return .needsDetail(Message.needsPort)
        case .findPortOwner:
            guard let port = raw.port else { return .invalidIntent(Message.missingPort) }
            guard ports.contains(port), let value = UInt16(exactly: port) else { return .invalidIntent(Message.outOfRange) }
            let numbers = numbers(in: request)
            guard numbers.contains(String(port)) else { return .invalidIntent(Message.notInRequest) }
            guard numbers.count == 1 else { return .needsDetail(Message.onePort) }
            return .proposed(.findPortOwner(port: value))
        }
    }

    /// Distinct ASCII digit runs in `text`, leading zeros dropped. A dotted
    /// group such as 127.0.0.1 or 1.2.3 is one address or version, not a
    /// port, and is skipped; a sentence's trailing period is not a group.
    static func numbers(in text: String) -> Set<String> {
        let characters = Array(text)
        var found = Set<String>()
        var index = 0
        while index < characters.count {
            guard isDigit(characters[index]) else {
                index += 1
                continue
            }
            var end = index
            var dotted = false
            while end < characters.count {
                if isDigit(characters[end]) {
                    end += 1
                } else if characters[end] == ".", end + 1 < characters.count, isDigit(characters[end + 1]) {
                    dotted = true
                    end += 1
                } else {
                    break
                }
            }
            if !dotted {
                let run = String(characters[index..<end]).drop { $0 == "0" }
                found.insert(run.isEmpty ? "0" : String(run))
            }
            index = end
        }
        return found
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
