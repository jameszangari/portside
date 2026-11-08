import Darwin
import Foundation

/// One receipt for one selected process. Cancellation after SIGTERM is a
/// failure to observe, never a claim that the signal was undone.
enum ProcessStopOutcome: Equatable, Sendable {
    case stopped, stillRunning, alreadyExited, targetChanged
    case denied, protected, canceled
    case failed(String)

    var message: String {
        switch self {
        case .stopped: return "Stopped. The selected process exited."
        case .stillRunning: return "Still running after SIGTERM. No further signal was sent."
        case .alreadyExited: return "Already exited. No signal was sent."
        case .targetChanged: return "Target changed. No signal was sent. Refresh and select again."
        case .denied: return "Denied. Ownership or macOS permissions prevent stopping this process."
        case .protected: return "Protected process. Portside will not stop it."
        case .canceled: return "Stop canceled. No signal was sent."
        case .failed(let reason): return "Stop failed. \(reason)"
        }
    }
}

protocol ProcessSignaler: Sendable {
    /// Returns errno, or nil when SIGTERM was delivered. No arbitrary signal API.
    func terminate(_ pid: pid_t) -> Int32?
}

struct SIGTERMProcessSignaler: ProcessSignaler {
    func terminate(_ pid: pid_t) -> Int32? {
        guard pid > 1 else { return EINVAL }
        return Darwin.kill(pid, SIGTERM) == 0 ? nil : errno
    }
}

struct ProcessStopPolicy: Sendable {
    var uid = geteuid()
    var ownPID = getpid()
    var parentPID = getppid()

    func protects(pid: pid_t) -> Bool { pid <= 1 || pid == ownPID || pid == parentPID }

    func protects(path: String) -> Bool {
        let roots = ["/System", "/usr/libexec", "/usr/sbin", "/sbin", "/bin", "/usr/bin", "/Library/Apple"]
        let url = URL(fileURLWithPath: path)
        let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        let names = ["launchd", "WindowServer", "Dock", "Finder", "portside"]
        return paths.contains { rawPath in
            let path = rawPath.lowercased()
            return roots.contains { path == $0.lowercased() || path.hasPrefix($0.lowercased() + "/") }
                || names.contains { URL(fileURLWithPath: path).lastPathComponent.lowercased() == $0.lowercased() }
        }
    }
}

/// Uses the discovery service for a new single-port listing, then performs
/// synchronous checks and one SIGTERM without an intervening suspension.
/// macOS has no public pidfd: the final identity-read/kill race remains.
struct ProcessStopper: Sendable {
    var inspector: any ProcessInspector = LibprocProcessInspector()
    var signaler: any ProcessSignaler = SIGTERMProcessSignaler()
    var policy = ProcessStopPolicy()
    var timeout: Duration = .seconds(5)

    func refusal(_ server: LocalServer) -> ProcessStopOutcome? {
        let process = server.process
        guard !policy.protects(pid: process.pid) else { return .protected }
        guard let identity = process.identity.value, identity.pid == process.pid,
              let uid = process.uid.value, let path = process.executablePath.value,
              path.hasPrefix("/"), !path.contains("\0"), server.port > 0,
              process.sockets.contains(where: { $0.port == server.port }) else {
            return .failed("Process identity, owner, executable or listener is unknown. No signal was sent.")
        }
        guard policy.uid != 0, uid == policy.uid, identity.uid == policy.uid else { return .denied }
        guard !policy.protects(path: path) else { return .protected }
        return nil
    }

    /// Also called before showing confirmation, so known refusals need no approval.
    func revalidate(_ server: LocalServer) -> ProcessStopOutcome? {
        if let refusal = refusal(server) { return refusal }
        let pid = server.process.pid
        switch inspector.parentPID(of: pid) {
        case .known(let parent) where parent == policy.ownPID: return .protected
        case .known: break
        case .unknown(let reason): return unknown(reason)
        }
        switch inspector.executablePath(of: pid) {
        case .known(let path):
            guard path.hasPrefix("/"), !path.contains("\0") else { return .failed("Executable is unknown. No signal was sent.") }
            if policy.protects(path: path) { return .protected }
            if path != server.process.executablePath.value { return .targetChanged }
        case .unknown(let reason): return unknown(reason)
        }
        // Last read before the syscall, after path and helper exclusions.
        switch inspector.identity(of: pid) {
        case .known(let identity):
            if identity.uid != policy.uid || identity.uid == 0 { return .denied }
            if identity != server.process.identity.value { return .targetChanged }
        case .unknown(let reason): return unknown(reason)
        }
        return nil
    }

    @MainActor
    func stop(_ server: LocalServer, listeners: ListenerService, authorized: () -> Bool) async -> ProcessStopOutcome {
        guard !Task.isCancelled, authorized() else { return .canceled }
        if let refusal = revalidate(server) { return refusal }
        guard let query = ListenerQuery(port: Int(server.port)) else { return .targetChanged }
        let fresh: ListenerSnapshot
        do { fresh = try await listeners.snapshot(query, fresh: true) }
        catch { return .canceled }
        guard !Task.isCancelled, authorized() else { return .canceled }
        // Recheck even when lsof found nothing: ESRCH is alreadyExited,
        // whereas a live process that lost its port is targetChanged.
        if let refusal = revalidate(server) { return refusal }
        guard fresh.query == query, fresh.visibleUID == policy.uid, fresh.outcome == .complete else {
            return .failed("Could not verify current port ownership. No signal was sent.")
        }
        guard let owner = fresh.processes.first(where: { $0.pid == server.process.pid }),
              owner.identity == server.process.identity, owner.uid == server.process.uid,
              owner.executablePath == server.process.executablePath,
              owner.sockets.contains(where: { $0.port == server.port }) else { return .targetChanged }
        // No await, UI callback, or port listing between this check and SIGTERM.
        if let refusal = revalidate(server) { return refusal }
        guard !Task.isCancelled else { return .canceled }
        if let code = signaler.terminate(server.process.pid) {
            switch code {
            case ESRCH: return .alreadyExited
            case EPERM, EACCES: return .denied
            default: return .failed("SIGTERM returned error \(code).")
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            switch inspector.identity(of: server.process.pid) {
            case .unknown(.exited): return .stopped
            case .known(let identity):
                guard let original = server.process.identity.value else { return .failed("Original identity is unknown.") }
                if identity.pid != original.pid || identity.startSeconds != original.startSeconds || identity.startMicroseconds != original.startMicroseconds { return .stopped }
                if identity.uid != original.uid { return .failed("SIGTERM was sent, but process ownership changed before exit was verified.") }
            case .unknown: return .failed("SIGTERM was sent, but process exit could not be verified.")
            }
            if Task.isCancelled { return .failed("SIGTERM was sent; exit observation was canceled.") }
            if ContinuousClock.now >= deadline { return .stillRunning }
            do { try await Task.sleep(until: min(deadline, .now.advanced(by: .milliseconds(50))), clock: .continuous) }
            catch { return .failed("SIGTERM was sent; exit observation was canceled.") }
        }
    }

    private func unknown(_ reason: UnknownReason) -> ProcessStopOutcome {
        switch reason {
        case .exited: return .alreadyExited
        case .changed: return .targetChanged
        case .denied: return .denied
        case .notReported: return .failed("Process facts are unknown. No signal was sent.")
        case .failed(let code): return .failed("Could not verify process facts (error \(code)). No signal was sent.")
        }
    }
}
