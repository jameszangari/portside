import AppKit
import UniformTypeIdentifiers

/// Access to one system-owned preferences file, granted by the user picking it
/// in an open panel. macOS refuses these group containers with no prompt, and
/// the pick is what lets Portside read that one file and no other. The grant is
/// kept as a security-scoped bookmark.
@MainActor
final class MenuBarFileGrant: ObservableObject {
    let fileURL: URL
    private let bookmarkKey: String
    private let title: String
    private let message: String
    private let defaults: UserDefaults
    private var scoped: URL?
    @Published private(set) var isGranted = false

    init(fileURL: URL, bookmarkKey: String, title: String, message: String, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.bookmarkKey = bookmarkKey
        self.title = title
        self.message = message
        self.defaults = defaults
        activate()
    }

    /// Resumes a grant from an earlier launch.
    func activate() {
        if scoped == nil, let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { scoped = url }
                if stale { store(url) }
            } else {
                defaults.removeObject(forKey: bookmarkKey)
            }
        }
        isGranted = FileManager.default.isReadableFile(atPath: fileURL.path)
    }

    /// Asks the user to pick the file. True when they picked exactly that file.
    @discardableResult
    func request() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.title = title
        panel.message = message
        panel.prompt = "Grant Access"
        NSApp.activate()
        guard panel.runModal() == .OK, let picked = panel.url, picked.standardizedFileURL.path == fileURL.standardizedFileURL.path else { return false }
        store(picked)
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        activate()
        return isGranted
    }

    func revoke() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        defaults.removeObject(forKey: bookmarkKey)
        isGranted = false
    }

    private func store(_ url: URL) {
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil))
        if let data { defaults.set(data, forKey: bookmarkKey) }
    }

    /// The whole property list, or nil when it cannot be read.
    func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// The two system files Thaw-style arrangement and Native hiding work with.
enum MenuBarSystemFiles {
    private static let groupContainers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers")
    /// MenuBarAgent's saved item order.
    static let layoutTable = groupContainers.appendingPathComponent("com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    /// Control Center's per-app "Allow in the Menu Bar" list.
    static let appList = groupContainers.appendingPathComponent("group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")

    @MainActor static func layoutGrant() -> MenuBarFileGrant {
        MenuBarFileGrant(
            fileURL: layoutTable, bookmarkKey: "menuBarLayout.layoutTableBookmark", title: "Menu Bar Layout Access",
            message: "Select com.apple.MenuBar.plist. Portside can then restore your icon order without moving the pointer. It reads and changes this file only."
        )
    }

    @MainActor static func appListGrant() -> MenuBarFileGrant {
        MenuBarFileGrant(
            fileURL: appList, bookmarkKey: "menuBarLayout.appListBookmark", title: "Menu Bar App List Access",
            message: "Select group.com.apple.controlcenter.plist. Portside can then hide apps with macOS's own per-app switch. It reads and changes this file only."
        )
    }

    /// Developer aid: the shape of a granted file, to a temporary path.
    @MainActor static func dumpSchema(_ grants: [(String, MenuBarFileGrant)], to path: String) {
        var out: [String: Any] = [:]
        for (name, grant) in grants {
            guard let plist = grant.read() else {
                let error = (try? Data(contentsOf: grant.fileURL)) == nil ? "read failed" : "not a plist"
                out[name] = "unreadable (granted=\(grant.isGranted), \(error), exists=\(FileManager.default.fileExists(atPath: grant.fileURL.path)))"
                continue
            }
            var keys: [String: Any] = [:]
            for (key, value) in plist {
                if let dict = value as? [String: Any] {
                    keys[key] = ["type": "dict", "count": dict.count, "sample": Array(dict.sorted { $0.key < $1.key }.prefix(60)).map { "\($0.key) = \($0.value)" }]
                } else if let data = value as? Data, let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                    let items = (inner as? [Any]) ?? [inner]
                    keys[key] = ["type": "embedded plist", "count": items.count, "sample": items.prefix(120).map { String(describing: $0) }]
                } else if let array = value as? [Any] {
                    keys[key] = ["type": "array", "count": array.count, "sample": array.prefix(4).map { String(describing: $0) }]
                } else {
                    keys[key] = String(describing: type(of: value)) + ": " + String(describing: value).prefix(200)
                }
            }
            out[name] = keys
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
