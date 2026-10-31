import Darwin
import Foundation
import os.log

/// PRIVATE API. Reads another app's Dock badge from LaunchServices.
///
/// When an app sets `NSDockTile.badgeLabel`, LaunchServices stores it in the
/// app's information dictionary under "StatusLabel" ({ "label": "3" }), and
/// the Dock draws it from there. There is no public API to read it.
///
/// Why not the Dock's accessibility tree (`AXStatusLabel`)? The Dock forgets
/// badges that were set before it last restarted, and Portside restarts it
/// at launch for the hide trick. LaunchServices keeps them. It also needs no
/// Accessibility permission.
///
/// Both symbols are looked up with dlopen/dlsym once. If either is missing
/// (an OS update renamed them), `isAvailable` is false and badges are off;
/// nothing crashes.
enum LaunchServicesBadges {
    private typealias CreateASNWithPid = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyInformationItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    /// kLSDefaultSessionID.
    private static let defaultSession: Int32 = -2
    private static let logger = Logger(subsystem: "com.james.portside", category: "DockBadges")

    private static let functions: (CreateASNWithPid, CopyInformationItem)? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformationItem") else {
            logger.error("LaunchServices badge symbols not found, badges unavailable")
            return nil
        }
        return (unsafeBitCast(create, to: CreateASNWithPid.self), unsafeBitCast(copy, to: CopyInformationItem.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// The badge text the app set, or nil for none. Each call is one round
    /// trip to launchservicesd (under a millisecond), so call it off the
    /// main thread.
    static func label(forPID pid: pid_t) -> String? {
        guard let (create, copy) = functions,
              let asn = create(nil, pid)?.takeRetainedValue(),
              let item = copy(defaultSession, asn, "StatusLabel" as CFString)?.takeRetainedValue(),
              let info = item as? [String: Any] else { return nil }
        let label: String
        switch info["label"] {
        case let text as String: label = text
        case let number as NSNumber: label = number.stringValue
        default: return nil
        }
        return label.isEmpty ? nil : label
    }
}
