import Darwin
import Foundation

/// One file or folder in a chosen root, as the index keeps it. Names and
/// paths only: no contents, no metadata beyond folder or not.
struct FileEntry: Equatable, Sendable {
    let path: String
    let name: String
    /// `name` folded for search (case and diacritics).
    let key: String
    let isDirectory: Bool
    let rootID: UUID

    init(path: String, name: String, isDirectory: Bool, rootID: UUID) {
        self.path = path
        self.name = name
        self.key = CommandCenterRanker.normalize(name)
        self.isDirectory = isDirectory
        self.rootID = rootID
    }

    /// `~/Documents/Notes` for a path under the home folder.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// A folder the person chose to search (`command-center-file-roots.json`).
struct FileRoot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// Standardized, symlinks resolved, absolute.
    var path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

/// Which folders may be searched. Only an explicit, specific folder: never
/// the disk, a top-level system folder or the whole home folder.
enum FileRootRules {
    static let limit = 10

    enum Problem: Error, Equatable {
        case notAbsolute
        case notAFolder
        case tooBroad
        case duplicate
        case insideExisting(String)
        case containsExisting(String)
        case limit

        var message: String {
            switch self {
            case .notAbsolute: return "Choose a folder."
            case .notAFolder: return "That is not a folder Portside can read."
            case .tooBroad: return "Choose a specific folder, not the whole disk, a system folder, a volume or your home folder."
            case .duplicate: return "That folder is already searched."
            case .insideExisting(let path): return "It is already inside \(path)."
            case .containsExisting(let path): return "It contains \(path), which is already searched. Remove that first."
            case .limit: return "At most \(FileRootRules.limit) folders can be searched."
            }
        }
    }

    /// The path to store, or why not. `existing` are the current roots' paths.
    static func validate(_ path: String, existing: [String], home: String = NSHomeDirectory()) -> Result<String, Problem> {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .failure(.notAbsolute) }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.notAFolder)
        }
        guard !isTooBroad(resolved, home: home) else { return .failure(.tooBroad) }
        guard existing.count < limit else { return .failure(.limit) }
        if existing.contains(resolved) { return .failure(.duplicate) }
        if let parent = existing.first(where: { resolved.hasPrefix($0 + "/") }) { return .failure(.insideExisting(FileEntry.abbreviated(parent, home: home))) }
        if let child = existing.first(where: { $0.hasPrefix(resolved + "/") }) { return .failure(.containsExisting(FileEntry.abbreviated(child, home: home))) }
        return .success(resolved)
    }

    static func isTooBroad(_ resolved: String, home: String) -> Bool {
        let components = resolved.split(separator: "/")
        if components.count <= 1 { return true }
        let homeResolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        if resolved == home || resolved == homeResolved { return true }
        // A mounted volume's top folder is a whole disk.
        if components.count == 2, components[0] == "Volumes" { return true }
        return ["/System", "/private", "/dev", "/cores", "/usr", "/bin", "/sbin"].contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }
}

/// Decides whether one path may be opened or revealed, right before it
/// happens, whatever the index said: still under a current root, not a
/// symlink, and not reaching outside through a symlinked parent.
enum FileAccess {
    enum Denial: Error, Equatable {
        case badPath
        case outsideRoots
        case missing
        case symlink
        case escapes

        var message: String {
            switch self {
            case .badPath: return "That is not a valid file path."
            case .outsideRoots: return "That file is not inside a folder you chose."
            case .missing: return "That file is no longer there."
            case .symlink: return "That is a symbolic link, which Portside does not follow."
            case .escapes: return "That file resolves outside the folder you chose."
            }
        }
    }

    static func authorize(_ path: String, roots: [String]) -> Result<URL, Denial> {
        guard path.hasPrefix("/"), !path.contains("\0"), path.count <= 4096,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return .failure(.badPath) }
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return .failure(.outsideRoots) }
        var info = stat()
        guard lstat(path, &info) == 0 else { return .failure(.missing) }
        if (info.st_mode & S_IFMT) == S_IFLNK { return .failure(.symlink) }
        guard let real = realPath(path), let realRoot = realPath(root), real.hasPrefix(realRoot + "/") else {
            return .failure(.escapes)
        }
        return .success(URL(fileURLWithPath: path))
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Scanner

