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

/// Another Portside.app on disk besides the running one.
struct InstalledCopy: Identifiable, Equatable {
    let url: URL
    let version: String
    var id: String { url.path }
}

/// Asks GitHub for the latest release of `AppInfo.repoURL`, compares its tag
/// with `AppInfo.version`, and can download the release DMG and replace the
/// running `.app` in place. One request per click; nothing runs in the background.
///
/// The GitHub repo is private, so checks and downloads need a token
/// (`GitHubAuth`: Portside keychain entry, or a logged-in `gh` CLI token).
///
/// Replacement: the new app is staged next to the installed one (same
/// volume), verified (bundle id, version, Developer ID team), then a helper
/// waits for Portside to quit and swaps the two with renames, rolling back if
/// the second rename fails. The path stays the same, so Open at Login and
/// pinned references keep working. dock.json lives in Application Support and
/// is never touched by the swap; it is copied to dock.json.before-update first.
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

    /// A verified new app staged next to the installed one.
    struct StagedUpdate {
        let app: URL
        let workDirectory: URL
        let version: String
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Portside/update.log")
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

    /// Other Portside.app copies Launch Services knows about (not the running
    /// one, not mounted disk images). An older copy here can be launched by
    /// Open at Login or Spotlight instead of the updated one.
    static func otherInstalledCopies() -> [InstalledCopy] {
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: AppInfo.bundleIdentifier)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { $0.path != running && !$0.path.hasPrefix("/Volumes/") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { InstalledCopy(url: $0, version: Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") }
            .sorted { $0.url.path < $1.url.path }
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

    /// Downloads `dmgURL`, stages and verifies the new app, backs up dock.json,
    /// then quits so the helper can swap the bundle and reopen it.
    /// Calls `onStatus` on the main actor with short progress strings.
    @MainActor
    static func downloadAndInstall(dmgURL: URL, version: String, onStatus: (String) -> Void) async throws {
        guard let destination = installedAppURL else {
            throw UpdateError.notInstalledApp
        }
        try checkWritable(destination)

        onStatus("Downloading…")
        updateLogger.info("downloading \(version, privacy: .public) from \(dmgURL.absoluteString, privacy: .public)")
        let downloaded = try await downloadDMG(from: dmgURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        onStatus("Installing…")
        let staged = try await Task.detached {
            try prepareUpdate(dmg: downloaded, expectedVersion: version, destination: destination)
        }.value

        do {
            try DockModel.backUpBeforeUpdate()
            try launchSwapHelper(staged, replacing: destination, relaunch: true)
        } catch {
            try? FileManager.default.removeItem(at: staged.workDirectory)
            throw error
        }
        onStatus("Restarting…")
        updateLogger.info("helper launched; quitting so \(destination.path, privacy: .public) can be replaced")
        NSApp.terminate(nil)
    }

    /// `portside --install-update <dmg> [--expect-version X.Y.Z] [--no-relaunch]`:
    /// the same stage, verify, back up, and swap path as Check for Updates,
    /// from a local DMG, for testing. The process exits right after starting
    /// the helper. Hidden; no UI.
    static func installFromCommandLine(arguments: [String], flagIndex: Int) -> Int32 {
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("portside: \(message)\n".utf8))
            return 1
        }
        guard flagIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: portside --install-update <dmg> [--expect-version X.Y.Z] [--no-relaunch]\n".utf8))
            return 2
        }
        let dmg = URL(fileURLWithPath: arguments[flagIndex + 1])
        var expected: String?
        if let i = arguments.firstIndex(of: "--expect-version"), i + 1 < arguments.count {
            expected = arguments[i + 1]
        }
        guard let destination = installedAppURL else {
            return fail(UpdateError.notInstalledApp.localizedDescription)
        }
        do {
            try checkWritable(destination)
            let staged = try prepareUpdate(dmg: dmg, expectedVersion: expected, destination: destination)
            try DockModel.backUpBeforeUpdate()
            try launchSwapHelper(staged, replacing: destination, relaunch: !arguments.contains("--no-relaunch"))
            print("Staged \(staged.version) at \(staged.app.path); helper will replace \(destination.path). Log: \(logURL.path)")
            return 0
        } catch {
            return fail(error.localizedDescription)
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

    /// Fails before any download if the swap could not happen.
    private static func checkWritable(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: destination.path) else {
            throw UpdateError.notWritable(parent.path)
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

    /// Mounts the DMG, copies Portside.app into a hidden work folder beside
    /// `destination` (same volume, so the swap is two renames), and verifies it.
    /// Nothing at `destination` changes. On any failure the work folder is removed.
    private static func prepareUpdate(dmg: URL, expectedVersion: String?, destination: URL) throws -> StagedUpdate {
        let work = destination.deletingLastPathComponent()
            .appendingPathComponent(".portside-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortsideUpdateMount-\(UUID().uuidString)", isDirectory: true)
        var mounted = false
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            mounted = true

            let mountedApp = mount.appendingPathComponent("Portside.app")
            guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                throw UpdateError.dmgMissingApp
            }
            let staged = work.appendingPathComponent("Portside.app")
            try run("/usr/bin/ditto", [mountedApp.path, staged.path])
            try? detach(mount)
            mounted = false
            try? FileManager.default.removeItem(at: mount)

            let version = try verify(staged, expectedVersion: expectedVersion)
            log("staged \(version) at \(staged.path)")
            return StagedUpdate(app: staged, workDirectory: work, version: version)
        } catch {
            if mounted { try? detach(mount) }
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: work)
            log("prepare failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Bundle id, version, and a valid Developer ID signature from the release team.
    private static func verify(_ app: URL, expectedVersion: String?) throws -> String {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == AppInfo.bundleIdentifier else {
            throw UpdateError.verificationFailed("the download is not Portside (bundle id mismatch).")
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if let expectedVersion, version != expectedVersion {
            throw UpdateError.verificationFailed("expected version \(expectedVersion), the download is \(version.isEmpty ? "unversioned" : version).")
        }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(AppInfo.releaseTeamID)\""
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path])
        } catch {
            throw UpdateError.verificationFailed("the signature is not a valid Portside release signature.")
        }
        return version
    }

    /// Writes and starts a helper that waits for `pid` to exit (up to 60s),
    /// then renames the installed app aside, renames the staged app into
    /// place, and removes the old one. If the second rename fails the old app
    /// is put back. Every step goes to `logURL`.
    private static func launchSwapHelper(_ staged: StagedUpdate, replacing destination: URL, relaunch: Bool) throws {
        let script = staged.workDirectory.appendingPathComponent("swap.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let body = """
        #!/bin/bash
        set -u
        APP_PID=\(pid)
        SRC=\(shellEscape(staged.app.path))
        DEST=\(shellEscape(destination.path))
        WORK=\(shellEscape(staged.workDirectory.path))
        OLD="$WORK/Portside-previous.app"
        LOG=\(shellEscape(logURL.path))
        RELAUNCH=\(relaunch ? 1 : 0)
        mkdir -p "$(dirname "$LOG")"
        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [swap] $*" >> "$LOG"; }
        reopen() { [ "$RELAUNCH" = 1 ] && /usr/bin/open "$DEST"; }

        log "waiting for pid $APP_PID to quit"
        for _ in $(seq 1 300); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
        if kill -0 "$APP_PID" 2>/dev/null; then
            log "still running after 60s; update cancelled, nothing changed"
            rm -rf "$WORK"
            exit 1
        fi
        if ! mv "$DEST" "$OLD"; then
            log "could not move $DEST aside; update cancelled, nothing changed"
            rm -rf "$WORK"
            reopen
            exit 1
        fi
        if ! mv "$SRC" "$DEST"; then
            log "could not move the new app into place; restoring the previous app"
            if mv "$OLD" "$DEST"; then
                chflags -R nouchg "$WORK" 2>/dev/null
                rm -rf "$WORK"
            else
                log "RESTORE FAILED: previous app left at $OLD"
            fi
            reopen
            exit 1
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
        log "installed \(staged.version) at $DEST"
        rm -rf "$WORK"
        reopen
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        log("helper started for \(destination.path) (pid \(pid))")
    }

    private static func detach(_ mount: URL) throws {
        try run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
    }

    private static func log(_ message: String) {
        updateLogger.info("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [app \(AppInfo.version)] \(message)\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// stdout and stderr share one pipe, read before waiting, so a chatty
    /// tool can't fill the pipe and block.
    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            updateLogger.error("\(executable, privacy: .public) failed (\(process.terminationStatus)): \(detail, privacy: .public)")
            throw UpdateError.commandFailed(executable, detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
        return output
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum UpdateError: LocalizedError {
    case notInstalledApp
    case notWritable(String)
    case dmgMissingApp
    case authRequired
    case verificationFailed(String)
    case downloadFailed(Int)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .notInstalledApp:
            "this build isn't an installed Portside.app (use the .app from a release or build-app.sh)."
        case .notWritable(let folder):
            "Portside can't write to \(folder). Move Portside.app to ~/Applications, or update from the release page."
        case .dmgMissingApp:
            "the download didn't contain Portside.app."
        case .authRequired:
            "a GitHub token is required to download from this private repo."
        case .verificationFailed(let reason):
            reason
        case .downloadFailed(let code):
            "download failed (HTTP \(code))."
        case .commandFailed(_, let detail):
            detail
        }
    }
}
