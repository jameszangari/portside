import Darwin
import XCTest
@testable import portside

/// Answers from a table instead of libproc. Unlisted pids are denied.
struct FakeProcessInspector: ProcessInspector {
    var identities: [pid_t: ProcessFact<ProcessIdentity>] = [:]
    var paths: [pid_t: ProcessFact<String>] = [:]
    var cwds: [pid_t: ProcessFact<String>] = [:]

    static func owning(_ pids: [pid_t], uid: uid_t = 501, startSeconds: UInt64 = 1_000) -> FakeProcessInspector {
        var fake = FakeProcessInspector()
        for pid in pids {
            fake.identities[pid] = .known(ProcessIdentity(pid: pid, startSeconds: startSeconds, startMicroseconds: 7, uid: uid))
            fake.paths[pid] = .known("/tmp/fixture/bin/server")
        }
        return fake
    }

    func identity(of pid: pid_t) -> ProcessFact<ProcessIdentity> { identities[pid] ?? .unknown(.denied) }
    func executablePath(of pid: pid_t) -> ProcessFact<String> { paths[pid] ?? .unknown(.denied) }
    func workingDirectory(of pid: pid_t) -> ProcessFact<String> { cwds[pid] ?? .unknown(.denied) }
}

/// The hand-authored `Fixtures/lsof/*.f` streams (NUL-separated, P2-REA-02
/// fixture table) through the parser and the snapshot builder.
final class LsofFieldParserTests: XCTestCase {
    private struct Meta: Decodable {
        let exit: Int32
        let stderr: String
    }

    private func bytes(_ name: String) throws -> Data { try Fixture.data("lsof/\(name)") }

    private func snapshot(
        _ name: String,
        limits: LsofLimits = LsofLimits(),
        inspector: FakeProcessInspector = .owning([4242, 4243, 4244, 5001, 5002, 6001, 6002])
    ) async throws -> ListenerSnapshot {
        let metas = try JSONDecoder().decode([String: Meta].self, from: try bytes("meta.json"))
        let meta = metas[name]
        let source = FixtureListenerSource(
            stdout: try bytes(name),
            stderr: Data((meta?.stderr ?? "").utf8),
            termination: .exited(meta?.exit ?? 0),
            limits: limits,
            inspector: inspector
        )
        return try await source.snapshot(.all)
    }

    private func socket(_ family: IPFamily, _ kind: ListenerHostKind, _ host: String, _ port: UInt16, fd: Int32) -> ListenerSocket {
        ListenerSocket(family: family, hostKind: kind, host: host, port: port, fd: fd)
    }

