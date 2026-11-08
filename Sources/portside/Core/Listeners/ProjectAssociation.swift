import Darwin
import Foundation

/// Which project a listener belongs to. The working directory is a verified
/// libproc fact; the project is only inferred from a Git marker above it.
enum ProjectAssociation: Equatable, Sendable {
    /// The nearest ancestor of the working directory (itself included) that
    /// holds a `.git` directory or file. An inference, never proof that the
    /// process was started from that project's tooling.
    case inferred(root: String)
    /// The working directory was read but no marker sits within the bounds.
    case notFound
    /// A marker exists only at the home folder or `/`, which names no project.
    case ambiguous
    /// The working directory could not be read, so nothing can be said.
    case unavailable(UnknownReason)

    var root: String? {
        if case .inferred(let root) = self { return root }
        return nil
    }

    /// The folder name of the root.
    var name: String? { root.map { ($0 as NSString).lastPathComponent } }
}

/// Bounded, stat-only project lookup: at most `maxLevels` ancestors, one
/// `lstat` each. No directory listing, no file reads, no shell, no symlink
/// following (a symlinked marker is ignored).
enum ProjectLocator {
    static let maxLevels = 24

    static func locate(
        workingDirectory: String,
        homes: Set<String> = defaultHomes()
    ) -> ProjectAssociation {
        guard workingDirectory.hasPrefix("/"), isDirectory(workingDirectory) else {
            return .unavailable(.failed(ENOENT))
        }
        var directory = workingDirectory
        var ambiguous = false
        for _ in 0..<maxLevels {
            if hasMarker(in: directory) {
                if directory == "/" || homes.contains(directory) { ambiguous = true } else { return .inferred(root: directory) }
            }
            if directory == "/" { break }
            directory = (directory as NSString).deletingLastPathComponent
            if directory.isEmpty { directory = "/" }
        }
        return ambiguous ? .ambiguous : .notFound
    }

    static func defaultHomes() -> Set<String> {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return [] }
        return [home, (home as NSString).resolvingSymlinksInPath]
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func hasMarker(in directory: String) -> Bool {
        var info = stat()
        let marker = (directory as NSString).appendingPathComponent(".git")
        guard lstat(marker, &info) == 0 else { return false }
        let kind = info.st_mode & S_IFMT
        return kind == S_IFDIR || kind == S_IFREG
    }
}
