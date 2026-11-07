import Foundation

/// A module's stable identifier, also the namespace of its commands
/// (`portside` owns `portside.openSettings`). Same character rules as one
/// part of a `CommandID`.
struct ModuleID: Hashable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String) {
        guard CommandID.isValidPart(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// Something a module needs before it may start. Permissions are read from
/// the `PermissionGate` (observed, never requested); a module dependency is
/// ready only while that module is running.
enum ModuleDependency: Hashable {
    case permission(PermissionScope)
    case module(ModuleID)
}

enum ModuleState: Equatable {
    case disabled
    /// Enabled, but a dependency is not ready. Starts on a later `refresh`.
    case waiting(String)
    case running
    /// `start` threw. Stays failed until disabled and enabled again.
    case failed(String)
}

/// One optional feature. `start` and `stop` run on the main actor, each at
/// most once per activation. Anything long-lived goes through the context,
/// so turning the module off cancels and releases it even if `stop` forgets.
@MainActor
protocol PortsideModule: AnyObject {
    var id: ModuleID { get }
    var title: String { get }
    var dependencies: [ModuleDependency] { get }
    /// Commands in this module's namespace. Registered once with the module
    /// and unavailable whenever it is not running.
    func commands() -> [CommandDescriptor]
    func start(_ context: ModuleContext) throws
    func stop()
}

extension PortsideModule {
    var dependencies: [ModuleDependency] { [] }
    func commands() -> [CommandDescriptor] { [] }
    func stop() {}
}

/// The resources of one activation. Closing it cancels every tracked task
/// and runs cleanups in reverse order, once. A closed context refuses new work.
@MainActor
final class ModuleContext {
    private var tasks: [Int: () -> Void] = [:]
    private var cleanups: [() -> Void] = []
    private var nextKey = 0
    private(set) var isActive = true

    /// Open tasks plus pending cleanups; zero after close.
    var resourceCount: Int { tasks.count + cleanups.count }

    /// Runs `operation` until it finishes or the module stops. nil when the
    /// context is already closed.
    @discardableResult
    func task<T>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never>? {
        guard isActive else { return nil }
        let key = nextKey
        nextKey += 1
        // The body is enqueued, so the entry exists before it can remove itself.
        let task = Task { @MainActor [weak self] in
            let value = await operation()
            self?.tasks[key] = nil
            return value
        }
        tasks[key] = { task.cancel() }
        return task
    }

    /// Releases an observer, subscription or handle when the module stops.
    /// Runs immediately when the context is already closed.
    func onStop(_ cleanup: @escaping () -> Void) {
        guard isActive else { return cleanup() }
        cleanups.append(cleanup)
    }

    fileprivate func close() {
        guard isActive else { return }
        isActive = false
        let open = tasks.values
        tasks.removeAll()
        open.forEach { $0() }
        let pending = cleanups
        cleanups.removeAll()
        pending.reversed().forEach { $0() }
    }
}

enum ModuleRegistryError: Error, Equatable {
    case duplicateModule(ModuleID)
    case commandOutsideNamespace(CommandID)
    case duplicateCommand(CommandID)
}

/// Owns which modules are enabled, whether their dependencies are ready, and
/// their start/stop. Event driven: state changes only on `enable`, `disable`,
/// `refresh` and `stopAll`; nothing polls. A module that fails to start is
/// marked failed and leaves the Dock and other modules alone. Main actor only.
@MainActor
final class ModuleRegistry {
    private final class Entry {
        let module: any PortsideModule
        var enabled = false
        var state = ModuleState.disabled
        var context: ModuleContext?
        init(_ module: any PortsideModule) { self.module = module }
    }

    private var entries: [ModuleID: Entry] = [:]
    private var order: [ModuleID] = []
    private let commands: CommandRegistry
    private let permissions: PermissionGate
    private var reconciling = false
    private var needsReconcile = false

    nonisolated init(commands: CommandRegistry, permissions: PermissionGate) {
        self.commands = commands
        self.permissions = permissions
    }

    /// Adds a module, off, and registers its commands. Nothing starts and no
    /// permission is read. All-or-nothing: on error nothing is registered.
    func register(_ module: any PortsideModule) throws {
        guard entries[module.id] == nil else { throw ModuleRegistryError.duplicateModule(module.id) }
        let provided = module.commands()
        var seen = Set<CommandID>()
        for descriptor in provided {
            guard descriptor.id.namespace == module.id.rawValue else {
                throw ModuleRegistryError.commandOutsideNamespace(descriptor.id)
            }
            guard seen.insert(descriptor.id).inserted, commands.descriptor(for: descriptor.id) == nil else {
                throw ModuleRegistryError.duplicateCommand(descriptor.id)
            }
        }
        entries[module.id] = Entry(module)
        order.append(module.id)
        for descriptor in provided {
            try commands.register(gated(descriptor, by: module.id, title: module.title))
        }
    }

    func state(of id: ModuleID) -> ModuleState? { entries[id]?.state }

    func isEnabled(_ id: ModuleID) -> Bool { entries[id]?.enabled ?? false }

    /// Resources held by the running activation; zero when not running.
    func resourceCount(of id: ModuleID) -> Int { entries[id]?.context?.resourceCount ?? 0 }

    /// Idempotent. Starts the module now if its dependencies are ready.
    @discardableResult
    func enable(_ id: ModuleID) -> ModuleState? {
        guard let entry = entries[id] else { return nil }
        if !entry.enabled {
            entry.enabled = true
            reconcile()
        }
        return entry.state
    }

    /// Idempotent. Stops the module and anything that depends on it.
    @discardableResult
    func disable(_ id: ModuleID) -> ModuleState? {
        guard let entry = entries[id] else { return nil }
        if entry.enabled {
            entry.enabled = false
            reconcile()
        }
        return entry.state
    }

    /// Re-reads dependencies after an outside change (a permission granted
    /// or revoked). Starts waiting modules and stops ones that lost a dependency.
    func refresh() { reconcile() }

    /// Quit path: stops everything, dependents first, without changing enabled flags.
    func stopAll() {
        for id in order.reversed() where entries[id]?.state == .running {
            stop(id, then: entries[id]?.enabled == true ? .waiting("Portside is quitting.") : .disabled)
        }
    }

    // MARK: Lifecycle

    /// Runs until stable. A call made from inside `start` or `stop` is folded
    /// into the current pass instead of recursing.
    private func reconcile() {
        if reconciling { needsReconcile = true; return }
        reconciling = true
        defer { reconciling = false }
        var passes = 0
        repeat {
            needsReconcile = false
            passes += 1
            var changed = false
            for id in order {
                guard let entry = entries[id] else { continue }
                let before = entry.state
                step(id, entry)
                if entry.state != before { changed = true }
            }
            if changed { needsReconcile = true }
        } while needsReconcile && passes <= order.count + 1
    }

    private func step(_ id: ModuleID, _ entry: Entry) {
        let unmet = entry.enabled ? unmetDependency(of: entry.module) : nil
        switch entry.state {
        case .running:
            if !entry.enabled { stop(id, then: .disabled) }
            else if let unmet { stop(id, then: .waiting(unmet)) }
        case .failed:
            if !entry.enabled { entry.state = .disabled }
        case .disabled, .waiting:
            if !entry.enabled { entry.state = .disabled }
            else if let unmet { entry.state = .waiting(unmet) }
            else { start(entry) }
        }
    }

    private func start(_ entry: Entry) {
        let context = ModuleContext()
        do {
            try entry.module.start(context)
            entry.context = context
            entry.state = .running
        } catch {
            context.close()
            entry.state = .failed("\(entry.module.title) could not start: \(error.localizedDescription)")
            NSLog("portside: module \(entry.module.id) failed to start: \(error)")
        }
    }

    /// Stops running dependents first, then the module, then releases its context.
    private func stop(_ id: ModuleID, then next: ModuleState) {
        guard let entry = entries[id], entry.state == .running else { return }
        // Mark first so a dependency cycle cannot recurse back here.
        entry.state = next
        for other in order where other != id {
            guard let dependent = entries[other], dependent.state == .running,
                  dependent.module.dependencies.contains(.module(id)) else { continue }
            stop(other, then: dependent.enabled ? .waiting("\(entry.module.title) is not running.") : .disabled)
        }
        entry.module.stop()
        entry.context?.close()
        entry.context = nil
    }

    private func unmetDependency(of module: any PortsideModule) -> String? {
        for dependency in module.dependencies {
            switch dependency {
            case .permission(let scope):
                let current = permissions.state(of: scope)
                if current != .granted { return PermissionDenial(scope: scope, state: current).reason }
            case .module(let other):
                guard let entry = entries[other] else { return "\(other) is not installed." }
                if entry.state != .running { return "\(entry.module.title) is not running." }
            }
        }
        return nil
    }

    // MARK: Commands

    private func blockReason(_ id: ModuleID, title: String) -> String? {
        switch entries[id]?.state {
        case .running: return nil
        case .waiting(let reason), .failed(let reason): return reason
        case .disabled, nil: return "\(title) is turned off."
        }
    }

    /// The module's descriptor with availability tied to its state and the
    /// handler run as a task of the current activation, so disabling the
    /// module cancels it and the caller gets a failure, not a late success.
    private func gated(_ descriptor: CommandDescriptor, by id: ModuleID, title: String) -> CommandDescriptor {
        CommandDescriptor(
            id: descriptor.id,
            title: descriptor.title,
            keywords: descriptor.keywords,
            input: descriptor.input,
            unavailableReason: { [weak self] in
                guard let self else { return "\(title) is turned off." }
                return self.blockReason(id, title: title) ?? descriptor.unavailableReason()
            },
            requiredPermissions: descriptor.requiredPermissions,
            handler: { [weak self] input in
                guard let context = self?.entries[id]?.context,
                      let work = context.task({ await descriptor.handler(input) }) else {
                    return .failure(CommandFailure(reason: "\(title) is turned off."))
                }
                let outcome = await withTaskCancellationHandler {
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                guard context.isActive else {
                    return .failure(CommandFailure(reason: "\(title) stopped before the command finished."))
                }
                return outcome
            }
        )
    }
}