struct FileScanLimits: Sendable {
    var maxEntries = 50_000
    var maxDepth = 12
    var deadline: TimeInterval = 10
    /// Folders never entered: build output and package stores no one searches by name.
    var skippedFolders: Set<String> = ["node_modules", "__pycache__", "DerivedData", "Pods", "Carthage"]
}

enum FileScanOutcome: Equatable, Sendable {
    case complete
    /// Stopped at a limit; what was found is kept.
    case truncated
    /// The root is gone, or is now a symlink or a different place.
    case missing
    case unreadable
    case canceled
}

struct FileScanResult: Sendable {
    var entries: [FileEntry]
    var outcome: FileScanOutcome
}

/// A bounded, breadth first walk of one root. Never follows a symlink (a
/// link is not listed and not entered), skips hidden files and the insides
/// of packages, and stops at the entry, depth and time limits.
enum FileScanner {
    static func scan(root: FileRoot, limits: FileScanLimits = FileScanLimits(), isCancelled: () -> Bool = { false }) -> FileScanResult {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path == root.path else {
            return FileScanResult(entries: [], outcome: .missing)
        }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey]
        var entries: [FileEntry] = []
        var queue: [(path: String, depth: Int)] = [(root.path, 0)]
        var head = 0
        var outcome = FileScanOutcome.complete
        let start = Date()
        var rootRead = false
        while head < queue.count {
            if isCancelled() { return FileScanResult(entries: [], outcome: .canceled) }
            if Date().timeIntervalSince(start) > limits.deadline {
                outcome = .truncated
                break
            }
            let (folder, depth) = queue[head]
            head += 1
            guard let children = try? files.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else {
                if !rootRead { return FileScanResult(entries: [], outcome: .unreadable) }
                continue
            }
            rootRead = true
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                let isFolder = values?.isDirectory == true
                if entries.count >= limits.maxEntries {
                    outcome = .truncated
                    break
                }
                let name = child.lastPathComponent
                // Built from the folder, not `child.path`, which may come back with a /private prefix.
                let path = folder + "/" + name
                entries.append(FileEntry(path: path, name: name, isDirectory: isFolder, rootID: root.id))
                if isFolder, values?.isPackage != true, depth < limits.maxDepth, !limits.skippedFolders.contains(name) {
                    queue.append((path, depth + 1))
                } else if isFolder, values?.isPackage != true, depth >= limits.maxDepth {
                    outcome = .truncated
                }
            }
            if outcome == .truncated, entries.count >= limits.maxEntries { break }
        }
        return FileScanResult(entries: entries, outcome: outcome)
    }
}

// MARK: - Search

enum FileSearch {
    static let resultLimit = 8
    static let minimumTerms = 1
    /// Fewer letters match too much to be useful.
    static let minimumCharacters = 2

    /// Entries whose folded name contains every term, best first: the whole
    /// name, then a name that starts with the text, then a word start, then
    /// anywhere; shorter names, then path. Deterministic.
    static func search(_ entries: [FileEntry], query: String, limit: Int = resultLimit) -> [FileEntry] {
        let terms = CommandCenterRanker.terms(query)
        guard !terms.isEmpty, terms.joined().count >= minimumCharacters else { return [] }
        let joined = terms.joined(separator: " ")
        var scored: [(rank: Int, entry: FileEntry)] = []
        for entry in entries where terms.allSatisfy(entry.key.contains) {
            let words = CommandCenterRanker.words(entry.key)
            let rank: Int
            if words.joined(separator: " ") == joined { rank = 0 }
            else if words.joined(separator: " ").hasPrefix(joined) { rank = 1 }
            else if terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) { rank = 2 }
            else { rank = 3 }
            scored.append((rank, entry))
        }
        scored.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.entry.name.count != rhs.entry.name.count { return lhs.entry.name.count < rhs.entry.name.count }
            return lhs.entry.path < rhs.entry.path
        }
        return scored.prefix(limit).map(\.entry)
    }
}
