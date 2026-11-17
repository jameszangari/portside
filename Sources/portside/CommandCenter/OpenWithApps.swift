import AppKit

/// Apps that can open a file, for the Open With actions. Public
/// `NSWorkspace` lookups, cached by file extension so a list of results does
/// not ask Launch Services once per row per keystroke.
@MainActor
final class OpenWithApps {
    static let limit = 8

    private var cache: [String: [URL]] = [:]
    private let lookup: @MainActor (URL) -> (default: URL?, all: [URL])

    init(lookup: @escaping @MainActor (URL) -> (default: URL?, all: [URL]) = { file in
        (NSWorkspace.shared.urlForApplication(toOpen: file), NSWorkspace.shared.urlsForApplications(toOpen: file))
    }) {
        self.lookup = lookup
    }

    /// The default app first, then the others by name; at most `limit`.
    /// Portside itself is left out.
    func apps(for file: URL) -> [URL] {
        let ext = file.pathExtension.lowercased()
        if !ext.isEmpty, let cached = cache[ext] { return cached }
        let found = lookup(file)
        var seen = Set<String>()
        let own = Bundle.main.bundleURL.path
        let others = found.all.filter { $0.path != own && $0 != found.default }
            .sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
        let ordered = ([found.default].compactMap { $0 } + others).filter { seen.insert($0.path).inserted }
        let result = Array(ordered.prefix(Self.limit))
        if !ext.isEmpty { cache[ext] = result }
        return result
    }

    static func name(_ app: URL) -> String { app.deletingPathExtension().lastPathComponent }
}
