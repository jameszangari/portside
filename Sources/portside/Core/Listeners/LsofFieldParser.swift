import Darwin
import Foundation

/// One process as lsof listed it, before libproc enrichment.
struct LsofProcessRecord: Equatable, Sendable {
    let pid: pid_t
    var name: String?
    var uid: uid_t?
    var userName: String?
    /// Ordered with `ListenerSocket.ordered`, duplicates removed.
    var sockets: [ListenerSocket]
}

struct LsofParseResult: Equatable, Sendable {
    /// Ordered by pid. Processes with no valid listening socket are left out.
    var processes: [LsofProcessRecord] = []
    /// File records skipped because a required field was missing or invalid.
    var malformedRecords = 0
    /// Sockets listed again with the same pid, fd, family, host and port.
    var duplicateSockets = 0
    /// Fields with an ID this parser does not use, or outside any record.
    var ignoredFields = 0
    /// The stream did not end on a set terminator: its last record was
    /// dropped, not counted as malformed.
    var endedMidRecord = false
}

/// Parses `lsof -F pcLuftPnT0` output: NUL-terminated fields, each starting
/// with a one-byte ID, and a newline after each process and file set. `p`
/// starts a process, `f` a file inside it. Works on bytes, so names with
/// spaces or non-ASCII text need no unescaping.
enum LsofFieldParser {
    private static let nul: UInt8 = 0
    private static let newline: UInt8 = 0x0A

    static func parse(_ data: Data) -> LsofParseResult {
        var result = LsofParseResult()
        var order: [pid_t] = []
        var processes: [pid_t: LsofProcessRecord] = [:]
        var socketSets: [pid_t: Set<ListenerSocket>] = [:]
        // nil pid: a `p` field that was not a positive number.
        var process: (pid: pid_t?, started: Bool) = (nil, false)
        var file: FileRecord?

        func finishFile() {
            guard let record = file else { return }
            file = nil
            guard let pid = process.pid, let socket = record.socket() else {
                result.malformedRecords += 1
                return
            }
            if socketSets[pid, default: []].insert(socket).inserted {
                processes[pid]?.sockets.append(socket)
            } else {
                result.duplicateSockets += 1
            }
        }

        let bytes = [UInt8](data)
        var start = 0
        while start < bytes.count {
            // The newline after the last set.
            if start == bytes.count - 1, bytes[start] == newline { break }
            guard let end = bytes[start...].firstIndex(of: nul) else {
                // A field with no terminator: the output was cut.
                result.endedMidRecord = true
                file = nil
                break
            }
            var fieldStart = start
            if bytes[fieldStart] == newline { fieldStart += 1 }
            start = end + 1
            guard fieldStart < end else { continue }
            let id = bytes[fieldStart]
            let value = bytes[(fieldStart + 1)..<end]
            switch id {
            case UInt8(ascii: "p"):
                finishFile()
                process = (Self.number(value).flatMap { $0 > 0 ? pid_t(exactly: $0) : nil }, true)
                if let pid = process.pid, processes[pid] == nil {
                    order.append(pid)
                    processes[pid] = LsofProcessRecord(pid: pid, sockets: [])
                }
            case UInt8(ascii: "c"), UInt8(ascii: "u"), UInt8(ascii: "L"):
                guard process.started, file == nil else {
                    result.ignoredFields += 1
                    continue
                }
                guard let pid = process.pid else { continue }
                switch id {
                case UInt8(ascii: "c"):
                    if processes[pid]?.name == nil { processes[pid]?.name = String(decoding: value, as: UTF8.self) }
                case UInt8(ascii: "u"):
                    if processes[pid]?.uid == nil { processes[pid]?.uid = Self.number(value).flatMap { uid_t(exactly: $0) } }
                default:
                    if processes[pid]?.userName == nil { processes[pid]?.userName = String(decoding: value, as: UTF8.self) }
                }
            case UInt8(ascii: "f"):
                finishFile()
                guard process.started else {
                    result.malformedRecords += 1
                    continue
                }
                file = FileRecord(fd: Self.number(value).flatMap { Int32(exactly: $0) })
            case UInt8(ascii: "t"), UInt8(ascii: "P"), UInt8(ascii: "n"), UInt8(ascii: "T"):
                guard file != nil else {
                    result.ignoredFields += 1
                    continue
                }
                let text = String(decoding: value, as: UTF8.self)
                switch id {
                case UInt8(ascii: "t"): file?.type = text
                case UInt8(ascii: "P"): file?.proto = text
                case UInt8(ascii: "n"): file?.name = text
                default:
                    // TCP/TPI info: only the state matters (`ST=LISTEN`).
                    if text.hasPrefix("ST=") { file?.state = String(text.dropFirst(3)) }
                }
            default:
                result.ignoredFields += 1
            }
        }
        if !bytes.isEmpty, bytes.last != newline { result.endedMidRecord = true }
        if result.endedMidRecord {
            // The record in progress may be missing fields; drop it uncounted.
            file = nil
        } else {
            finishFile()
        }

        result.processes = order.compactMap { pid in
            guard var record = processes[pid], !record.sockets.isEmpty else { return nil }
            record.sockets.sort(by: ListenerSocket.ordered)
            return record
        }
        .sorted { $0.pid < $1.pid }
        return result
    }

