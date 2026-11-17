import XCTest
@testable import portside

/// Hide and restore against an in-memory `com.apple.dock`; the real domain
/// and the real Dock are never touched.
final class NativeDockTests: XCTestCase {
    /// A fake preferences domain. `synchronize` copies pending writes into
    /// what `read` sees, like cfprefsd.
    final class FakeDomain {
        var values: [String: CFPropertyList] = [:]
        var writes: [String] = []
        var restarts = 0
        var failRestarts = 0
        var dropWrites = false
        var failSynchronize = false
    }

    private var domain: FakeDomain!
    private var directory: URL!
    private var saved: NativeDock.System!

    override func setUpWithError() throws {
        domain = FakeDomain()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-dock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        saved = NativeDock.system
        let domain = domain!, directory = directory!
        NativeDock.system = NativeDock.System(
            read: { domain.values[$0] },
            write: { key, value in
                domain.writes.append(key)
                guard !domain.dropWrites else { return }
                domain.values[key] = value
            },
            synchronize: { !domain.failSynchronize },
            restartDock: {
                domain.restarts += 1
                if domain.failRestarts > 0 {
                    domain.failRestarts -= 1
                    throw NativeDock.Failure.dockRestart("test")
                }
            },
            supportDirectory: { directory }
        )
    }

    override func tearDownWithError() throws {
        NativeDock.system = saved
        try? FileManager.default.removeItem(at: directory)
    }

    private func userSettings() {
        domain.values = [
            "autohide": kCFBooleanFalse,
            "autohide-time-modifier": NSNumber(value: 0.25),
            "orientation": "left" as NSString,
            "tilesize": NSNumber(value: Int64(48)),
            "show-recents": kCFBooleanTrue,
        ]
    }

