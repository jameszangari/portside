import CoreAudio
import Foundation

/// Hysteresis over measured RMS, independent of device buffer size.
struct PlaybackGate {
    private(set) var playing = false
    private var candidateSince: Double?

    mutating func update(rms: Double, time: Double) -> Bool? {
        let audible = rms.isFinite && rms > 0.0001
        guard audible != playing else { candidateSince = nil; return nil }
        let since = candidateSince ?? time
        candidateSince = since
        guard time - since >= (audible ? 0.10 : 0.50) else { return nil }
        playing = audible
        candidateSince = nil
        return playing
    }
}

/// Float32 PCM from the tap, including planar and interleaved buffers.
enum AudioSampleLevel {
    static func rms(_ input: UnsafePointer<AudioBufferList>) -> Double {
        var squareSum = 0.0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let bytes = buffer.mData else { continue }
            let samples = bytes.assumingMemoryBound(to: Float.self)
            let length = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<length {
                let value = Double(samples[i])
                if value.isFinite { squareSum += value * value }
            }
            count += length
        }
        return count > 0 ? sqrt(squareSum / Double(count)) : 0
    }
}

/// Public CoreAudio process taps. Owns temporary private aggregate devices,
/// never changes the default output, and discards every buffer after RMS.
///
/// Ableton, browsers and remote-desktop helpers often add or drop audio
/// process objects while still playing. Recreating the tap on every set
/// change cleared the icon and reset the gate, so playback looked flaky.
/// Process-set updates are debounced, playing state is kept across recreate,
/// and a failed tap only skips that app (not every app).
final class AudioPlaybackMonitor {
    private struct Entry {
        var id = UUID()
        var processes: Set<AudioObjectID>
        var meter: ProcessAudioMeter?
        var playing = false
        var recreate: DispatchWorkItem?
        var failed = false
    }

    private let queue: DispatchQueue
    private let onChange: (String, Bool) -> Void
    private let onError: (String) -> Void
    private var entries: [String: Entry] = [:]
    /// How long a changed process set must stay put before the tap is rebuilt.
    private let recreateDelay: TimeInterval = 0.4

    init(queue: DispatchQueue, onChange: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void) {
        self.queue = queue
        self.onChange = onChange
        self.onError = onError
    }

    /// Called on the activity queue, with one process set per owning app.
    func sync(_ owners: [String: Set<AudioObjectID>]) {
        for key in Array(entries.keys) where owners[key] == nil {
            cancel(key)
            if entries[key]?.playing == true { onChange(key, false) }
            entries[key] = nil
        }
        for (key, processes) in owners {
            if entries[key] == nil {
                entries[key] = Entry(processes: processes)
                startMeter(for: key, processes: processes, preserving: false)
                continue
            }
            guard entries[key]?.processes != processes else { continue }
            entries[key]?.processes = processes
            entries[key]?.recreate?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.entries[key]?.processes == processes else { return }
                self.startMeter(for: key, processes: processes, preserving: self.entries[key]?.playing == true)
            }
            entries[key]?.recreate = work
            queue.asyncAfter(deadline: .now() + recreateDelay, execute: work)
        }
    }

    func stop() {
        for key in Array(entries.keys) {
            cancel(key)
            if entries[key]?.playing == true { onChange(key, false) }
        }
        entries = [:]
    }

    private func cancel(_ key: String) {
        entries[key]?.recreate?.cancel()
        entries[key]?.recreate = nil
        entries[key]?.meter?.stop()
        entries[key]?.meter = nil
    }

    private func startMeter(for key: String, processes: Set<AudioObjectID>, preserving: Bool) {
        entries[key]?.recreate?.cancel()
        entries[key]?.recreate = nil
        entries[key]?.meter?.stop()
        entries[key]?.meter = nil
        guard !processes.isEmpty else {
            if !preserving, entries[key]?.playing == true {
                entries[key]?.playing = false
                onChange(key, false)
            }
            return
        }
        let id = UUID()
        entries[key]?.id = id
        do {
            let meter = try ProcessAudioMeter(processes: processes) { [weak self] playing in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, self.entries[key]?.id == id else { return }
                    self.entries[key]?.playing = playing
                    self.onChange(key, playing)
                }
            }
            entries[key]?.meter = meter
            entries[key]?.failed = false
            // Keep the prior "playing" report until the new gate confirms, so a
            // helper-process churn mid-song does not blank the icon.
            if !preserving { entries[key]?.playing = false }
        } catch {
            entries[key]?.failed = true
            if preserving || entries[key]?.playing == true {
                entries[key]?.playing = false
                onChange(key, false)
            }
            // One app failing must not block others; a later process-set change retries.
            onError("Playback measurement unavailable for one app: \(error.localizedDescription) Allow Portside in System Settings > Privacy & Security > Screen & System Audio Recording, then turn measurement off and on.")
        }
    }
}

private final class ProcessAudioMeter {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let callbackQueue = DispatchQueue(label: "com.james.portside.audio-level", qos: .userInitiated)
    private var gate = PlaybackGate()
    private let onChange: (Bool) -> Void

    init(processes: Set<AudioObjectID>, onChange: @escaping (Bool) -> Void) throws {
        self.onChange = onChange
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
            description.name = "Portside playback activity"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap")

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Read audio format")
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mBitsPerChannel == 32 else {
                throw MeterError(operation: "Unsupported audio format", status: kAudioHardwareUnsupportedOperationError)
            }
            // Prefer the created tap's own UID when available; description.uuid
            // usually matches, but a mismatch leaves the aggregate silent.
            var tapUID = description.uuid.uuidString as CFString
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uidValue: Unmanaged<CFString>?
            if AudioObjectGetPropertyData(tap, &uidAddress, 0, nil, &uidSize, &uidValue) == noErr,
               let uid = uidValue?.takeRetainedValue() {
                tapUID = uid
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Portside playback activity",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create private audio device")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, callbackQueue) { [weak self] _, input, _, _, _ in
                self?.consume(input)
            }, "Create audio callback")
            try check(AudioDeviceStart(device, ioProc), "Start audio measurement")
        } catch {
            stop()
            throw error
        }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let rms = AudioSampleLevel.rms(input)
        let time = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        if let playing = gate.update(rms: rms, time: time) { onChange(playing) }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw MeterError(operation: operation, status: status) }
    }

    private struct MeterError: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "\(operation) failed (\(status))." }
    }
}
