import Foundation

/// What an update check found. The Settings header shows `message`.
enum UpdateCheckResult: Equatable {
    /// Checking is not wired up yet. Nothing was fetched.
    case notConfigured
    case upToDate
    case available(version: String, releaseURL: URL)
    case failed(String)

    var message: String {
        switch self {
        case .notConfigured: "Update checks aren't set up yet."
        case .upToDate: "Portside is up to date."
        case .available(let version, _): "Version \(version) is available."
        case .failed(let reason): "Couldn't check for updates: \(reason)"
        }
    }
}

/// Stub. Wiring it up means only filling in `check()`: fetch
/// `https://api.github.com/repos/<owner>/<repo>/releases/latest` for
/// `AppInfo.repoURL`, read `tag_name` and `html_url`, strip a leading "v",
/// and compare it with `AppInfo.version`. No network calls until then.
enum UpdateChecker {
    static func check() async -> UpdateCheckResult {
        .notConfigured
    }
}
