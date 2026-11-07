import Foundation

/// A user-made link in Command Center (`commandCenterQuicklinks` in
/// dock.json). The URL is stored as typed, so a half-typed or refused link
/// survives and its row says why it cannot open.
struct Quicklink: Codable, Equatable, Identifiable, Sendable {
    static let nameLimit = 100
    static let listLimit = 100

    var id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String = "", url: String = "") {
        self.id = id
        self.name = String(name.prefix(Self.nameLimit))
        self.url = String(url.prefix(QuicklinkURL.maxLength))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: c.value(.name, or: ""),
            url: try c.decode(String.self, forKey: .url)
        )
    }

    /// The row title: the name, else the link's host, else the text.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URLComponents(string: url)?.host, !host.isEmpty { return host }
        return url.isEmpty ? "Untitled Quicklink" : url
    }
}

/// Lenient element wrapper for `[Quicklink]` in dock.json: an entry that
/// fails to decode (no id, no URL) is dropped alone, never the whole list.
struct DecodedQuicklink: Decodable {
    let value: Quicklink?

    init(from decoder: Decoder) throws {
        value = try? Quicklink(from: decoder)
    }
}

/// The scheme allowlist and shape checks for quicklinks. Checked when the
/// row is built and again by the command right before opening, so a link
/// edited mid-session or passed by another caller is refused the same way.
enum QuicklinkURL {
    /// Anything else (file, javascript, data, custom app schemes) is refused.
    static let allowedSchemes: [String] = ["https", "http", "mailto", "x-apple.systempreferences"]
    static let maxLength = 2048

    enum Problem: Error, Equatable {
        case empty
        case tooLong
        case malformed
        case scheme(String)
        case missingHost
        case missingAddress
        case credentials

        var message: String {
            switch self {
            case .empty: return "Add a link."
            case .tooLong: return "The link is longer than \(QuicklinkURL.maxLength) characters."
            case .malformed: return "Not a valid link. Start it with https:// or mailto:."
            case .scheme(let scheme): return "Links starting with “\(scheme):” are not allowed. Use https, http, mailto or x-apple.systempreferences."
            case .missingHost: return "The link has no website address."
            case .missingAddress: return "The mailto link has no email address."
            case .credentials: return "Links with a user name or password are not allowed."
            }
        }
    }

    static func validate(_ text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= maxLength else { return .failure(.tooLong) }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
              let url = URL(string: trimmed) else {
            return .failure(.malformed)
        }
        guard allowedSchemes.contains(scheme) else { return .failure(.scheme(scheme)) }
        if components.user != nil || components.password != nil { return .failure(.credentials) }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        case "mailto":
            guard !components.path.isEmpty else { return .failure(.missingAddress) }
        default:
            break
        }
        return .success(url)
    }
}
