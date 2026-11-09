import XCTest
@testable import portside

/// Settings > Integrations state: module switches, saved choices, permission
/// rows for denied and unavailable scopes, and the restricted preset. Model
/// setters write dock.json, so these run only under an isolated home.
@MainActor
final class IntegrationSettingsTests: XCTestCase {
    /// Holds one long task and one cleanup while running.
    private final class WorkModule: PortsideModule {
        let id: ModuleID
        let title: String
        let isSensitive: Bool
        let dependencies: [ModuleDependency]
        let fallback = "Works without it."
        var taskCanceled = false
        var cleanedUp = 0

        init(_ raw: String, sensitive: Bool = true, dependencies: [ModuleDependency] = []) {
            id = ModuleID(raw)!
            title = raw.capitalized
            isSensitive = sensitive
            self.dependencies = dependencies
        }

        func start(_ context: ModuleContext) throws {
            context.task { [weak self] in
                while !Task.isCancelled { await Task.yield() }
                self?.taskCanceled = true
            }
            context.onStop { [weak self] in self?.cleanedUp += 1 }
        }
    }

    private final class CoreModule: PortsideModule {
        let id = ModuleID("core")!
        let title = "Core"
        let isRequired = true
        func start(_ context: ModuleContext) throws {}
    }

    private final class Scope {
        var state: PermissionState
        var requests: [String] = []
        init(_ state: PermissionState) { self.state = state }
    }

    private var gate: PermissionGate!
    private var registry: ModuleRegistry!
    private var model: DockModel!