    func testIPv4Loopback() async throws {
        let snapshot = try await snapshot("v4-loopback.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.processes.count, 1)
        XCTAssertEqual(snapshot.sockets, [socket(.v4, .loopback, "127.0.0.1", 5173, fd: 3)])
        let process = try XCTUnwrap(snapshot.processes.first)
        XCTAssertEqual(process.pid, 4242)
        XCTAssertEqual(process.name, .known("python3.13"))
        XCTAssertEqual(process.uid, .known(501))
        XCTAssertEqual(process.userName, .known("tester"))
        XCTAssertTrue(process.hasVerifiedIdentity)
        XCTAssertEqual(process.executablePath, .known("/tmp/fixture/bin/server"))
    }

    func testIPv6Loopback() async throws {
        let snapshot = try await snapshot("v6-loopback.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.sockets, [socket(.v6, .loopback, "::1", 5173, fd: 3)])
    }

    func testWildcardIPv4AndIPv6StayTwoSockets() async throws {
        let snapshot = try await snapshot("wildcard-v4-v6.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.processes.count, 1)
        XCTAssertEqual(snapshot.sockets, [
            socket(.v4, .wildcard, "*", 3000, fd: 20),
            socket(.v6, .wildcard, "*", 3000, fd: 21),
        ])
        XCTAssertEqual(snapshot.diagnostics.duplicateSockets, 0)
    }

    func testWildcardAndLoopbackOnOnePortStayTwoSockets() async throws {
        let snapshot = try await snapshot("wildcard-and-loopback-same-port.f")
        XCTAssertEqual(snapshot.sockets, [
            socket(.v4, .wildcard, "*", 3000, fd: 21),
            socket(.v4, .loopback, "127.0.0.1", 3000, fd: 20),
        ])
    }

    func testMultiplePortsSortByPortThenFamily() async throws {
        let snapshot = try await snapshot("multi-port-one-process.f")
        XCTAssertEqual(snapshot.processes.count, 1)
        XCTAssertEqual(snapshot.sockets.map { "\($0.port)/\($0.family.rawValue)" }, ["5432/4", "5432/6", "8080/4", "9000/6"])
    }

    func testTwoProcessesWithTheSameName() async throws {
        let snapshot = try await snapshot("two-processes-same-name.f")
        XCTAssertEqual(snapshot.processes.map(\.pid), [5001, 5002])
        XCTAssertEqual(snapshot.processes.map(\.name), [.known("node"), .known("node")])
        XCTAssertEqual(snapshot.processes.map { $0.sockets.map(\.port) }, [[5173], [5174]])
    }

    func testNamesWithSpacesAndUnicodeArePreserved() async throws {
        let snapshot = try await snapshot("name-with-space-and-unicode.f")
        XCTAssertEqual(snapshot.processes.map(\.name), [.known("Code Helper (Plugin)"), .known("開発サーバ")])
        XCTAssertEqual(snapshot.processes.last?.sockets, [socket(.v6, .wildcard, "*", 41001, fd: 31)])
    }

    func testEmptyOutputIsCompleteWithNoListeners() async throws {
        let snapshot = try await snapshot("empty.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertEqual(snapshot.visibleUID, geteuid())
    }

    func testExitOneWithNoStderrIsNoListenersNotFailure() async throws {
        let snapshot = try await snapshot("no-listeners-exit1.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.exitStatus, 1)
    }

    func testExitOneWithStderrIsFailure() async throws {
        let snapshot = try await snapshot("denied-stderr.f")
        XCTAssertEqual(snapshot.outcome, .failed(.exitStatus(1)))
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertGreaterThan(snapshot.diagnostics.stderrBytes, 0)
    }

    func testTruncatedMidRecordKeepsCompletedRecords() async throws {
        let snapshot = try await snapshot("truncated-mid-record.f")
        XCTAssertEqual(snapshot.outcome, .partial(truncated: true, malformedRecords: 0))
        XCTAssertEqual(snapshot.processes.map(\.pid), [4242, 4243])
        XCTAssertTrue(snapshot.diagnostics.endedMidRecord)
    }

    func testStreamEndingOnANulBeforeTheSetNewlineDropsTheOpenRecord() {
        // Cut after a field terminator but before the set ended: more fields may be missing.
        let parsed = LsofFieldParser.parse(Data("p4242\0cnode\0\nf3\0tIPv4\0PTCP\0n127.0.0.1:5173\0TST=LISTEN\0".utf8))
        XCTAssertTrue(parsed.endedMidRecord)
        XCTAssertTrue(parsed.processes.isEmpty)
        XCTAssertEqual(parsed.malformedRecords, 0)
    }

    func testMalformedAddressesAreSkippedAndCounted() async throws {
        let snapshot = try await snapshot("malformed-address.f")
        XCTAssertEqual(snapshot.outcome, .partial(truncated: false, malformedRecords: 4))
        XCTAssertEqual(snapshot.sockets, [socket(.v4, .loopback, "127.0.0.1", 3000, fd: 14)])
    }

    func testConnectedSocketIsMalformed() async throws {
        let snapshot = try await snapshot("connected-socket.f")
        XCTAssertEqual(snapshot.outcome, .partial(truncated: false, malformedRecords: 1))
        XCTAssertEqual(snapshot.sockets.map(\.fd), [11])
    }

    func testUnknownFieldsAreIgnored() async throws {
        let snapshot = try await snapshot("unknown-field.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.diagnostics.ignoredFields, 2)
        XCTAssertEqual(snapshot.processes.first?.userName, .known("tester"))
        XCTAssertEqual(snapshot.sockets.count, 1)
    }

    func testDuplicatesCollapseOnlyOnFullSocketKey() async throws {
        let snapshot = try await snapshot("duplicate-record.f")
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.processes.count, 1)
        // Same address and port on fd 10 and fd 11 stay two sockets.
        XCTAssertEqual(snapshot.sockets.map(\.fd), [10, 11])
        XCTAssertEqual(snapshot.diagnostics.duplicateSockets, 2)
    }

    func testOutputOverTheByteCapIsPartialTruncated() async throws {
        var limits = LsofLimits()
        limits.stdoutCap = 1024
        let snapshot = try await snapshot("oversized.f", limits: limits)
        XCTAssertEqual(snapshot.outcome, .partial(truncated: true, malformedRecords: 0))
        XCTAssertEqual(snapshot.diagnostics.stdoutBytes, 1024)
        XCTAssertFalse(snapshot.sockets.isEmpty)
        XCTAssertLessThan(snapshot.sockets.count, 100)
        let whole = try await self.snapshot("oversized.f")
        XCTAssertEqual(whole.outcome, .complete)
        XCTAssertEqual(whole.sockets.count, 100)
    }

    // MARK: Exit and termination rules

    private func build(_ termination: LsofRun.Termination, stdout: String = "", stderr: String = "", truncated: Bool = false) -> ListenerSnapshot {
        var run = LsofRun(termination: termination)
        run.stdout = Data(stdout.utf8)
        run.stderr = Data(stderr.utf8)
        run.stdoutTruncated = truncated
        return ListenerSnapshotBuilder.snapshot(.all, run: run, inspector: FakeProcessInspector.owning([4242]))
    }

    private let oneListener = "p4242\0cnode\0u501\0\nf3\0tIPv4\0PTCP\0n127.0.0.1:3000\0TST=LISTEN\0\n"

    func testExitAndSignalOutcomes() {
        XCTAssertEqual(build(.exited(0), stdout: oneListener).outcome, .complete)
        XCTAssertEqual(build(.exited(0), stdout: oneListener, stderr: "lsof: WARNING: x\n").outcome, .complete)
        XCTAssertEqual(build(.exited(1), stdout: oneListener).processes.count, 1)
        XCTAssertEqual(build(.exited(2)).outcome, .failed(.exitStatus(2)))
        XCTAssertEqual(build(.exited(1), stdout: oneListener, stderr: "denied").processes.count, 0)
        XCTAssertEqual(build(.signaled(SIGSEGV), stdout: oneListener).outcome, .failed(.signaled(SIGSEGV)))
        XCTAssertEqual(build(.timedOut, stdout: oneListener).outcome, .timedOut)
        XCTAssertTrue(build(.timedOut, stdout: oneListener).processes.isEmpty)
        XCTAssertEqual(build(.launchFailed("missing")).outcome, .failed(.launchFailed("missing")))
        // Stopped at the byte cap by Portside: partial, not a failure.
        let capped = build(.signaled(SIGTERM), stdout: oneListener, truncated: true)
        XCTAssertEqual(capped.outcome, .partial(truncated: true, malformedRecords: 0))
        XCTAssertEqual(capped.processes.count, 1)
    }

    // MARK: Address grammar

    func testAddressGrammar() {
        func kind(_ name: String, _ family: IPFamily) -> ListenerHostKind? { LsofFieldParser.parseAddress(name, family: family)?.kind }
        XCTAssertEqual(kind("*:80", .v4), .wildcard)
        XCTAssertEqual(kind("*:80", .v6), .wildcard)
        XCTAssertEqual(kind("0.0.0.0:80", .v4), .wildcard)
        XCTAssertEqual(kind("[::]:80", .v6), .wildcard)
        XCTAssertEqual(kind("127.0.0.1:80", .v4), .loopback)
        XCTAssertEqual(kind("127.4.5.6:80", .v4), .loopback)
        XCTAssertEqual(kind("[::1]:80", .v6), .loopback)
        XCTAssertEqual(kind("[::ffff:127.0.0.1]:80", .v6), .loopback)
        XCTAssertEqual(kind("192.168.1.20:80", .v4), .specific)
        XCTAssertEqual(kind("[fe80::1%lo0]:80", .v6), .specific)
        XCTAssertEqual(LsofFieldParser.parseAddress("[fe80::1%lo0]:80", family: .v6)?.host, "fe80::1%lo0")
        XCTAssertEqual(LsofFieldParser.parseAddress("*:65535", family: .v4)?.port, 65535)
        for bad in ["abc", "*:0", "*:65536", "*:99999", "[::1]", "*:", ":80", "*:8a", "*:+80", "*:٣٠٠٠",
                    "127.0.0.1:5000->127.0.0.1:6000", "300.1.1.1:80", "localhost:80", "[]:80"] {
            XCTAssertNil(LsofFieldParser.parseAddress(bad, family: .v4), bad)
            XCTAssertNil(LsofFieldParser.parseAddress(bad, family: .v6), bad)
        }
        // Family must match the bracket form.
        XCTAssertNil(LsofFieldParser.parseAddress("[::1]:80", family: .v4))
        XCTAssertNil(LsofFieldParser.parseAddress("127.0.0.1:80", family: .v6))
    }

    func testRecordsMissingRequiredFieldsAreMalformed() {
        let stream = [
            "p1\0cx\0\n",
            "f3\0PTCP\0n*:1\0TST=LISTEN\0\n",            // no type
            "f4\0tIPv4\0n*:2\0TST=LISTEN\0\n",           // no protocol
            "f5\0tIPv4\0PTCP\0TST=LISTEN\0\n",           // no name
            "f6\0tIPv4\0PTCP\0n*:4\0\n",                  // no state
            "f7\0tIPv4\0PTCP\0n*:5\0TST=ESTABLISHED\0\n", // not listening
            "fcwd\0tIPv4\0PTCP\0n*:6\0TST=LISTEN\0\n",   // not a descriptor number
            "f8\0tunix\0PTCP\0n*:7\0TST=LISTEN\0\n",     // not IP
            "f9\0tIPv4\0PUDP\0n*:8\0TST=LISTEN\0\n",     // not TCP
            "f10\0tIPv4\0PTCP\0n*:9\0TST=LISTEN\0\n",    // valid
            "p0\0cbad\0\nf3\0tIPv4\0PTCP\0n*:10\0TST=LISTEN\0\n", // pid 0
            "pabc\0\nf3\0tIPv4\0PTCP\0n*:11\0TST=LISTEN\0\n",     // pid not a number
        ].joined()
        let parsed = LsofFieldParser.parse(Data(stream.utf8))
        XCTAssertEqual(parsed.malformedRecords, 10)
        XCTAssertEqual(parsed.processes.map(\.pid), [1])
        XCTAssertEqual(parsed.processes.first?.sockets.map(\.port), [9])
        XCTAssertFalse(parsed.endedMidRecord)
    }

    func testFileBeforeAnyProcessIsMalformed() {
        let parsed = LsofFieldParser.parse(Data("f3\0tIPv4\0PTCP\0n*:1\0TST=LISTEN\0\n".utf8))
        XCTAssertEqual(parsed.malformedRecords, 1)
        XCTAssertTrue(parsed.processes.isEmpty)
    }

    func testMissingProcessFieldsAreUnknownNotGuessed() async throws {
        let source = FixtureListenerSource(
            stdout: Data("p4242\0\nf3\0tIPv4\0PTCP\0n127.0.0.1:3000\0TST=LISTEN\0\n".utf8),
            inspector: FakeProcessInspector()
        )
        let snapshot = try await source.snapshot(.all)
        let process = try XCTUnwrap(snapshot.processes.first)
        XCTAssertEqual(process.name, .unknown(.notReported))
        XCTAssertEqual(process.uid, .unknown(.notReported))
        XCTAssertEqual(process.userName, .unknown(.notReported))
        XCTAssertEqual(process.identity, .unknown(.denied))
        XCTAssertEqual(process.executablePath, .unknown(.denied))
        XCTAssertFalse(process.hasVerifiedIdentity)
    }

    // MARK: Identity enrichment

    func testReusedPidIsChangedNotTheNewProcess() {
        let record = LsofProcessRecord(pid: 4242, name: "node", uid: 501, userName: "tester", sockets: [])
        let listedBy = Date(timeIntervalSince1970: 2_000)

        let otherUser = ListenerSnapshotBuilder.enrich(record, inspector: FakeProcessInspector.owning([4242], uid: 0), listedBy: listedBy)
        XCTAssertEqual(otherUser.identity, .unknown(.changed))
        XCTAssertEqual(otherUser.executablePath, .unknown(.changed))
        XCTAssertFalse(otherUser.hasVerifiedIdentity)

        let startedLater = ListenerSnapshotBuilder.enrich(record, inspector: FakeProcessInspector.owning([4242], startSeconds: 2_001), listedBy: listedBy)
        XCTAssertEqual(startedLater.identity, .unknown(.changed))

        let same = ListenerSnapshotBuilder.enrich(record, inspector: FakeProcessInspector.owning([4242], startSeconds: 1_999), listedBy: listedBy)
        XCTAssertEqual(same.identity.value?.startSeconds, 1_999)
        XCTAssertEqual(same.identity.value?.startMicroseconds, 7)
    }

    func testExitedAndDeniedIdentityStayUnknown() {
        let record = LsofProcessRecord(pid: 4242, name: "node", uid: 501, userName: nil, sockets: [])
        var inspector = FakeProcessInspector()
        inspector.identities[4242] = .unknown(.exited)
        inspector.paths[4242] = .unknown(.exited)
        let exited = ListenerSnapshotBuilder.enrich(record, inspector: inspector, listedBy: Date())
        XCTAssertEqual(exited.identity, .unknown(.exited))
        XCTAssertEqual(exited.executablePath, .unknown(.exited))
        // Path and identity are read separately (one can be denied alone).
        inspector.identities[4242] = .unknown(.denied)
        inspector.paths[4242] = .known("/sbin/launchd")
        let denied = ListenerSnapshotBuilder.enrich(record, inspector: inspector, listedBy: Date())
        XCTAssertEqual(denied.identity, .unknown(.denied))
        XCTAssertEqual(denied.executablePath, .known("/sbin/launchd"))
        XCTAssertFalse(denied.hasVerifiedIdentity)
    }

    func testIdentityStartComparisonUsesMicroseconds() {
        let identity = ProcessIdentity(pid: 1, startSeconds: 100, startMicroseconds: 500_001, uid: 501)
        XCTAssertTrue(identity.started(after: Date(timeIntervalSince1970: 100.5)))
        XCTAssertFalse(identity.started(after: Date(timeIntervalSince1970: 100.6)))
        XCTAssertNotEqual(identity, ProcessIdentity(pid: 1, startSeconds: 100, startMicroseconds: 500_002, uid: 501))
        XCTAssertNotEqual(identity, ProcessIdentity(pid: 1, startSeconds: 100, startMicroseconds: 500_001, uid: 502))
    }
}
