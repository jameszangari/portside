import Foundation
import os.log

/// Which Spaces the window server has a window on, and a way to put it on
/// the current one.
///
/// macOS can drop a long-lived all-Spaces window from all but one Space
/// (seen on macOS 27 after hours or days and several wakes): the dock panel
/// kept sliding in on a Space nobody was looking at. `NSWindow.isOnActiveSpace`
/// still says true then, so the window server is asked directly.
///
/// Private API: every symbol is looked up with dlopen/dlsym. If anything is
/// missing, `isOffCurrentSpace` answers false and nothing is repaired, which
/// is the behavior Portside had before.
enum WindowSpaces {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias MoveWindowsToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void

    private struct Symbols {
        let connection: Int32
        let spacesForWindows: CopySpacesForWindows
        let displaySpaces: CopyManagedDisplaySpaces
        let move: MoveWindowsToManagedSpace?
    }

    private static let logger = Logger(subsystem: "com.james.portside", category: "WindowSpaces")
    /// All Spaces kinds: current, others, and user.
    private static let allSpacesMask: Int32 = 0x7

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            logger.error("SkyLight not loadable, Space checks disabled")
            return nil
        }
        guard let main = dlsym(handle, "SLSMainConnectionID"),
              let spaces = dlsym(handle, "SLSCopySpacesForWindows"),
              let displays = dlsym(handle, "SLSCopyManagedDisplaySpaces") else {
            logger.error("SkyLight Space symbols missing, Space checks disabled")
            return nil
        }
        return Symbols(
            connection: unsafeBitCast(main, to: MainConnectionID.self)(),
            spacesForWindows: unsafeBitCast(spaces, to: CopySpacesForWindows.self),
            displaySpaces: unsafeBitCast(displays, to: CopyManagedDisplaySpaces.self),
            move: dlsym(handle, "SLSMoveWindowsToManagedSpace").map { unsafeBitCast($0, to: MoveWindowsToManagedSpace.self) }
        )
    }()

    /// Each display's current Space.
    private static func currentSpaces(_ s: Symbols) -> [UInt64] {
        guard let displays = s.displaySpaces(s.connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64 }
    }

    private static func spaces(of windowNumber: Int, _ s: Symbols) -> [UInt64] {
        let list = [windowNumber] as CFArray
        return (s.spacesForWindows(s.connection, allSpacesMask, list)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    /// The window is listed on some Spaces but none of the current ones. An
    /// empty list (a fresh all-Spaces window can report none) counts as fine.
    static func isOffCurrentSpace(_ windowNumber: Int) -> Bool {
        guard windowNumber > 0, let s = symbols else { return false }
        return isOff(listed: spaces(of: windowNumber, s), current: currentSpaces(s))
    }

    static func isOff(listed: [UInt64], current: [UInt64]) -> Bool {
        guard !listed.isEmpty, !current.isEmpty else { return false }
        return Set(listed).isDisjoint(with: current)
    }

    /// Move the window onto the first display's current Space. AppKit then
    /// spreads an all-Spaces window to the others again.
    static func moveToCurrentSpace(_ windowNumber: Int) {
        guard windowNumber > 0, let s = symbols, let move = s.move, let space = currentSpaces(s).first else { return }
        move(s.connection, [windowNumber] as CFArray, space)
    }

    /// For the log: listed Spaces against the current ones.
    static func describe(_ windowNumber: Int) -> String {
        guard let s = symbols else { return "unavailable" }
        return "on \(spaces(of: windowNumber, s)), current \(currentSpaces(s))"
    }
}