    override func setUp() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.hasPrefix("/tmp") || home.hasPrefix("/private/tmp") else {
            throw XCTSkip("needs CFFIXED_USER_HOME under /tmp")
        }
        gate = PermissionGate()
        registry = ModuleRegistry(commands: CommandRegistry(permissions: gate), permissions: gate)
        model = DockModel()
    }

    /// dock.json under the isolated home (same path DockModel writes).
    private func savedFile() throws -> URL {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        return support.appendingPathComponent("com.james.portside/dock.json")
    }

    private func register(_ name: String, _ scope: Scope, requestable: Bool = true) {
        gate.register(AppPermissionAdapter(
            name: name,
            state: { scope.state },
            request: requestable ? { feature in scope.requests.append(feature); return true } : nil
        ))
    }

    private func row(_ settings: IntegrationSettings, _ raw: String) -> IntegrationSettings.ModuleRow? {
        settings.modules.first { $0.id.rawValue == raw }
    }

    // MARK: Listing

    func testListsModulesAndScopesWithoutRequestingAnything() throws {
        let capture = Scope(.notRequested)
        register("capture", capture)
        try registry.register(CoreModule())
        try registry.register(WorkModule("previews", dependencies: [.permission(.app("capture"))]))
        registry.enableSaved(model.modules)

        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)

        XCTAssertEqual(settings.modules.map(\.id.rawValue), ["core", "previews"])
        XCTAssertEqual(row(settings, "core")?.state, .running)
        XCTAssertEqual(row(settings, "core")?.canToggle, false)
        XCTAssertEqual(row(settings, "previews")?.isEnabled, false, "optional modules start off")
        XCTAssertEqual(row(settings, "previews")?.permissions, [.app("capture")])
        XCTAssertEqual(settings.permissions.map(\.scope), [.app("capture")])
        XCTAssertEqual(settings.permissions.first?.usedBy, ["Previews"])
        XCTAssertEqual(settings.permissions.first?.canRequest, true)
        XCTAssertTrue(capture.requests.isEmpty, "building the pane never requests")
    }

    // MARK: Switches and persistence

    func testTurningOnAndOffSavesAndReleasesWork() async throws {
        let module = WorkModule("indexer")
        try registry.register(module)
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)

        settings.setEnabled(true, for: module.id)
        XCTAssertEqual(row(settings, "indexer")?.state, .running)
        XCTAssertEqual(model.modules.savedEnabled(module.id), true)
        XCTAssertEqual(registry.resourceCount(of: module.id), 2)
        let saved = try Fixture.object(Data(contentsOf: savedFile()))
        XCTAssertEqual(((saved["modules"] as? [String: Any])?["indexer"] as? [String: Any])?["enabled"] as? Bool, true)

        settings.setEnabled(false, for: module.id)
        XCTAssertEqual(row(settings, "indexer")?.state, .disabled)
        XCTAssertEqual(model.modules.savedEnabled(module.id), false)
        XCTAssertEqual(registry.resourceCount(of: module.id), 0)
        XCTAssertEqual(module.cleanedUp, 1)
        for _ in 0..<20 where !module.taskCanceled { await Task.yield() }
        XCTAssertTrue(module.taskCanceled, "turning off cancels the module's task")
    }

    func testRequiredModuleCannotBeTurnedOff() throws {
        try registry.register(CoreModule())
        registry.enableSaved(model.modules)
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)

        settings.setEnabled(false, for: ModuleID("core")!)
        XCTAssertEqual(row(settings, "core")?.state, .running)
        XCTAssertNil(model.modules.savedEnabled(ModuleID("core")!), "nothing saved for a required module")
    }

    // MARK: Denied and unavailable

    func testDeniedPermissionWaitsWithReasonAndRequestsOnlyOnAsk() throws {
        let capture = Scope(.denied)
        register("capture", capture)
        let module = WorkModule("previews", dependencies: [.permission(.app("capture"))])
        try registry.register(module)
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)

        settings.setEnabled(true, for: module.id)
        guard case .waiting(let reason)? = row(settings, "previews")?.state else {
            return XCTFail("denied permission should leave the module waiting")
        }
        XCTAssertTrue(reason.contains("denied"))
        XCTAssertEqual(row(settings, "previews")?.fallback, "Works without it.")
        XCTAssertEqual(registry.resourceCount(of: module.id), 0, "no work while waiting")
        XCTAssertEqual(settings.permissions.first?.state, .denied)
        XCTAssertTrue(capture.requests.isEmpty)

        settings.request(.app("capture"))
        XCTAssertEqual(capture.requests, ["Previews"])

        capture.state = .granted
        settings.reload()
        XCTAssertEqual(row(settings, "previews")?.state, .running)
        XCTAssertEqual(settings.permissions.first?.canRequest, false)

        // Revoked while running: stops and releases, stays enabled.
        capture.state = .denied
        settings.reload()
        XCTAssertEqual(registry.resourceCount(of: module.id), 0)
        XCTAssertEqual(row(settings, "previews")?.isEnabled, true)
    }

    func testUnavailableAndUnregisteredScopesCannotBeRequested() throws {
        let managed = Scope(.unavailable)
        register("managed", managed)
        try registry.register(WorkModule("hooks", dependencies: [.permission(.app("managed")), .permission(.app("missing"))]))
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)

        XCTAssertEqual(settings.permissions.map(\.scope), [.app("managed"), .app("missing")])
        XCTAssertEqual(settings.permissions.map(\.state), [.unavailable, .unavailable])
        XCTAssertEqual(settings.permissions.map(\.canRequest), [false, false])
        XCTAssertTrue(PermissionState.unavailable.detail.contains("administrator"))

        settings.request(.app("missing"))
        XCTAssertTrue(managed.requests.isEmpty)
        settings.setEnabled(true, for: ModuleID("hooks")!)
        guard case .waiting(let reason)? = row(settings, "hooks")?.state else {
            return XCTFail("unavailable permission should leave the module waiting")
        }
        XCTAssertTrue(reason.contains("unavailable on this Mac"))
    }

    func testSetupWalksMissingPermissionsInOrderAndAsksOnlyForTheOnePicked() throws {
        let first = Scope(.denied), second = Scope(.notRequested), done = Scope(.granted), blocked = Scope(.unavailable)
        for (name, scope) in [("first", first), ("done", done), ("blocked", blocked), ("second", second)] {
            gate.register(AppPermissionAdapter(name: name, state: { scope.state }, request: { scope.requests.append($0); return true }))
        }
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)
        XCTAssertEqual(settings.missingPermissions.map(\.scope), [.app("first"), .app("second")], "granted and unavailable are skipped")
        XCTAssertTrue(first.requests.isEmpty && second.requests.isEmpty, "listing asks for nothing")
        settings.request(try XCTUnwrap(settings.missingPermissions.first).scope)
        XCTAssertEqual(first.requests.count, 1)
        XCTAssertTrue(second.requests.isEmpty, "one at a time")
        first.state = .granted
        settings.reload()
        XCTAssertEqual(settings.missingPermissions.map(\.scope), [.app("second")])
        second.state = .granted
        settings.reload()
        XCTAssertTrue(settings.missingPermissions.isEmpty)
    }

    func testScopeWithoutRequesterShowsNoRequest() {
        register("plain", Scope(.notRequested), requestable: false)
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)
        XCTAssertEqual(settings.permissions.first?.canRequest, false)
        XCTAssertFalse(gate.request(.app("plain"), forFeature: "test"))
    }

    // MARK: Restricted preset

    func testRestrictedPresetTurnsOffSensitiveModulesAndHoldsThemOff() throws {
        let sensitive = WorkModule("scripts")
        let plain = WorkModule("clock", sensitive: false)
        try registry.register(CoreModule())
        try registry.register(sensitive)
        try registry.register(plain)
        registry.enableSaved(model.modules)
        let settings = IntegrationSettings(registry: registry, permissions: gate, model: model)
        settings.setEnabled(true, for: sensitive.id)
        settings.setEnabled(true, for: plain.id)

        settings.setRestricted(true)
        XCTAssertTrue(model.restrictedMode)
        XCTAssertEqual(row(settings, "scripts")?.state, .disabled)
        XCTAssertEqual(row(settings, "scripts")?.isRestricted, true)
        XCTAssertEqual(row(settings, "scripts")?.canToggle, false)
        XCTAssertEqual(model.modules.savedEnabled(sensitive.id), false)
        XCTAssertEqual(registry.resourceCount(of: sensitive.id), 0)
        XCTAssertEqual(row(settings, "clock")?.state, .running, "non-sensitive modules keep running")
        XCTAssertEqual(row(settings, "core")?.state, .running)

        settings.setEnabled(true, for: sensitive.id)
        XCTAssertEqual(row(settings, "scripts")?.state, .disabled, "held off while restricted")

        settings.setRestricted(false)
        XCTAssertEqual(row(settings, "scripts")?.state, .disabled, "turning restricted off turns nothing on")
        settings.setEnabled(true, for: sensitive.id)
        XCTAssertEqual(row(settings, "scripts")?.state, .running)
    }

    func testRestrictedModePersistsAndLaunchKeepsSensitiveModulesOff() throws {
        model.setRestrictedMode(true)
        let saved = try Fixture.object(Data(contentsOf: savedFile()))
        XCTAssertEqual(saved["restrictedMode"] as? Bool, true)
        XCTAssertTrue(DockModel.load().restrictedMode)

        model.setRestrictedMode(false)
        let cleared = try Fixture.object(Data(contentsOf: savedFile()))
        XCTAssertNil(cleared["restrictedMode"], "off writes no key")
        XCTAssertFalse(DockModel.load().restrictedMode)

        // A file that says restricted but still has a sensitive module on
        // (hand edit, older build): launch keeps it off.
        try registry.register(WorkModule("scripts"))
        try registry.register(WorkModule("clock", sensitive: false))
        var choices = ModuleSettings()
        choices.setEnabled(true, for: ModuleID("scripts")!)
        choices.setEnabled(true, for: ModuleID("clock")!)
        registry.enableSaved(choices, restricted: true)
        XCTAssertEqual(registry.state(of: ModuleID("scripts")!), .disabled)
        XCTAssertEqual(registry.state(of: ModuleID("clock")!), .running)
    }
}
