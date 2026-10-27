import Foundation

/// A user-defined group of apps shown as one tile in the strip. Clicking the
/// tile expands it into a grid in the overlay panel. Not a filesystem stack.
///
/// Stores full `PinnedApp`s rather than ids so apps without a bundle id keep
/// their path. Expanded state is not persisted: the grid is transient and
/// closes whenever the dock hides.
struct FolderGroup: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var apps: [PinnedApp]

    init(id: String = UUID().uuidString, name: String, apps: [PinnedApp]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

/// One slot in the strip's pinned section: an app or a group.
enum DockEntry: Hashable, Identifiable {
    case app(PinnedApp)
    case group(FolderGroup)

    var id: String {
        switch self {
        case .app(let app): app.id
        case .group(let group): "group:" + group.id
        }
    }

    /// Apps in this slot (one for an app, the members for a group).
    var apps: [PinnedApp] {
        switch self {
        case .app(let app): [app]
        case .group(let group): group.apps
        }
    }

    var group: FolderGroup? {
        if case .group(let group) = self { return group }
        return nil
    }
}

extension DockEntry: Codable {
    private enum CodingKeys: String, CodingKey { case type, app, group }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "group": self = .group(try c.decode(FolderGroup.self, forKey: .group))
        default: self = .app(try c.decode(PinnedApp.self, forKey: .app))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let app):
            try c.encode("app", forKey: .type)
            try c.encode(app, forKey: .app)
        case .group(let group):
            try c.encode("group", forKey: .type)
            try c.encode(group, forKey: .group)
        }
    }
}