    private func assertUserSettings(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try NativeDock.read("autohide"), .bool(false), file: file, line: line)
        XCTAssertNil(try NativeDock.read("autohide-delay"), "a key that did not exist is deleted again", file: file, line: line)
        XCTAssertEqual(try NativeDock.read("autohide-time-modifier"), .real(0.25), file: file, line: line)
        XCTAssertEqual(try NativeDock.read("orientation"), .string("left"), file: file, line: line)
        XCTAssertEqual(try NativeDock.read("tilesize"), .integer(48), "an integer stays an integer", file: file, line: line)
        XCTAssertEqual(try NativeDock.read("show-recents"), .bool(true), file: file, line: line)
        XCTAssertNil(try NativeDock.read("magnification"), file: file, line: line)
    }

    func testHideWritesOnlyTheTwoKeysAndRestorePutsBackExactValues() throws {
        userSettings()
        try NativeDock.hide()
        XCTAssertTrue(NativeDock.looksHidden())
        XCTAssertEqual(Set(domain.writes), Set(NativeDock.touchedKeys))
        XCTAssertEqual(domain.restarts, 1)
        let backup = try XCTUnwrap(NativeDock.loadBackup())
        XCTAssertEqual(backup.state, .hidden)
        XCTAssertEqual(backup.entries.map(\.key), NativeDock.savedKeys)

        XCTAssertEqual(try NativeDock.restore(), .restored)
        try assertUserSettings()
        XCTAssertFalse(NativeDock.backupExists)
        XCTAssertFalse(NativeDock.looksHidden())
        XCTAssertEqual(domain.restarts, 2)
    }

    func testBackupSurvivesAnotherProcessReadingIt() throws {
        userSettings()
        try NativeDock.hide()
        // A crashed run's backup, read fresh by the next launch.
        let data = try Data(contentsOf: NativeDock.backupURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NativeDock.Backup.self, from: data)
        XCTAssertEqual(decoded.entries.first { $0.key == "tilesize" }?.value, .integer(48))
        XCTAssertNil(decoded.entries.first { $0.key == "autohide-delay" }?.value)
        XCTAssertNotNil(decoded.entries.first { $0.key == "autohide-delay" })
    }

    func testHideTwiceIsANoOpWhileHidden() throws {
        userSettings()
        try NativeDock.hide()
        domain.writes = []
        try NativeDock.hide()
        XCTAssertTrue(domain.writes.isEmpty)
        XCTAssertEqual(domain.restarts, 1)
    }

    func testUnrestoredBackupBlocksHideAndIsNeverOverwritten() throws {
        userSettings()
        try NativeDock.hide()
        let original = try Data(contentsOf: NativeDock.backupURL)
        // Someone else changed the Dock back while Portside's backup stayed.
        domain.values["autohide-delay"] = NSNumber(value: 0.0)
        XCTAssertThrowsError(try NativeDock.hide()) { error in
            guard case NativeDock.Failure.unrestoredBackup = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: NativeDock.backupURL), original)
    }

    func testDockAlreadyHiddenElsewhereIsRefusedWithoutABackup() throws {
        for delay: CFPropertyList in [NSNumber(value: 5_000.0), NSNumber(value: Int64(1_000))] {
            userSettings()
            domain.values["autohide-delay"] = delay
            domain.writes = []
            XCTAssertThrowsError(try NativeDock.hide()) { error in
                guard case NativeDock.Failure.alreadyHiddenElsewhere = error else { return XCTFail("\(error)") }
            }
            XCTAssertFalse(NativeDock.backupExists, "a hidden Dock must never be saved as the real value")
            XCTAssertTrue(domain.writes.isEmpty)
        }
    }

    func testFailedRestartRollsBackAndRemovesTheBackup() throws {
        userSettings()
        domain.failRestarts = 1
        XCTAssertThrowsError(try NativeDock.hide())
        try assertUserSettings()
        XCTAssertFalse(NativeDock.backupExists, "rollback restored and verified, so the backup goes")
    }

    func testRollbackThatAlsoFailsKeepsTheBackupForTheNextLaunch() throws {
        userSettings()
        domain.failRestarts = 2
        XCTAssertThrowsError(try NativeDock.hide())
        XCTAssertEqual(try NativeDock.loadBackup()?.state, .applying)
        NativeDock.recoverIfNeeded()
        try assertUserSettings()
        XCTAssertFalse(NativeDock.backupExists)
    }

    func testHideThatDoesNotReadBackRollsBack() throws {
        userSettings()
        domain.dropWrites = true
        XCTAssertThrowsError(try NativeDock.hide()) { error in
            guard case NativeDock.Failure.verify = error else { return XCTFail("\(error)") }
        }
        try assertUserSettings()
        XCTAssertFalse(NativeDock.backupExists)
    }

    func testRestoreThatDoesNotReadBackKeepsTheBackup() throws {
        userSettings()
        try NativeDock.hide()
        domain.dropWrites = true
        XCTAssertThrowsError(try NativeDock.restore())
        XCTAssertTrue(NativeDock.backupExists)
        domain.dropWrites = false
        XCTAssertEqual(try NativeDock.restore(), .restored)
        try assertUserSettings()
    }

    func testFailedSynchronizeKeepsTheBackup() throws {
        userSettings()
        try NativeDock.hide()
        domain.failSynchronize = true
        XCTAssertThrowsError(try NativeDock.restore()) { error in
            guard case NativeDock.Failure.synchronize = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(NativeDock.backupExists)
    }

    func testRestorePutsBackKeysChangedWhileHidden() throws {
        userSettings()
        try NativeDock.hide()
        domain.values["orientation"] = "bottom" as NSString
        domain.values["magnification"] = kCFBooleanTrue
        try NativeDock.restore()
        try assertUserSettings()
    }

    func testRestoreWithNoBackupChangesNothing() throws {
        userSettings()
        XCTAssertEqual(try NativeDock.restore(), .nothingToRestore)
        XCTAssertTrue(domain.writes.isEmpty)
        XCTAssertEqual(domain.restarts, 0)
    }

    func testDamagedBackupIsLeftInPlace() throws {
        userSettings()
        try FileManager.default.createDirectory(at: NativeDock.backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: NativeDock.backupURL)
        XCTAssertThrowsError(try NativeDock.loadBackup()) { error in
            guard case NativeDock.Failure.unreadableBackup = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try NativeDock.hide(), "never hide over a backup it cannot read")
        NativeDock.recoverIfNeeded()
        XCTAssertTrue(NativeDock.backupExists)
        XCTAssertTrue(domain.writes.isEmpty)
    }

    func testArraysAndDictionariesRoundTripThroughTheBackup() throws {
        let value: CFPropertyList = ["a": [1, 2]] as NSDictionary
        let saved = try NativeDock.Value(value)
        guard case .plist = saved else { return XCTFail("\(saved)") }
        XCTAssertEqual(try saved.propertyList() as? NSDictionary, value as? NSDictionary)
    }
}
