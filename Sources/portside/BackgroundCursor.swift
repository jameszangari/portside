import Foundation
import os.log

/// Lets Portside change the cursor while another app is frontmost.
///
/// Portside never activates, and macOS ignores cursor changes from
/// background apps, so the separator's resize cursor would never show.
/// SkyLight (the window server client library) has a per-connection
/// "SetsCursorInBackground" property that lifts that restriction.
///
/// Private API: every symbol is looked up with dlopen/dlsym. If anything is
/// missing (an OS update renamed it), this logs once and does nothing, so
/// Portside keeps working with the normal cursor behavior.
enum BackgroundCursor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias CopyConnectionProperty = @convention(c) (Int32, Int32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32

    private static let logger = Logger(subsystem: "com.james.portside", category: "BackgroundCursor")
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let key = "SetsCursorInBackground" as CFString

    /// Whether the property was set successfully.
    private(set) static var isEnabled = false
    private static var attempted = false

    /// Call once at launch. Safe to call again; it only acts the first time.
    static func enable() {
        guard !attempted else { return }
        attempted = true

        guard let handle = dlopen(skyLightPath, RTLD_LAZY) else {
            logger.error("SkyLight not loadable, background cursor disabled")
            return
        }
        guard let mainConnection: MainConnectionID = symbol(handle, "CGSMainConnectionID", "SLSMainConnectionID"),
              let setProperty: SetConnectionProperty = symbol(handle, "CGSSetConnectionProperty", "SLSSetConnectionProperty") else {
            logger.error("SkyLight connection symbols missing, background cursor disabled")
            return
        }

        let connection = mainConnection()
        let status = setProperty(connection, connection, key, kCFBooleanTrue)
        guard status == 0 else {
            logger.error("SetsCursorInBackground failed with error \(status), background cursor disabled")
            return
        }
        isEnabled = true
        logger.info("SetsCursorInBackground enabled on connection \(connection), read back: \(readBack(handle, connection), privacy: .public)")
    }

    /// Reads the property back for the log. Optional: missing symbol is fine.
    private static func readBack(_ handle: UnsafeMutableRawPointer, _ connection: Int32) -> String {
        guard let copyProperty: CopyConnectionProperty = symbol(handle, "CGSCopyConnectionProperty", "SLSCopyConnectionProperty") else {
            return "unavailable"
        }
        var value: Unmanaged<CFTypeRef>?
        guard copyProperty(connection, connection, key, &value) == 0, let object = value?.takeRetainedValue() else {
            return "unreadable"
        }
        return String(describing: object)
    }

    /// First symbol found among `names`, cast to the C function type `T`.
    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ names: String...) -> T? {
        for name in names {
            if let pointer = dlsym(handle, name) {
                return unsafeBitCast(pointer, to: T.self)
            }
        }
        return nil
    }
}
