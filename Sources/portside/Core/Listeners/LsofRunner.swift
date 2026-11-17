import Darwin
import Foundation

/// The exact lsof command. Built only from `ListenerQuery`, never from text:
/// absolute path, fixed arguments, no shell.
struct LsofInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    /// The child's whole environment. Nothing is inherited.
    let environment: [String: String]

    static let executablePath = "/usr/sbin/lsof"

    /// `-nP` no name lookups, `-sTCP:LISTEN` listeners only, `+c 0` full
    /// command names, `-F pcLuftPnT0` NUL-terminated fields. No `-u`, `-r`,
    /// `+M` or `-w`.
    static func listeners(_ query: ListenerQuery) -> LsofInvocation {
        let selector = query.port.map { "-iTCP:\($0)" } ?? "-iTCP"
        return LsofInvocation(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: ["-nP", selector, "-sTCP:LISTEN", "+c", "0", "-F", "pcLuftPnT0"],
            environment: ["LC_ALL": "C"]
        )
    }
}

struct LsofLimits: Sendable {
    /// From launch until SIGTERM.
    var deadline: Duration = .seconds(2)
    /// From SIGTERM until SIGKILL.
    var killGrace: Duration = .milliseconds(250)
    /// From SIGKILL until the run is given up on. A child stuck in the kernel
    /// cannot be reaped sooner; it is left to Foundation to reap.
    var abandonGrace: Duration = .milliseconds(500)
    /// After exit, how long to wait for the pipes to close.
    var drainGrace: Duration = .milliseconds(250)
    var stdoutCap = 1 << 20
    var stderrCap = 64 << 10
}

/// What one lsof run produced. Read by `ListenerSnapshotBuilder`.
struct LsofRun: Sendable {
    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signaled(Int32)
        /// Missed the deadline and was stopped.
        case timedOut
        case launchFailed(String)
        /// The caller canceled. The child was stopped.
        case canceled
    }

    var stdout = Data()
    var stderr = Data()
    /// The byte cap was hit; the child was stopped.
    var stdoutTruncated = false
    var stderrTruncated = false
    var termination: Termination
    /// The child's pid, 0 if it never started. For tests only.
    var pid: pid_t = 0
    /// False only when the child was given up on after SIGKILL.
    var reaped = true
    var finishedAt = Date()
    var duration: Duration = .zero
}

