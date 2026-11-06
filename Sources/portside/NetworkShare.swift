import Foundation
import NetFS
import os.log

/// Mounts a network share (smb://, afp://, nfs://) by its server URL, for
/// folder stacks pinned from a share that has since disconnected. Public
/// NetFS API: uses saved Keychain credentials and shows the system
/// authentication prompt only when it needs one.
enum NetworkShare {
    private static let logger = Logger(subsystem: "com.james.portside", category: "Stacks")

    /// Mounts at the system default location (`/Volumes`). `completion` runs
    /// on the main thread with whether the mount succeeded.
    static func mount(_ serverURL: URL, completion: @escaping (Bool) -> Void) {
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            serverURL as CFURL, nil, nil, nil, nil, nil, &requestID, .main
        ) { status, _, mountpoints in
            let paths = (mountpoints as? [String]) ?? []
            logger.info("share mount finished, status \(status), \(paths.count) mountpoint(s)")
            // EEXIST: already mounted, which is also fine.
            completion(status == 0 || status == EEXIST)
        }
        if status != 0 {
            logger.error("share mount did not start, status \(status)")
            completion(false)
        }
    }
}
