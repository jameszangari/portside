import Foundation

/// App name, author, version, and repo in one place. Edit these here; the
/// Settings header and the update checker read them.
enum AppInfo {
    static let name = "Portside"
    static let author = "James"
    static let version = "0.1.0"
    static let repoURL = URL(string: "https://github.com/jameszangari/portside-dock")!

    /// "Version 0.1.0 by James"
    static var versionLine: String { "Version \(version) by \(author)" }
}
