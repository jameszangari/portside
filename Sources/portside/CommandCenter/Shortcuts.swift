import Foundation

/// One Apple Shortcut as `shortcuts list --show-identifiers` reports it.
struct ShortcutInfo: Equatable, Identifiable, Sendable {
    static let nameLimit = 200
    static let listLimit = 500

    let id: UUID
    let name: String
}

/// Reads the output of `shortcuts list --show-identifiers`: one
/// `Name (UUID)` per line. A line that does not end in a UUID, an empty
/// name or a repeated UUID is skipped alone.
enum ShortcutListParser {
    static func parse(_ data: Data) -> [ShortcutInfo] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var seen = Set<UUID>()
        var found: [ShortcutInfo] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard found.count < ShortcutInfo.listLimit, line.hasSuffix(")"), let open = line.lastIndex(of: "("),
                  let id = UUID(uuidString: String(line[line.index(after: open)..<line.index(before: line.endIndex)])) else { continue }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(id).inserted else { continue }
            found.append(ShortcutInfo(id: id, name: String(name.prefix(ShortcutInfo.nameLimit))))
        }
        return found.sorted { lhs, rhs in
            let left = lhs.name.lowercased(), right = rhs.name.lowercased()
            return left == right ? lhs.id.uuidString < rhs.id.uuidString : left < right
        }
    }
}

/// The exact `shortcuts` commands. Absolute path, argument arrays, no shell,
/// nothing inherited but `LC_ALL`. A shortcut runs by its identifier from a
/// list this app read, never by typed text, and gets no input and no output
/// path.
enum ShortcutsInvocation {
    static let executablePath = "/usr/bin/shortcuts"

    static func list() -> LsofInvocation { make(["list", "--show-identifiers"]) }

    static func run(_ id: UUID) -> LsofInvocation { make(["run", id.uuidString]) }

    private static func make(_ arguments: [String]) -> LsofInvocation {
        LsofInvocation(executableURL: URL(fileURLWithPath: executablePath), arguments: arguments, environment: ["LC_ALL": "C"])
    }

    static let listLimits = LsofLimits(deadline: .seconds(5), killGrace: .milliseconds(500), stdoutCap: 1 << 20, stderrCap: 16 << 10)
    /// A shortcut may wait on its own dialogs, so the wait is long but bounded.
    static let runLimits = LsofLimits(deadline: .seconds(60), killGrace: .seconds(2), stdoutCap: 64 << 10, stderrCap: 16 << 10)
}

/// Runs one child. The live one is `LsofRunner`, the same bounded runner
/// Local Servers uses (deadline, byte caps, SIGTERM then SIGKILL, cancel
/// stops the child); tests inject a fake.
typealias ShortcutsProcessRunner = @Sendable (LsofInvocation, LsofLimits) async -> LsofRun

/// Apple Shortcuts discovery and explicit runs (P2-CMD-07). Listing happens
/// when Command Center opens (at most every 30 s); a run happens only when a
/// person picks that shortcut's row. Nothing runs from a search, a model or
/// a timer, one run at a time, and an ID that was not listed is refused.
@MainActor
final class ShortcutsService {
    enum Message {
        static let missing = "Shortcuts is not available on this Mac."
        static let off = "Shortcuts is turned off."
        static let busy = "Another shortcut is still running."
        static let gone = "That shortcut is no longer in your list."
    }

    nonisolated static let refreshInterval: TimeInterval = 30

    private(set) var shortcuts: [ShortcutInfo] = []
    /// The `shortcuts` module runs.
    private(set) var isActive = false
    /// Why the last listing failed, nil when it worked or has not run.
    private(set) var listFailure: String?
    private(set) var running: UUID?
    private var loading = false
    private var lastRefresh: Date?
    private var generation = 0
    private let runner: ShortcutsProcessRunner
    private let exists: @Sendable () -> Bool

    nonisolated init(
        runner: @escaping ShortcutsProcessRunner = { await LsofRunner.run($0, limits: $1) },
        exists: @escaping @Sendable () -> Bool = { FileManager.default.isExecutableFile(atPath: ShortcutsInvocation.executablePath) }
    ) {
        self.runner = runner
        self.exists = exists
    }

    /// nil when shortcuts can be listed and run now.
    var unavailableReason: String? {
        if !isActive { return Message.off }
        if !exists() { return Message.missing }
        return nil
    }

