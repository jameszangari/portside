import AudioToolbox
import CoreAudio
import Foundation

/// The volume or brightness level the shelf strip shows for a moment after
/// it changes (SHELF-09): a symbol left of the notch, a bar right of it.
struct NotchHUD: Equatable {
    enum Kind: Equatable { case volume, brightness }
    let kind: Kind
    /// 0 to 1.
    let level: Double
    var muted = false

    static let duration: TimeInterval = 1.5
    /// Each side's room: the symbol on one, the bar, a gap and the number
    /// on the other, plus the strip's 12 pt margins.
    static let sideWidth: CGFloat = 12 + 64 + 8 + 26 + 12

    /// The strip width that fits the HUD. Without a notch the middle third
    /// stands in for it, so each side is a third of the strip.
    static func stripWidth(notch: CGFloat, flare: CGFloat) -> CGFloat {
        notch > 0 ? notch + 2 * sideWidth + flare : 3 * sideWidth + flare
    }

    var symbol: String {
        switch kind {
        case .volume:
            // The view fills the waves with the level (variable value).
            return muted || level <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    /// 0 to 100, as the strip prints it.
    var percent: Int { Int((min(1, max(0, level)) * 100).rounded()) }

    var label: String {
        let percent = "\(percent)%"
        switch kind {
        case .volume: return muted ? "Volume muted" : "Volume \(percent)"
        case .brightness: return "Brightness \(percent)"
        }
    }
}

/// Tells a brightness key press from auto-brightness. A key moves the level
/// by about 1/16 at once, or in a quick ramp; ambient light drifts in small
/// steps over seconds. Once the HUD shows, every change updates it.
struct NotchBrightnessFilter {
    static let jump: Float = 0.04
    static let window: TimeInterval = 0.5

    private var last: Float?
    private var anchor: (value: Float, at: Date)?

    init(last: Float? = nil) { self.last = last }

    /// Whether `value` should show the HUD. `showing`: the HUD is up now.
    mutating func accept(_ value: Float, at now: Date, showing: Bool) -> Bool {
        let before = last ?? value
        last = value
        if showing { anchor = (value, now); return true }
        if abs(value - before) >= Self.jump { anchor = (value, now); return true }
        if let anchor, now.timeIntervalSince(anchor.at) <= Self.window {
            if abs(value - anchor.value) >= Self.jump { self.anchor = (value, now); return true }
            return false
        }
        anchor = (before, now)
        return false
    }
}

/// The default output device's volume and mute, through CoreAudio property
/// listeners (public, no permission). Follows the default device when it
/// changes, without reporting the switch itself. Main queue only.
final class SystemVolumeObserver {
    struct Level: Equatable {
        var volume: Float
        var muted: Bool
    }

    var onChange: ((Level) -> Void)?
    private(set) var running = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: Level?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    func start() {
        guard !running else { return }
        running = true
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            defaultListener = block
        }
        attach()
    }

    func stop() {
        guard running else { return }
        running = false
        detach()
        if let defaultListener {
            var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, defaultListener)
        }
        defaultListener = nil
    }

    /// Listens to the current default device; its level is the new baseline.
    private func attach() {
        detach()
        guard let id = Self.defaultDevice() else { return }
        device = id
        last = Self.level(id)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        for selector in Self.selectors {
            var addr = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(id, &addr, .main, block)
        }
        deviceListener = block
    }

    private func detach() {
        if let deviceListener, device != kAudioObjectUnknown {
            for selector in Self.selectors {
                var addr = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(device, &addr, .main, deviceListener)
            }
        }
        deviceListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func changed() {
        guard let now = Self.level(device), now != last else { return }
        last = now
        onChange?(now)
    }

    /// The default output device, if any.
    static func defaultDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Sets the default device's volume (0 to 1); false when it has no
    /// settable volume, so the key goes on to macOS.
    static func setVolume(_ volume: Float) -> Bool {
        guard let device = defaultDevice() else { return false }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value = Float32(min(1, max(0, volume)))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultDevice() else { return false }
        var addr = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Nil for a device without a volume control (some HDMI outputs).
    static func level(_ device: AudioObjectID) -> Level? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr else { return nil }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = address(kAudioDevicePropertyMute)
        let muted = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &mute) == noErr && mute != 0
        return Level(volume: volume, muted: muted)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
