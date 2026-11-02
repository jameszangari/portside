import Foundation

/// App name, author, version, and repo in one place. The Settings header and
/// the update checker read them. Version and build details come from the
/// generated `BuildInfo.swift`; edit the version in VERSION at the repo root.
enum AppInfo {
    static let name = "Portside"
    static let author = "James Cliff"
    static let version = BuildInfo.version
    static let commit = BuildInfo.commit
    static let isDirty = BuildInfo.isDirty
    static let isRelease = BuildInfo.isRelease
    static let repoURL = URL(string: "https://github.com/jameszangari/portside")!
    static let bundleIdentifier = "com.james.portside"
    /// Developer ID team that signs release builds. Updates signed by anyone else are refused.
    static let releaseTeamID = "WNZ8H4UHQE"

    /// Short hash for dirty or unreleased builds ("abc1234", "abc1234-dirty"),
    /// nil for a clean release or when the commit is unknown.
    static var buildSuffix: String? {
        guard commit != "unknown" else { return nil }
        if isDirty == true { return "\(commit)-dirty" }
        return isRelease ? nil : commit
    }

    /// "Version 0.1.0 by James Cliff", plus " (abc1234)" when not a clean release.
    static var versionLine: String {
        let line = "Version \(version) by \(author)"
        guard let buildSuffix else { return line }
        return "\(line) (\(buildSuffix))"
    }
}