    /// Reads `*:PORT`, `IPv4:PORT` or `[IPv6]:PORT`, splitting on the last
    /// colon. The port must be 1...65535 in ASCII digits and the host must
    /// match `family`. A connected socket (`a->b`) is rejected.
    static func parseAddress(_ name: String, family: IPFamily) -> (kind: ListenerHostKind, host: String, port: UInt16)? {
        guard !name.contains("->"), let colon = name.lastIndex(of: ":") else { return nil }
        let hostPart = name[..<colon]
        let portPart = name[name.index(after: colon)...]
        guard (1...5).contains(portPart.count), portPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(portPart), port > 0 else { return nil }
        if hostPart == "*" { return (.wildcard, "*", port) }
        if hostPart.hasPrefix("["), hostPart.hasSuffix("]"), hostPart.count > 2 {
            guard family == .v6 else { return nil }
            let host = String(hostPart.dropFirst().dropLast())
            guard let kind = v6Kind(host) else { return nil }
            return (kind, host, port)
        }
        guard family == .v4, !hostPart.contains(":") else { return nil }
        let host = String(hostPart)
        guard let kind = v4Kind(host) else { return nil }
        return (kind, host, port)
    }

    private static func v4Kind(_ host: String) -> ListenerHostKind? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        let value = UInt32(bigEndian: address.s_addr)
        if value == 0 { return .wildcard }
        return value >> 24 == 127 ? .loopback : .specific
    }

    private static func v6Kind(_ host: String) -> ListenerHostKind? {
        // A scope (`fe80::1%en0`) is kept in `host` but not parsed.
        let bare = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        var address = in6_addr()
        guard inet_pton(AF_INET6, bare, &address) == 1 else { return nil }
        let b = withUnsafeBytes(of: address) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { return .wildcard }
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopback }
        // IPv4-mapped loopback, ::ffff:127.x.x.x.
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF, b[12] == 127 { return .loopback }
        return .specific
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> Int64? {
        guard (1...19).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int64(String(decoding: bytes, as: UTF8.self))
    }

    private struct FileRecord {
        let fd: Int32?
        var type: String?
        var proto: String?
        var name: String?
        var state: String?

        func socket() -> ListenerSocket? {
            guard let fd, let name, proto == "TCP", state == "LISTEN" else { return nil }
            let family: IPFamily
            switch type {
            case "IPv4": family = .v4
            case "IPv6": family = .v6
            default: return nil
            }
            guard let address = LsofFieldParser.parseAddress(name, family: family) else { return nil }
            return ListenerSocket(family: family, hostKind: address.kind, host: address.host, port: address.port, fd: fd)
        }
    }
}
