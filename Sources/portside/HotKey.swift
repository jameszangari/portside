import Carbon.HIToolbox
import os.log

/// A system-wide keyboard shortcut through Carbon's RegisterEventHotKey.
/// Needs no Accessibility or Input Monitoring permission, and costs nothing
/// until the key is pressed (the window server delivers one event).
///
/// If the same combination is an enabled macOS shortcut (System Settings >
/// Keyboard > Keyboard Shortcuts), macOS handles it first and this one may
/// never fire.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void
    private static var handlers: [UInt32: HotKey] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private static let logger = Logger(subsystem: "com.james.portside", category: "HotKey")

    /// `keyCode` is a virtual key code (`kVK_ANSI_D`), `modifiers` Carbon
    /// flags (`cmdKey | optionKey`). Nil if macOS refused the registration.
    init?(keyCode: Int, modifiers: Int, name: String, action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        guard HotKey.installHandlerIfNeeded() else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5053_4844), id: id) // "PSHD"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            HotKey.logger.error("hotkey \(name, privacy: .public) not registered (status \(status))")
            return nil
        }
        HotKey.handlers[id] = self
        HotKey.logger.info("hotkey \(name, privacy: .public) registered")
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard read == noErr, let hotKey = HotKey.handlers[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        if status != noErr {
            logger.error("hotkey event handler not installed (status \(status))")
        }
        return status == noErr
    }
}
