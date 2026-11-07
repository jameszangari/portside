import XCTest
@testable import portside

/// Versioned module settings in dock.json: defaults, round trips of values
/// this build does not know, schema backups and rollback. Checked by value.
final class ModuleSettingsTests: XCTestCase {
    private let commandCenter = ModuleID("commandCenter")!
    private let core = PortsideCoreModule.moduleID

    private func decode(_ name: String) throws -> DockModel {
        try JSONDecoder().decode(DockModel.self, from: Fixture.data(name))
    }

    private func resave(_ model: DockModel, over original: Data) throws -> [String: Any] {
        try Fixture.object(DockModel.mergingUnknownKeys(from: original, into: JSONEncoder().encode(model)))
    }

    // MARK: Defaults

    func testLegacyFileHasNoModuleChoicesAndOptionalModulesStayOff() throws {
        let model = try decode("legacy-flat-pins.json")
        XCTAssertTrue(model.modules.isEmpty)
        XCTAssertFalse(model.modules.isEnabled(commandCenter, required: false))
        XCTAssertTrue(model.modules.isEnabled(core, required: true))
        XCTAssertEqual(DockModel.schema(of: try Fixture.data("legacy-flat-pins.json")), 0)
    }

    func testLegacyResaveStampsSchemaAndWritesNoModules() throws {
        let original = try Fixture.data("legacy-flat-pins.json")
        let json = try resave(try decode("legacy-flat-pins.json"), over: original)
        XCTAssertEqual(json["settingsSchema"] as? Int, DockModel.settingsSchema)
        XCTAssertNil(json["modules"], "no choices made, nothing written")
        XCTAssertNotNil(json["futureModules"])
    }

    func testFreshModelUsesCurrentSchema() throws {
        let json = try Fixture.object(JSONEncoder().encode(DockModel()))
        XCTAssertEqual(json["settingsSchema"] as? Int, DockModel.settingsSchema)
        XCTAssertNil(json["modules"])
    }

    // MARK: Current schema

    func testSavedChoicesLoadAndRequiredModulesIgnoreThem() throws {
        let model = try decode("modules-current.json")
        XCTAssertTrue(model.modules.isEnabled(commandCenter, required: false))
        XCTAssertEqual(model.modules.savedEnabled(ModuleID("windowSwitcher")!), false)
        XCTAssertNil(model.modules.savedEnabled(ModuleID("neverSeen")!))
        // The core module's saved false cannot turn Portside's own commands off.
        XCTAssertEqual(model.modules.savedEnabled(core), false)
        XCTAssertTrue(model.modules.isEnabled(core, required: true))
        XCTAssertEqual(model.edge, .right)
    }

    func testNestedModuleKeysAndUnknownTopLevelRoundTrip() throws {
        let original = try Fixture.data("modules-current.json")
        let source = try Fixture.object(original)
        let json = try resave(try decode("modules-current.json"), over: original)
        XCTAssertEqual(json["modules"] as? NSDictionary, source["modules"] as? NSDictionary)
        XCTAssertEqual(json["laterTopLevel"] as? NSDictionary, source["laterTopLevel"] as? NSDictionary)
    }

