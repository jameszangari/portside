import Darwin
import XCTest
@testable import portside

final class ProjectAssociationTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("portside-dev05a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(raw.path, &buffer) != nil else { throw CocoaError(.fileNoSuchFile) }
        base = URL(fileURLWithPath: String(cString: buffer))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func dir(_ path: String) throws -> String {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func testGitDirectoryInfersNearestRoot() throws {
        let root = try dir("app")
        _ = try dir("app/.git")
        let sub = try dir("app/packages/web")
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: sub, homes: []), .inferred(root: root))
        XCTAssertEqual(ProjectAssociation.inferred(root: root).name, "app")
    }

    func testGitFileCountsAsMarkerAndNearestWins() throws {
        _ = try dir("outer/.git")
        let inner = try dir("outer/inner")
        try Data("gitdir: x".utf8).write(to: base.appendingPathComponent("outer/inner/.git"))
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: inner, homes: []), .inferred(root: inner))
    }

    func testNonGitDirectoryIsNotFound() throws {
        let plain = try dir("plain/deep")
        let result = ProjectLocator.locate(workingDirectory: plain, homes: [])
        XCTAssertTrue(result == .notFound || result == .ambiguous, "\(result)")
    }

    func testMarkerAtHomeIsAmbiguous() throws {
        let home = try dir("home")
        _ = try dir("home/.git")
        let sub = try dir("home/scratch")
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: sub, homes: [home]), .ambiguous)
    }

    func testSymlinkedMarkerIgnored() throws {
        let target = try dir("elsewhere/.git")
        let proj = try dir("linked")
        try FileManager.default.createSymbolicLink(atPath: proj + "/.git", withDestinationPath: target)
        XCTAssertNotEqual(ProjectLocator.locate(workingDirectory: proj, homes: []), .inferred(root: proj))
    }

    func testMissingOrRelativeDirectoryUnavailable() {
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: base.path + "/gone", homes: []), .unavailable(.failed(ENOENT)))
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: "relative", homes: []), .unavailable(.failed(ENOENT)))
    }

    func testDepthBounded() throws {
        _ = try dir(".git")
        var path = "d"
        for _ in 0..<(ProjectLocator.maxLevels + 2) { path += "/d" }
        let deep = try dir(path)
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: deep, homes: []), .notFound)
    }

    // MARK: enrich

    private func record(_ pid: pid_t) -> LsofProcessRecord {
        let socket = ListenerSocket(family: .v4, hostKind: .loopback, host: "127.0.0.1", port: 3000, fd: 5)
        return LsofProcessRecord(pid: pid, name: "node", uid: 501, userName: "t", sockets: [socket])
    }

    func testEnrichVerifiedCwdAndInferredProject() throws {
        let root = try dir("svc")
        _ = try dir("svc/.git")
        var fake = FakeProcessInspector.owning([4242])
        fake.cwds[4242] = .known(root)
        let process = ListenerSnapshotBuilder.enrich(record(4242), inspector: fake, listedBy: Date())
        XCTAssertEqual(process.workingDirectory, .known(root))
        XCTAssertEqual(process.project, .inferred(root: root))
    }

    func testEnrichDeniedCwdIsUnknown() {
        let process = ListenerSnapshotBuilder.enrich(record(4242), inspector: FakeProcessInspector.owning([4242]), listedBy: Date())
        XCTAssertEqual(process.workingDirectory, .unknown(.denied))
        XCTAssertEqual(process.project, .unavailable(.denied))
    }

    func testEnrichReusedPidReadsNoCwd() {
        var fake = FakeProcessInspector.owning([4242], uid: 999)
        fake.cwds[4242] = .known("/tmp")
        let process = ListenerSnapshotBuilder.enrich(record(4242), inspector: fake, listedBy: Date())
        XCTAssertEqual(process.workingDirectory, .unknown(.changed))
        XCTAssertEqual(process.project, .unavailable(.changed))
    }

    func testEnrichUnknownIdentityReadsNoCwd() {
        var fake = FakeProcessInspector()
        fake.cwds[4242] = .known("/tmp")
        let process = ListenerSnapshotBuilder.enrich(record(4242), inspector: fake, listedBy: Date())
        XCTAssertEqual(process.workingDirectory, .unknown(.denied))
    }

    func testCardFactsSayUnknownWhenUnreadable() {
        let process = ListenerSnapshotBuilder.enrich(record(4242), inspector: FakeProcessInspector.owning([4242]), listedBy: Date())
        let facts = LocalServerText.project(process)
        XCTAssertEqual(facts.map(\.label), ["Directory", "Project"])
        XCTAssertEqual(facts[1].value, "Unknown")
        XCTAssertTrue(facts[0].value.hasPrefix("Unknown"))
    }

    func testCardFactsLabelProvenance() throws {
        let root = try dir("shown")
        _ = try dir("shown/.git")
        var fake = FakeProcessInspector.owning([4242])
        fake.cwds[4242] = .known(root)
        let facts = LocalServerText.project(ListenerSnapshotBuilder.enrich(record(4242), inspector: fake, listedBy: Date()))
        XCTAssertTrue(facts[0].value.contains("verified working directory"))
        XCTAssertTrue(facts[1].value.hasPrefix("shown (inferred from the Git repository"))
    }

    // MARK: real process

    func testLibprocReadsOwnedChildCwdAndFindsRepo() throws {
        let root = try dir("live")
        _ = try dir("live/.git")
        let sub = try dir("live/src")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.currentDirectoryURL = URL(fileURLWithPath: sub)
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let inspector = LibprocProcessInspector()
        var cwd = inspector.workingDirectory(of: child.processIdentifier)
        for _ in 0..<50 where cwd.value != sub {
            usleep(20_000)
            cwd = inspector.workingDirectory(of: child.processIdentifier)
        }
        XCTAssertEqual(cwd, .known(sub))
        XCTAssertEqual(ProjectLocator.locate(workingDirectory: sub, homes: []), .inferred(root: root))
    }

    func testLibprocExitedPidIsUnknown() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? child.run()
        child.waitUntilExit()
        XCTAssertNil(LibprocProcessInspector().workingDirectory(of: child.processIdentifier).value)
    }
}
