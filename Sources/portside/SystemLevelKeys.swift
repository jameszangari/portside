import AppKit
import CoreGraphics
import os.log

/// A volume or brightness key from the keyboard's media row.
enum SystemLevelKey: Equatable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    /// From an `NX_SYSDEFINED` aux-control event's `data1` (subtype 8): the
    /// key in the high 16 bits, 0xA (down) or 0xB (up) in bits 8 to 15.
    static func decode(data1: Int) -> (key: SystemLevelKey, down: Bool)? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        let key: SystemLevelKey
        switch code {
        case 0: key = .volumeUp        // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown      // NX_KEYTYPE_SOUND_DOWN
        case 2: key = .brightnessUp    // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: key = .mute            // NX_KEYTYPE_MUTE
        default: return nil
        }
        return (key, state == 0xA)
    }

    /// The level after one press, as macOS steps it: 1/16, or 1/64 with
    /// Option and Shift held.
    static func step(_ value: Float, up: Bool, fine: Bool) -> Float {
        let size: Float = fine ? 1 / 64 : 1 / 16
        // Off the grid (set elsewhere), the first press snaps to it.
        let position = value / size
        let onGrid = abs(position - position.rounded()) < 0.01
        let next = onGrid ? position.rounded() + (up ? 1 : -1) : up ? position.rounded(.up) : position.rounded(.down)
        return min(1, max(0, next * size))
    }
}

/// Hides the macOS volume and brightness indicators (SHELF-09b): an active
/// event tap takes the media row's volume, mute and brightness keys, and
/// `handle` applies the change itself, so macOS never draws its own. A key
/// `handle` declines (returns false) goes on to macOS unchanged. Needs
/// Accessibility; without it `start` returns false and nothing is taken.
/// Main run loop only.
final class SystemLevelKeyTap {
    /// The key went down (or repeated); true when it was handled.
    var handle: ((SystemLevelKey, _ fine: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose down was taken, so their up is taken too.
    private var taken: Set<Int> = []
    private let logger = Logger(subsystem: "com.james.portside", category: "NotchHUD")

    var running: Bool { tap != nil }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<SystemLevelKeyTap>.fromOpaque(info).takeUnretainedValue()
            return tap.process(type, event)
        }, userInfo: me) else {
            logger.info("keys: event tap refused (Accessibility off)")
            return false
        }
        let loopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = loopSource
        logger.info("keys: replacing the macOS volume and brightness indicators")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        taken = []
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a slow tap off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
              let (key, down) = SystemLevelKey.decode(data1: ns.data1) else { return Unmanaged.passUnretained(event) }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        if !down { return taken.remove(code) != nil ? nil : Unmanaged.passUnretained(event) }
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        guard handle?(key, fine) == true else { return Unmanaged.passUnretained(event) }
        taken.insert(code)
        return nil
    }
}