    /// What Command Center lists: nothing while off or without Shortcuts.
    var rows: [ShortcutInfo] { unavailableReason == nil ? shortcuts : [] }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        generation += 1
        shortcuts = []
        listFailure = nil
        lastRefresh = nil
        loading = false
    }

    /// Background listing; `changed` runs when the list differs. Skipped
    /// while one runs, within the interval, or when unavailable.
    func refresh(now: Date = Date(), changed: @escaping @MainActor () -> Void) {
        guard unavailableReason == nil, !loading else { return }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        loading = true
        generation += 1
        let mine = generation
        let runner = runner
        Task { [weak self] in
            let result = await runner(ShortcutsInvocation.list(), ShortcutsInvocation.listLimits)
            self?.finishListing(result, generation: mine, now: now, changed: changed)
        }
    }

    private func finishListing(_ run: LsofRun, generation mine: Int, now: Date, changed: @MainActor () -> Void) {
        guard mine == generation, isActive else { return }
        loading = false
        lastRefresh = now
        guard case .exited(0) = run.termination, !run.stdoutTruncated else {
            // Keep the last good list; say why this one failed.
            listFailure = "Shortcuts could not list your shortcuts."
            return
        }
        listFailure = nil
        let found = ShortcutListParser.parse(run.stdout)
        guard found != shortcuts else { return }
        shortcuts = found
        changed()
    }

    /// Runs one listed shortcut and waits for it, bounded. Cancel stops the
    /// `shortcuts` child; macOS may let a shortcut that already started finish.
    func run(_ id: UUID) async -> Result<String?, CommandFailure> {
        if let reason = unavailableReason { return .failure(CommandFailure(reason: reason)) }
        guard let shortcut = shortcuts.first(where: { $0.id == id }) else { return .failure(CommandFailure(reason: Message.gone)) }
        guard running == nil else { return .failure(CommandFailure(reason: Message.busy)) }
        running = id
        defer { running = nil }
        let result = await runner(ShortcutsInvocation.run(id), ShortcutsInvocation.runLimits)
        switch result.termination {
        case .exited(0):
            return .success("Ran \(shortcut.name).")
        case .exited(let status):
            return .failure(CommandFailure(reason: "\(shortcut.name) did not finish (status \(status))."))
        case .signaled:
            return .failure(CommandFailure(reason: "\(shortcut.name) was stopped."))
        case .timedOut:
            return .failure(CommandFailure(reason: "\(shortcut.name) did not finish in 60 seconds. Portside stopped waiting; Shortcuts may still be running it."))
        case .launchFailed:
            return .failure(CommandFailure(reason: Message.missing))
        case .canceled:
            return .failure(CommandFailure(reason: "\(shortcut.name) was canceled. Shortcuts may still finish it."))
        }
    }
}

/// The optional `shortcuts` module. Off by default and held off by
/// restricted mode (a shortcut can do anything the person built it to do).
/// It lists on open and runs only what is picked. Without the `shortcuts`
/// tool it fails to start with a reason and Command Center works unchanged.
@MainActor
final class ShortcutsModule: PortsideModule {
    static let moduleID = ModuleID("shortcuts")!
    static let runCommand = CommandID("shortcuts.run")!

    struct Unavailable: LocalizedError {
        var errorDescription: String? { ShortcutsService.Message.missing }
    }

    let id = ShortcutsModule.moduleID
    let title = "Shortcuts"
    let summary = "Lists your Apple Shortcuts in Command Center and runs one when you pick it (Return). Portside runs only the shortcut you choose, by its identifier, with no input, and never from a search. A run waits at most 60 seconds, and Esc stops waiting. Uses the shortcuts tool that comes with macOS."
    let fallback = "Command Center and the dock work the same without it; Shortcuts still runs from its own app."
    let dependencies: [ModuleDependency] = [.module(CommandCenterModule.moduleID)]

    let service: ShortcutsService

    init(service: ShortcutsService) {
        self.service = service
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.runCommand,
                title: "Run Shortcut",
                keywords: ["automation"],
                symbolName: "bolt.fill",
                input: .string(maxLength: 36),
                unavailableReason: { [service] in service.unavailableReason },
                handler: { [service] input in
                    // The ID of a listed shortcut, never a name or text.
                    guard case .string(let raw) = input, let id = UUID(uuidString: raw) else {
                        return .failure(CommandFailure(reason: "No shortcut given."))
                    }
                    return await service.run(id)
                }
            ),
        ]
    }

    func start(_ context: ModuleContext) throws {
        service.activate()
        guard service.unavailableReason == nil else {
            service.deactivate()
            throw Unavailable()
        }
        context.onStop { [service] in
            MainActor.assumeIsolated { service.deactivate() }
        }
    }
}
