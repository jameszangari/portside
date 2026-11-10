import Foundation
import ObjectiveC

/// What one assertion allows on the menu bar: the integer codes of the Apple
/// items to keep and the bundle IDs of the apps to keep. Everything else is
/// hidden by macOS while the assertion is held.
struct MenuBarAssertionConfig: Equatable, Sendable {
    var systemItems: [Int]
    var bundleIdentifiers: [String]
}

/// One held assertion. Invalidating it, or the holder exiting for any reason,
/// brings the hidden items back.
@MainActor
protocol MenuBarAssertionHandle: AnyObject {
    func invalidate()
}

/// The only place that touches the private assertion API (P2-MENU step 2).
/// The live bridge resolves every class and selector at runtime, checks their
/// type encodings against the ones verified on macOS 27.0.1, and refuses to
/// run if anything differs. Tests inject a fake.
@MainActor
protocol MenuBarAssertionBridge: AnyObject {
    /// Nil when the API can be used, else why not.
    var unavailableReason: String? { get }
    /// Starts activation. `completion` runs once on the main actor with an
    /// error description, or nil. Nil handle means nothing was started.
    func activate(_ config: MenuBarAssertionConfig, completion: @escaping @MainActor (String?) -> Void) -> MenuBarAssertionHandle?
}

/// Whether hiding uses the assertion: on from macOS 27, the release that no
/// longer reflows over-wide status items. `PORTSIDE_ASSERTION_HIDING=0` or the
/// defaults key turns it off and falls back to the separator shelf.
enum MenuBarAssertionOptIn {
    static let disableKey = "PortsideAssertionHidingDisabled"
    static let developerKey = "PortsideDeveloperAssertionHiding"
    static let environmentKey = "PORTSIDE_ASSERTION_HIDING"
    static let minimumOSMajor = 27

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        guard osMajor >= minimumOSMajor, environment[environmentKey] != "0" else { return false }
        return !defaults.bool(forKey: disableKey)
    }

    /// The terminal hooks and diagnostics file, off in normal use.
    static func developerHooks(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        defaults.bool(forKey: developerKey) || environment[environmentKey] == "1"
    }
}

/// Private API, loaded with `dlopen` and the Objective-C runtime. Verified on
/// macOS 27.0.1 (26A434): `MBAssessmentModeConfiguration` takes
/// `initWithAllowedSystemItems:allowedBundleIdentifiers:` (two `NSArray`) and
/// `MBAssessmentModeAssertion` takes `activateWithConfiguration:completionHandler:`
/// and `invalidate`. See docs/ARCHITECTURE.md Notes.
@MainActor
final class LiveMenuBarAssertionBridge: MenuBarAssertionBridge {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configurationClass = "MBAssessmentModeConfiguration"
    private static let assertionClass = "MBAssessmentModeAssertion"
    /// Type encodings seen on the verified build. A change means the API moved.
    private static let initEncoding = "@32@0:8@16@24"
    private static let activateEncoding = "v32@0:8@16@?24"
    private static let invalidateEncoding = "v16@0:8"

    private typealias Completion = @convention(block) (AnyObject?) -> Void
    private typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeRawPointer?
    private typealias InitConfiguration = @convention(c) (UnsafeRawPointer, Selector, NSArray, NSArray) -> UnsafeRawPointer?
    private typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, Completion) -> Void
    private typealias Invalidate = @convention(c) (AnyObject, Selector) -> Void

    private static let initSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    private final class Handle: MenuBarAssertionHandle {
        private var object: NSObject?
        init(_ object: NSObject) { self.object = object }

        func invalidate() {
            guard let object else { return }
            self.object = nil
            let imp = class_getMethodImplementation(type(of: object), LiveMenuBarAssertionBridge.invalidateSelector)
            unsafeBitCast(imp, to: Invalidate.self)(object, LiveMenuBarAssertionBridge.invalidateSelector)
        }
    }

    let unavailableReason: String?
    private let configurationType: NSObject.Type?
    private let assertionType: NSObject.Type?

    init() {
        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else {
            unavailableReason = "The menu bar framework could not be loaded."
            configurationType = nil
            assertionType = nil
            return
        }
        guard let configuration = objc_getClass(Self.configurationClass) as? NSObject.Type,
              let assertion = objc_getClass(Self.assertionClass) as? NSObject.Type else {
            unavailableReason = "This macOS has no menu bar assertion."
            configurationType = nil
            assertionType = nil
            return
        }
        let matches = Self.encoding(configuration, Self.initSelector) == Self.initEncoding
            && Self.encoding(assertion, Self.activateSelector) == Self.activateEncoding
            && Self.encoding(assertion, Self.invalidateSelector) == Self.invalidateEncoding
        guard matches else {
            unavailableReason = "This macOS changed the menu bar assertion, so Portside will not use it."
            configurationType = nil
            assertionType = nil
            return
        }
        unavailableReason = nil
        configurationType = configuration
        assertionType = assertion
    }

    private static func encoding(_ type: NSObject.Type, _ selector: Selector) -> String? {
        class_getInstanceMethod(type, selector).flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) }
    }

    func activate(_ config: MenuBarAssertionConfig, completion: @escaping @MainActor (String?) -> Void) -> MenuBarAssertionHandle? {
        guard unavailableReason == nil, let configurationType, let assertionType,
              let configuration = makeConfiguration(configurationType, config) else { return nil }
        let assertion = assertionType.init()
        let imp = class_getMethodImplementation(assertionType, Self.activateSelector)
        let block: Completion = { error in
            let text = error.map { String(describing: $0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(text) } }
        }
        unsafeBitCast(imp, to: Activate.self)(assertion, Self.activateSelector, configuration, block)
        return Handle(assertion)
    }

    /// Raw pointers keep Swift's reference counting out of the init family's
    /// ownership rules: `alloc` returns +1, `init` consumes it and returns +1.
    private func makeConfiguration(_ type: NSObject.Type, _ config: MenuBarAssertionConfig) -> NSObject? {
        guard let meta = object_getClass(type) else { return nil }
        let allocSelector = NSSelectorFromString("alloc")
        let alloc = unsafeBitCast(class_getMethodImplementation(meta, allocSelector), to: Alloc.self)
        guard let raw = alloc(type, allocSelector) else { return nil }
        let initImp = unsafeBitCast(class_getMethodImplementation(type, Self.initSelector), to: InitConfiguration.self)
        guard let made = initImp(raw, Self.initSelector, config.systemItems.map { NSNumber(value: $0) } as NSArray, config.bundleIdentifiers as NSArray) else { return nil }
        return Unmanaged<NSObject>.fromOpaque(made).takeRetainedValue()
    }
}
