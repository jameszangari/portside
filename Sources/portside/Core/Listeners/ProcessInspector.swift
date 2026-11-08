import Darwin
import Foundation

/// Reads per-process facts without spawning anything. Never reads a
/// process's arguments or environment. The working directory is the one
/// path read beyond the executable (P2-DEV-05A).
protocol ProcessInspector: Sendable {
    func identity(of pid: pid_t) -> ProcessFact<ProcessIdentity>
    func executablePath(of pid: pid_t) -> ProcessFact<String>
    func parentPID(of pid: pid_t) -> ProcessFact<pid_t>
    func workingDirectory(of pid: pid_t) -> ProcessFact<String>
}

extension ProcessInspector {
    func parentPID(of pid: pid_t) -> ProcessFact<pid_t> { .unknown(.notReported) }
    func workingDirectory(of pid: pid_t) -> ProcessFact<String> { .unknown(.notReported) }
}

/// Public libproc: `proc_pidinfo(PROC_PIDTBSDINFO)` for start time and uid,
/// `proc_pidpath` for the executable. Either can be denied on its own
/// (another user's or a protected process), which stays unknown.
struct LibprocProcessInspector: ProcessInspector {
    func identity(of pid: pid_t) -> ProcessFact<ProcessIdentity> {
        guard pid > 0 else { return .unknown(.failed(EINVAL)) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return .unknown(Self.reason(errno)) }
        guard info.pbi_status != SZOMB else { return .unknown(.exited) }
        return .known(ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            uid: info.pbi_uid
        ))
    }

    func parentPID(of pid: pid_t) -> ProcessFact<pid_t> {
        guard pid > 0 else { return .unknown(.failed(EINVAL)) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return .unknown(Self.reason(errno)) }
        guard info.pbi_status != SZOMB else { return .unknown(.exited) }
        return .known(pid_t(info.pbi_ppid))
    }

    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`: the kernel's current directory
    /// for the process, already resolved. Denied for other users' processes.
    func workingDirectory(of pid: pid_t) -> ProcessFact<String> {
        guard pid > 0 else { return .unknown(.failed(EINVAL)) }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return .unknown(Self.reason(errno)) }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? .unknown(.notReported) : .known(path)
    }

    func executablePath(of pid: pid_t) -> ProcessFact<String> {
        guard pid > 0 else { return .unknown(.failed(EINVAL)) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        errno = 0
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return .unknown(Self.reason(errno)) }
        return .known(String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func reason(_ code: Int32) -> UnknownReason {
        switch code {
        case EPERM, EACCES: return .denied
        case ESRCH: return .exited
        default: return .failed(code)
        }
    }
}