/// Runs one lsof child off the main thread with a deadline, byte caps and
/// cancellation. The only signals sent go to that child: SIGTERM at the
/// deadline, cap or cancel, then SIGKILL after `killGrace`.
enum LsofRunner {
    /// `onReaped` runs once when the child has exited and been reaped (at
    /// once if it never started), possibly after this returns.
    static func run(_ invocation: LsofInvocation, limits: LsofLimits, onReaped: @escaping @Sendable () -> Void = {}) async -> LsofRun {
        let execution = LsofExecution(invocation: invocation, limits: limits, onReaped: onReaped)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { execution.start($0) }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// One child's state, confined to `queue`.
private final class LsofExecution: @unchecked Sendable {
    private enum Stop { case timedOut, capped, canceled }

    private let invocation: LsofInvocation
    private let limits: LsofLimits
    private let onReaped: @Sendable () -> Void
    private let queue = DispatchQueue(label: "portside.listeners.lsof", qos: .utility)
    private let process = Process()
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?
    private var continuation: CheckedContinuation<LsofRun, Never>?
    private var canceledBeforeStart = false
    private var stop: Stop?
    private var exit: LsofRun.Termination?
    private var sources: [DispatchSourceRead] = []
    private var openStreams = 0
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutTruncated = false
    private var stderrTruncated = false

    init(invocation: LsofInvocation, limits: LsofLimits, onReaped: @escaping @Sendable () -> Void) {
        self.invocation = invocation
        self.limits = limits
        self.onReaped = onReaped
    }

    func cancel() {
        queue.async { [self] in
            if continuation == nil, started == nil { canceledBeforeStart = true }
            requestStop(.canceled)
        }
    }

    func start(_ continuation: CheckedContinuation<LsofRun, Never>) {
        queue.async { [self] in
            self.continuation = continuation
            if canceledBeforeStart {
                onReaped()
                return finish(LsofRun(termination: .canceled))
            }
            launch()
        }
    }

    private func launch() {
        let out = Pipe()
        let err = Pipe()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        process.terminationHandler = { [self] process in
            let status = process.terminationStatus
            let signaled = process.terminationReason == .uncaughtSignal
            queue.async { [self] in
                process.terminationHandler = nil
                exit = signaled ? .signaled(status) : .exited(status)
                onReaped()
                if openStreams == 0 { finishNow() } else { after(limits.drainGrace) { [self] in finishNow() } }
            }
        }
        started = clock.now
        do {
            try process.run()
        } catch {
            onReaped()
            return finish(LsofRun(termination: .launchFailed(launchFailure(error))))
        }
        // Foundation closed the child's ends in this process; ours get their
        // own descriptors so a read source can own and close them.
        watch(out.fileHandleForReading, isStdout: true)
        watch(err.fileHandleForReading, isStdout: false)
        after(limits.deadline) { [self] in requestStop(.timedOut) }
    }

    private func watch(_ handle: FileHandle, isStdout: Bool) {
        let fd = dup(handle.fileDescriptor)
        try? handle.close()
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        openStreams += 1
        var closed = false
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while !closed {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    append(buffer[0..<count], isStdout: isStdout)
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN {
                    return
                } else {
                    closed = true
                    source.cancel()
                    openStreams -= 1
                    if openStreams == 0, exit != nil { finishNow() }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        sources.append(source)
        source.resume()
    }

    private func append(_ bytes: ArraySlice<UInt8>, isStdout: Bool) {
        if isStdout {
            guard !stdoutTruncated else { return }
            let room = limits.stdoutCap - stdout.count
            stdout.append(contentsOf: bytes.prefix(max(0, room)))
            if bytes.count > room {
                stdoutTruncated = true
                requestStop(.capped)
            }
        } else {
            guard !stderrTruncated else { return }
            let room = limits.stderrCap - stderr.count
            stderr.append(contentsOf: bytes.prefix(max(0, room)))
            if bytes.count > room { stderrTruncated = true }
        }
    }

    /// SIGTERM, then SIGKILL, then give up. Only the first reason counts.
    private func requestStop(_ reason: Stop) {
        guard continuation != nil, started != nil, exit == nil, stop == nil else { return }
        stop = reason
        process.terminate()
        after(limits.killGrace) { [self] in
            // `exit` is set on this queue once the child is reaped, so the
            // pid still names Portside's own child here.
            if exit == nil, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            after(limits.abandonGrace) { [self] in finishNow() }
        }
    }

    private func finishNow() {
        guard continuation != nil else { return }
        var run = LsofRun(termination: .canceled)
        run.stdout = stdout
        run.stderr = stderr
        run.stdoutTruncated = stdoutTruncated
        run.stderrTruncated = stderrTruncated
        run.pid = process.processIdentifier
        run.reaped = exit != nil
        switch stop {
        case .canceled: run.termination = .canceled
        case .timedOut: run.termination = .timedOut
        case .capped: run.termination = exit ?? .timedOut
        case nil: run.termination = exit ?? .timedOut
        }
        finish(run)
    }

    private func finish(_ partial: LsofRun) {
        guard let continuation else { return }
        self.continuation = nil
        for source in sources { source.cancel() }
        sources.removeAll()
        var run = partial
        run.finishedAt = Date()
        if let started { run.duration = clock.now - started }
        continuation.resume(returning: run)
    }

    private func after(_ delay: Duration, _ work: @escaping () -> Void) {
        let (seconds, attoseconds) = delay.components
        let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: work)
    }

    private func launchFailure(_ error: Error) -> String {
        let code = (error as NSError).code
        if code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError {
            return "\(invocation.executableURL.path) does not exist."
        }
        return "\(invocation.executableURL.path) could not be started."
    }
}