    func testChangingOneChoiceKeepsTheEntrysOtherKeys() throws {
        var settings = try decode("modules-current.json").modules
        settings.setEnabled(false, for: commandCenter)
        settings.setEnabled(true, for: ModuleID("brandNew")!)
        let json = try Fixture.object(JSONEncoder().encode(settings))
        let entry = try XCTUnwrap(json["commandCenter"] as? [String: Any])
        XCTAssertEqual(entry["enabled"] as? Bool, false)
        XCTAssertEqual(entry["hotkey"] as? String, "option-space")
        XCTAssertEqual((entry["recent"] as? [String: Any])?["limit"] as? Int, 20)
        XCTAssertEqual((json["windowSwitcher"] as? [String: Any])?["previews"] as? Bool, true)
        XCTAssertEqual((json["brandNew"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    // MARK: Malformed

    func testMalformedModuleValuesLoadAsOffAndAreKept() throws {
        let original = try Fixture.data("malformed-modules.json")
        let model = try decode("malformed-modules.json")
        for raw in ["textFlag", "stringBool", "numberBool", "nullEntry"] {
            XCTAssertNil(model.modules.savedEnabled(ModuleID(raw)!), raw)
            XCTAssertFalse(model.modules.isEnabled(ModuleID(raw)!, required: false), raw)
        }
        XCTAssertEqual(DockModel.schema(of: original), 0, "a non-integer schema reads as legacy")
        XCTAssertEqual(model.edge, .left)
        let json = try resave(model, over: original)
        XCTAssertEqual(json["modules"] as? NSDictionary, try Fixture.object(original)["modules"] as? NSDictionary)
    }

    func testModulesThatIsNotAnObjectIsKeptUntilAChoiceReplacesIt() throws {
        var raw = try Fixture.object(Fixture.data("modules-current.json"))
        raw["modules"] = [1, "two"]
        let model = try JSONDecoder().decode(DockModel.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(model.modules.savedEnabled(commandCenter))
        XCTAssertEqual(try Fixture.object(JSONEncoder().encode(model))["modules"] as? NSArray, [1, "two"])

        var settings = model.modules
        settings.setEnabled(true, for: commandCenter)
        XCTAssertEqual(settings.savedEnabled(commandCenter), true)
    }

    func testTruncatedFileFailsToDecode() {
        XCTAssertThrowsError(try decode("truncated.json"))
    }

    // MARK: Future and downgrade

    func testFutureSchemaLoadsWithFallbacksAndKeepsItsSchema() throws {
        let original = try Fixture.data("future-schema.json")
        let model = try decode("future-schema.json")
        XCTAssertEqual(model.edge, .bottom, "unknown enum value falls back")
        XCTAssertEqual(model.iconStyle, .matchSystem)
        XCTAssertEqual(model.iconSize, 52)
        XCTAssertTrue(model.modules.isEnabled(commandCenter, required: false))

        let source = try Fixture.object(original)
        let json = try resave(model, over: original)
        XCTAssertEqual(json["settingsSchema"] as? Int, 99, "never written down to this build's schema")
        XCTAssertEqual(json["modules"] as? NSDictionary, source["modules"] as? NSDictionary)
        XCTAssertEqual(json["workspaces"] as? NSArray, source["workspaces"] as? NSArray)
        XCTAssertEqual(json["savedByVersion"] as? String, AppInfo.version)
    }

    func testSchemaBackupNamesAndOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = try Fixture.data("legacy-flat-pins.json")
        let older = try XCTUnwrap(DockModel.backUpForSchemaChange(legacy, in: directory))
        XCTAssertEqual(older.lastPathComponent, "dock.json.schema-0")
        XCTAssertEqual(try Data(contentsOf: older), legacy)
        XCTAssertNil(DockModel.backUpForSchemaChange(Data("{}".utf8), in: directory), "first copy is kept")
        XCTAssertEqual(try Data(contentsOf: older), legacy)

        let future = try Fixture.data("future-schema.json")
        XCTAssertEqual(DockModel.backUpForSchemaChange(future, in: directory)?.lastPathComponent, "dock.json.from-schema-99")
        XCTAssertNil(DockModel.backUpForSchemaChange(try Fixture.data("modules-current.json"), in: directory))
    }

    // MARK: Real load path (isolated home only)

    private func isolatedStorage() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasPrefix("/tmp") || home.hasPrefix("/private/tmp") else {
            throw XCTSkip("needs CFFIXED_USER_HOME under /tmp")
        }
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let directory = support.appendingPathComponent("com.james.portside")
        guard directory.path.contains(home) || directory.path.contains("/tmp/") else {
            throw XCTSkip("Application Support is not under the isolated home")
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testLegacyMigrationBacksUpOnceAndRollbackRestoresIt() throws {
        let directory = try isolatedStorage()
        let file = directory.appendingPathComponent("dock.json")
        let backup = directory.appendingPathComponent("dock.json.schema-0")
        let legacy = try Fixture.data("legacy-flat-pins.json")
        try legacy.write(to: file)

        let model = DockModel.load()
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        model.setModuleEnabled(commandCenter, true)
        let saved = try Fixture.object(Data(contentsOf: file))
        XCTAssertEqual(saved["settingsSchema"] as? Int, DockModel.settingsSchema)
        XCTAssertEqual((saved["modules"] as? [String: Any])?.keys.sorted(), ["commandCenter"])

        // Current schema now: loading again makes no second copy.
        try Data("{}".utf8).write(to: backup)
        let reloaded = DockModel.load()
        XCTAssertTrue(reloaded.modules.isEnabled(commandCenter, required: false))
        XCTAssertEqual(try Data(contentsOf: backup), Data("{}".utf8))

        // Rollback: put the pre-migration copy back and load it.
        try FileManager.default.removeItem(at: file)
        try legacy.write(to: file)
        let restored = DockModel.load()
        XCTAssertEqual(restored.entries.count, 3)
        XCTAssertEqual(restored.edge, .left)
        XCTAssertTrue(restored.modules.isEmpty)
    }

    func testFutureFileBacksUpAndUnreadableFileIsSetAside() throws {
        let directory = try isolatedStorage()
        let file = directory.appendingPathComponent("dock.json")
        let future = try Fixture.data("future-schema.json")
        try future.write(to: file)

        let model = DockModel.load()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("dock.json.from-schema-99")), future)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("dock.json.from-99.0.0")), future)
        try model.save()
        let saved = try Fixture.object(Data(contentsOf: file))
        XCTAssertEqual(saved["settingsSchema"] as? Int, 99)
        XCTAssertEqual(saved["modules"] as? NSDictionary, try Fixture.object(future)["modules"] as? NSDictionary)
        XCTAssertNotNil(saved["workspaces"])

        try Fixture.data("truncated.json").write(to: file)
        _ = DockModel.load()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("dock.json.unreadable-") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside)), try Fixture.data("truncated.json"))
    }
}

