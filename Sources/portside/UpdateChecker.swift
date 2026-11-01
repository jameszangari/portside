import Foundation

/// What an update check found. The Settings header shows `message`.
enum UpdateCheckResult: Equatable {
    /// Repo URL couldn't be turned into an API URL.
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

/// Asks GitHub for the latest release of `AppInfo.repoURL` and compares its
/// tag with `AppInfo.version`. One request per click; nothing runs in the background.
enum UpdateChecker {
    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    static func check() async -> UpdateCheckResult {
        let parts = AppInfo.repoURL.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2,
              let api = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest") else {
            return .notConfigured
        }
        var request = URLRequest(url: api, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Portside/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed(http.statusCode == 404 ? "no releases published yet." : "GitHub returned \(http.statusCode).")
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            return isNewer(latest, than: AppInfo.version)
                ? .available(version: latest, releaseURL: release.html_url)
                : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Numeric dotted compare ("0.10.0" > "0.9.1"); ignores any "-suffix".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func nums(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = nums(a), y = nums(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
