import AppKit
import Foundation
import os.log

private let updateLogger = Logger(subsystem: "com.james.portside", category: "Update")

/// What an update check found. The Settings sidebar shows `message`.
enum UpdateCheckResult: Equatable {
    /// Repo URL couldn't be turned into an API URL.
    case notConfigured
    case upToDate
    /// `dmgURL` is the GitHub asset to install when present (API asset URL when private).
    case available(version: String, releaseURL: URL, dmgURL: URL?)
    case failed(String)

    var message: String {
        switch self {
        case .notConfigured: "Update checks aren't set up yet."
        case .upToDate: "Portside is up to date."
        case .available(let version, _, _): "Version \(version) is available."
        case .failed(let reason): "Couldn't check for updates: \(reason)"
        }
    }
}

/// Asks GitHub for the latest release of `AppInfo.repoURL`, compares its tag
/// with `AppInfo.version`, and can download the release DMG and replace the
/// running `.app` in place. One request per click; nothing runs in the background.
///
/// The GitHub repo is private, so checks and downloads need a token
/// (`GitHubAuth`: Portside keychain entry, or a logged-in `gh` CLI token).
enum UpdateChecker {
    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            /// API URL; required for private-repo downloads (with a Bearer token).
            let url: URL
            let browser_download_url: URL
        }
    }

    /// True when this process is running from a `Portside.app` bundle we can replace.
    static var canInstallInPlace: Bool {
        installedAppURL != nil
    }

    /// `Bundle.main.bundleURL` when it is an `.app`, else nil (`swift run`, etc.).
    static var installedAppURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        return url
    }

    static func check() async -> UpdateCheckResult {
        let parts = AppInfo.repoURL.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2,
              let api = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest") else {
            return .notConfigured
        }
        let token = GitHubAuth.token()
        var request = URLRequest(url: api, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Portside/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed(httpFailure(http.statusCode, authenticated: token != nil))
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard isNewer(latest, than: AppInfo.version) else { return .upToDate }
            let asset = release.assets.first { $0.name == "Portside-\(latest).dmg" }
                ?? release.assets.first { $0.name.hasPrefix("Portside-") && $0.name.hasSuffix(".dmg") }
            // Private repos need the API asset URL + token; public can use either.
            let dmgURL: URL? = {
                guard let asset else { return nil }
                return token != nil ? asset.url : asset.browser_download_url
            }()
            return .available(version: latest, releaseURL: release.html_url, dmgURL: dmgURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Downloads `dmgURL`, stages `Portside.app`, verifies the signature, then
    /// quits so a helper can swap the installed bundle and reopen it.
    /// Calls `onStatus` on the main actor with short progress strings.
    @MainActor
    static func downloadAndInstall(dmgURL: URL, onStatus: (String) -> Void) async throws {
        guard let destination = installedAppURL else {
            throw UpdateError.notInstalledApp
        }

        onStatus("Downloading…")
        updateLogger.info("downloading update from \(dmgURL.absoluteString, privacy: .public)")
        let downloaded = try await downloadDMG(from: dmgURL)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortsideUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var mountPoint: URL?
        do {
            onStatus("Installing…")
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", downloaded.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            mountPoint = mount

            let mountedApp = mount.appendingPathComponent("Portside.app")
            guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                throw UpdateError.dmgMissingApp
            }

            let staged = work.appendingPathComponent("Portside.app")
            try run("/usr/bin/ditto", [mountedApp.path, staged.path])
            // Downloads pick up quarantine; clear it on the staged copy before verify/open.
            _ = try? run("/usr/bin/xattr", ["-cr", staged.path])
            try run("/usr/bin/codesign", ["--verify", "--verbose=2", staged.path])

            try detachMount(mount)
            mountPoint = nil
            try? FileManager.default.removeItem(at: downloaded)

            onStatus("Restarting…")
            try launchReplacementHelper(stagingApp: staged, replacing: destination, workDirectory: work)
            updateLogger.info("helper launched; terminating for replacement at \(destination.path, privacy: .public)")
            NSApp.terminate(nil)
        } catch {
            if let mountPoint { try? detachMount(mountPoint) }
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: downloaded)
            throw error
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

    // MARK: - Private

    private static func httpFailure(_ code: Int, authenticated: Bool) -> String {
        switch code {
        case 401, 403:
            return "GitHub auth failed. Check the token in Settings > General."
        case 404:
            if authenticated {
                return "no releases published yet."
            }
            return "the GitHub repo is private (or has no releases). Add a token in Settings > General, or sign in with the GitHub CLI (gh auth login)."
        default:
            return "GitHub returned \(code)."
        }
    }

    private static func downloadDMG(from url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Portside/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        // API asset URLs need octet-stream + Bearer; browser URLs are fine with either.
        let isAPIAsset = url.host == "api.github.com"
        if isAPIAsset {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        }
        if let token = GitHubAuth.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if isAPIAsset {
            throw UpdateError.authRequired
        }
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.downloadFailed(http.statusCode)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Portside-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func launchReplacementHelper(stagingApp: URL, replacing destination: URL, workDirectory: URL) throws {
        let script = workDirectory.appendingPathComponent("replace.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        // Wait for this process to exit, then swap the .app and reopen.
        let body = """
        #!/bin/bash
        set -euo pipefail
        APP_PID=\(pid)
        SRC=\(shellEscape(stagingApp.path))
        DEST=\(shellEscape(destination.path))
        WORK=\(shellEscape(workDirectory.path))
        while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
        sleep 0.3
        rm -rf "$DEST"
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/xattr -cr "$DEST" >/dev/null 2>&1 || true
        /usr/bin/open "$DEST"
        rm -rf "$WORK"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func detachMount(_ mount: URL) throws {
        try run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            updateLogger.error("\(executable, privacy: .public) failed (\(process.terminationStatus)): \(detail, privacy: .public)")
            throw UpdateError.commandFailed(executable, detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
        return stdout
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum UpdateError: LocalizedError {
    case notInstalledApp
    case dmgMissingApp
    case authRequired
    case downloadFailed(Int)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .notInstalledApp:
            "this build isn't an installed Portside.app (use the .app from a release or build-app.sh)."
        case .dmgMissingApp:
            "the download didn't contain Portside.app."
        case .authRequired:
            "a GitHub token is required to download from this private repo."
        case .downloadFailed(let code):
            "download failed (HTTP \(code))."
        case .commandFailed(_, let detail):
            detail
        }
    }
}
