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

/// Empty gap between pinned apps, like a native Dock spacer tile.
struct DockSpacer: Codable, Hashable, Identifiable {
    enum Size: String, Codable, CaseIterable {
        case regular, small

        var title: String {
            switch self {
            case .regular: "Regular Spacer"
            case .small: "Small Spacer"
            }
        }

        /// Width relative to the current icon size.
        var widthFactor: CGFloat {
            switch self {
            case .regular: 1
            case .small: 0.45
            }
        }
    }

    var id: String
    var size: Size

    init(id: String = UUID().uuidString, size: Size) {
        self.id = id
        self.size = size
    }
}

/// One slot in the strip's pinned section: an app, a group, or a spacer.
enum DockEntry: Hashable, Identifiable {
    case app(PinnedApp)
    case group(FolderGroup)
    case spacer(DockSpacer)

    var id: String {
        switch self {
        case .app(let app): app.id
        case .group(let group): "group:" + group.id
        case .spacer(let spacer): "spacer:" + spacer.id
        }
    }

    /// Apps in this slot (one for an app, the members for a group, none for a spacer).
    var apps: [PinnedApp] {
        switch self {
        case .app(let app): [app]
        case .group(let group): group.apps
        case .spacer: []
        }
    }

    var group: FolderGroup? {
        if case .group(let group) = self { return group }
        return nil
    }

    var spacer: DockSpacer? {
        if case .spacer(let spacer) = self { return spacer }
        return nil
    }
}

extension DockEntry: Codable {
    private enum CodingKeys: String, CodingKey { case type, app, group, spacer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "group": self = .group(try c.decode(FolderGroup.self, forKey: .group))
        case "spacer": self = .spacer(try c.decode(DockSpacer.self, forKey: .spacer))
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
        case .spacer(let spacer):
            try c.encode("spacer", forKey: .type)
            try c.encode(spacer, forKey: .spacer)
        }
    }
}
