#if DEBUG
import AVFoundation
import CoreAudio
import Foundation
import os

/// Regression checks run without permission; --capture also measures a local test tone.
enum AudioPlaybackProbe {
    @MainActor static func run(capture: Bool) -> Int32 {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        do {
            var gate = PlaybackGate()
            for frame in 0..<100 {
                try require(gate.update(rms: 0, time: Double(frame) / 100) == nil && !gate.playing, "Silence must stay idle")
            }
            _ = gate.update(rms: 0.02, time: 1)
            try require(!gate.playing, "Single transient must not start playback")
            _ = gate.update(rms: 0, time: 1.05)
            _ = gate.update(rms: 0.02, time: 2)
            try require(gate.update(rms: 0.02, time: 2.11) == true, "Sustained tone must start playback")
            _ = gate.update(rms: 0, time: 3)
            try require(gate.playing, "Brief gap must not stop playback")
            try require(gate.update(rms: 0, time: 3.51) == false, "Sustained silence must stop playback")
            _ = gate.update(rms: .nan, time: 4)
            try require(!gate.playing, "NaN must not count as sound")
            var samples: [Float] = [0.02, -0.02, 0.02, -0.02]
            let rms = samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return AudioSampleLevel.rms(&list)
            }
            try require(abs(rms - 0.02) < 0.000001, "Interleaved PCM must measure both channels")
            print("PASS audio levels: silence, transient, sustained tone, gap, stop, NaN and stereo PCM")
            guard capture else { return 0 }
            return try captureTone()
        } catch {
            print("FAIL audio levels: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor private static func captureTone() throws -> Int32 {
        let amplitude = OSAllocatedUnfairLock(initialState: Float(0))
        let observed = OSAllocatedUnfairLock(initialState: (playing: false, changes: 0, error: Optional<String>.none))
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        var phase = 0.0
        let source = AVAudioSourceNode(format: format) { silence, _, frames, buffers in
            let volume = amplitude.withLock { $0 }
            silence.pointee = ObjCBool(volume == 0)
            let buffers = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<Int(frames) {
                let sample = volume * Float(sin(phase))
                phase += 2 * .pi * 440 / format.sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for channel in 0..<Int(buffer.mNumberChannels) {
                        data[frame * Int(buffer.mNumberChannels) + channel] = sample
                    }
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid(), process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        guard status == noErr else { print("FAIL process lookup: \(status)"); return 1 }
        let queue = DispatchQueue(label: "com.james.portside.audio-probe")
        let monitor = AudioPlaybackMonitor(queue: queue, onChange: { _, playing in
            observed.withLock { $0.playing = playing; $0.changes += 1 }
        }, onError: { message in observed.withLock { $0.error = message } })
        defer { queue.sync { monitor.stop() } }
        print("Starting local audio tap. macOS may ask for System Audio Recording permission.")
        queue.sync { monitor.sync(["probe": [process]]) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        guard !observed.withLock({ $0.playing }) else { print("FAIL silent stream marked playing"); return 1 }
        print("PASS silent running stream has no playback state")
        print("Playing a quiet 440 Hz test tone until detected, for up to 20 seconds.")
        amplitude.withLock { $0 = 0.02 }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !observed.withLock({ $0.playing || $0.error != nil }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        amplitude.withLock { $0 = 0 }
        guard observed.withLock({ $0.playing }) else {
            print(observed.withLock { $0.error } ?? "BLOCKED: no captured tone; grant System Audio Recording permission and retry.")
            return 1
        }
        print("PASS actual tone detected")
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        guard !observed.withLock({ $0.playing }) else { print("FAIL playback persisted after silence"); return 1 }
        print("PASS playback cleared after silence; private taps and devices will be removed")
        return 0
    }
}
#endif
