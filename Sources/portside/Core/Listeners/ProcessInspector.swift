import Darwin
import Foundation

/// Reads per-process facts without spawning anything. Never reads a
/// process's arguments, environment or working directory.
protocol ProcessInspector: Sendable {
    func identity(of pid: pid_t) -> ProcessFact<ProcessIdentity>
    func executablePath(of pid: pid_t) -> ProcessFact<String>
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
        return .known(ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            uid: info.pbi_uid
        ))
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
