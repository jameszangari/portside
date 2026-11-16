import CoreGraphics
import Foundation
import os.log

/// The built-in display's brightness, for the shelf's brightness HUD
/// (SHELF-09). There is no public API on Apple silicon, so this is the only
/// file that uses the private DisplayServices framework, loaded with
/// `dlopen`/`dlsym`. Portside sets brightness only for a brightness key it
/// took with "Replace the macOS indicator" on (SHELF-09b). If the framework
/// or a symbol is missing, `start` returns false and there is no brightness
/// HUD. Main queue only.
final class DisplayBrightnessObserver {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetLevel = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private struct Symbols {
        let get: Get
        let set: SetLevel
        let register: Register
        let unregister: Unregister
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let unregister = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications") else {
            Logger(subsystem: "com.james.portside", category: "NotchHUD").info("brightness: DisplayServices unavailable")
            return nil
        }
        return Symbols(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: SetLevel.self), register: unsafeBitCast(register, to: Register.self),
                       unregister: unsafeBitCast(unregister, to: Unregister.self))
    }()

    var onChange: ((Float) -> Void)?
    private(set) var display: CGDirectDisplayID?
    var running: Bool { display != nil }

    deinit { stop() }

    /// Listens to the built-in display. False with no built-in display
    /// online (lid closed) or no framework.
    @discardableResult
    func start() -> Bool {
        guard display == nil, let symbols = Self.symbols, let builtIn = Self.builtInDisplay() else { return running }
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard symbols.register(builtIn, observer, { _, observer, _, _, info in
            guard let observer, let value = (info as NSDictionary?)?["value"] as? NSNumber else { return }
            let me = Unmanaged<DisplayBrightnessObserver>.fromOpaque(observer).takeUnretainedValue()
            let level = value.floatValue
            if Thread.isMainThread { me.onChange?(level) } else { DispatchQueue.main.async { me.onChange?(level) } }
        }) == 0 else { return false }
        display = builtIn
        return true
    }

    func stop() {
        guard let display, let symbols = Self.symbols else { return }
        _ = symbols.unregister(display, UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        self.display = nil
    }

    /// The built-in display's brightness, 0 to 1.
    var brightness: Float? {
        guard let display, let symbols = Self.symbols else { return nil }
        var value: Float = 0
        return symbols.get(display, &value) == 0 ? value : nil
    }

    /// Sets the built-in display's brightness; false when it cannot, so the
    /// key goes on to macOS.
    func setBrightness(_ value: Float) -> Bool {
        guard let display, let symbols = Self.symbols else { return false }
        return symbols.set(display, min(1, max(0, value))) == 0
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }
}