/// Saved choices applied at launch through the registry.
@MainActor
final class ModuleRegistrySettingsTests: XCTestCase {
    private final class OptionalModule: PortsideModule {
        let id: ModuleID
        let title: String
        init(_ raw: String) { id = ModuleID(raw)!; title = raw }
        func start(_ context: ModuleContext) throws {}
    }

    private final class RequiredModule: PortsideModule {
        let id = ModuleID("core")!
        let title = "Core"
        let isRequired = true
        func start(_ context: ModuleContext) throws {}
    }

    func testEnableSavedStartsRequiredAndChosenModulesOnly() throws {
        let permissions = PermissionGate()
        let registry = ModuleRegistry(commands: CommandRegistry(permissions: permissions), permissions: permissions)
        try registry.register(RequiredModule())
        try registry.register(OptionalModule("chosen"))
        try registry.register(OptionalModule("fresh"))
        try registry.register(OptionalModule("declined"))

        var settings = ModuleSettings()
        settings.setEnabled(false, for: ModuleID("core")!)
        settings.setEnabled(true, for: ModuleID("chosen")!)
        settings.setEnabled(false, for: ModuleID("declined")!)
        settings.setEnabled(true, for: ModuleID("notInstalled")!)
        registry.enableSaved(settings)

        XCTAssertEqual(registry.state(of: ModuleID("core")!), .running)
        XCTAssertEqual(registry.state(of: ModuleID("chosen")!), .running)
        XCTAssertEqual(registry.state(of: ModuleID("fresh")!), .disabled, "new modules start off")
        XCTAssertEqual(registry.state(of: ModuleID("declined")!), .disabled)
        XCTAssertNil(registry.state(of: ModuleID("notInstalled")!))
        XCTAssertEqual(settings.savedEnabled(ModuleID("notInstalled")!), true, "kept for a build that has it")
    }
}
