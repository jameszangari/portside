import AppKit
import Carbon.HIToolbox
import os.log
import SwiftUI

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
    /// Weak, so dropping the last reference runs `deinit` and unregisters.
    private static var handlers: [UInt32: WeakHotKey] = [:]
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
        HotKey.handlers[id] = WeakHotKey(value: self)
        HotKey.logger.info("hotkey \(name, privacy: .public) registered")
    }

    convenience init?(chord: HotkeyChord, name: String, action: @escaping () -> Void) {
        self.init(keyCode: Int(chord.keyCode), modifiers: Int(chord.modifiers), name: name, action: action)
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
            guard read == noErr, let hotKey = HotKey.handlers[hotKeyID.id]?.value else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        if status != noErr {
            logger.error("hotkey event handler not installed (status \(status))")
        }
        return status == noErr
    }
}

private struct WeakHotKey {
    weak var value: HotKey?
}

// MARK: - Chord

/// Key code plus Carbon modifier flags, persisted in dock.json.
/// React analogy: a serializable shortcut value, like `{ key, metaKey }`.
struct HotkeyChord: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon flags: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32

    /// Default for Open Settings: Command-Shift-D.
    /// Distinct from Cmd+Option+D (Dock hiding) and from the local menu's Cmd+,
    static let settingsDefault = HotkeyChord(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// The fixed dock hiding shortcut, Command-Option-D, as on the native Dock.
    static let dockHiding = HotkeyChord(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(cmdKey | optionKey)
    )

    /// Default for Command Center: Option-Space. Spotlight keeps Cmd-Space.
    static let commandCenterDefault = HotkeyChord(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey)
    )

    /// At least Command or Control, so a bare letter never becomes a hotkey.
    /// Option-Space is the one exception: Option alone with a letter types a
    /// character (Option-E, Option-U), Space does not.
    var isRegisterable: Bool {
        modifiers & UInt32(cmdKey | controlKey) != 0
            || (keyCode == UInt32(kVK_Space) && modifiers & UInt32(optionKey) != 0)
    }

    /// Symbols macOS shows in menus: ⌃⌥⇧⌘ plus the key.
    var displayString: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += Self.keyName(keyCode)
        return parts
    }

    /// Build from a key-down event. Returns nil for Escape, bare modifiers,
    /// or chords that are not `isRegisterable`.
    static func from(event: NSEvent) -> HotkeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Modifier-only presses have empty characters and a modifier keyCode.
        switch Int(event.keyCode) {
        case kVK_Escape, kVK_Command, kVK_Shift, kVK_Option, kVK_Control,
             kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl,
             kVK_Function, kVK_CapsLock:
            return nil
        default: break
        }
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        let chord = HotkeyChord(keyCode: UInt32(event.keyCode), modifiers: carbon)
        return chord.isRegisterable ? chord : nil
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "Return"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default: return "Key\(keyCode)"
        }
    }
}

// MARK: - Recorder button

/// Click to record a new global shortcut. Escape cancels; Delete clears.
/// React analogy: a controlled input that listens for one keydown while focused.
struct HotkeyRecorderButton: View {
    let title: String
    let chord: HotkeyChord?
    let defaultChord: HotkeyChord
    let onChange: (HotkeyChord?) -> Void

    @State private var recording = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                recording = true
            } label: {
                Text(recording ? "Type shortcut…" : (chord?.displayString ?? "None"))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minWidth: 108, alignment: .center)
            }
            .buttonStyle(.bordered)
            .disabled(recording)

            if recording {
                Button("Cancel") { recording = false }
                    .buttonStyle(.borderless)
            } else {
                if chord != defaultChord {
                    Button("Reset") { onChange(defaultChord) }
                        .buttonStyle(.borderless)
                }
                if chord != nil {
                    Button("Clear") { onChange(nil) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .background(
            HotkeyCaptureRepresentable(active: recording) { event in
                handleCapture(event)
            }
        )
    }

    private func handleCapture(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            return true
        }
        // Delete / Backspace clears while recording.
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onChange(nil)
            recording = false
            return true
        }
        guard let next = HotkeyChord.from(event: event) else { return false }
        onChange(next)
        recording = false
        return true
    }
}

/// Local key monitor while recording. Lives as an NSView so the monitor is
/// tied to the SwiftUI lifecycle without a custom AppKit controller.
private struct HotkeyCaptureRepresentable: NSViewRepresentable {
    var active: Bool
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.handler = handler
        nsView.setActive(active)
    }

    final class CaptureView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let handler = self.handler else { return event }
                    return handler(event) ? nil : event
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
