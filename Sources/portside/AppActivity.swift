import AppKit
import CoreAudio
import CoreMediaIO
import Darwin
import os.log
import SwiftUI

/// What an app is doing right now, drawn as a small icon on its tile.
/// Declared in priority order: a tile shows only the first one that applies
/// (a video call shows the camera, not the mic or the sound).
enum ActivityKind: Int, Comparable, CaseIterable {
    case camera, microphone, audio, audioOutput, working

    static func < (a: ActivityKind, b: ActivityKind) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .camera: "Camera in use"
        case .microphone: "Microphone in use"
        case .audio: "Playing audio"
        case .audioOutput: "Audio output active"
        case .working: "Working"
        }
    }
}

/// Which activity icons to draw, plus the apps watched for "Working".
/// Stored as `activityIcons` in dock.json.
struct ActivityIconSettings: Codable, Equatable {
    var camera = true
    var microphone = true
    var audio = true
    var measureAudioPlayback = false
    var working = true
    /// Bundle ids watched for "Working" (CPU use of the app and its child
    /// processes). Opt-in per app from the right-click menu.
    var workingApps: [String] = Self.defaultWorkingApps

    static let defaultWorkingApps = [
        "com.t3tools.t3code",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = c.value(.camera, or: true)
        microphone = c.value(.microphone, or: true)
        audio = c.value(.audio, or: true)
        measureAudioPlayback = c.value(.measureAudioPlayback, or: false)
        working = c.value(.working, or: true)
        workingApps = c.value(.workingApps, or: Self.defaultWorkingApps)
    }

    func shows(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .camera: camera
        case .microphone: microphone
        case .audio, .audioOutput: audio
        case .working: working
        }
    }
}

/// Per-app activity: microphone, camera, audio output, and "working".
///
/// Microphone and audio output come from CoreAudio's per-process objects
/// (`kAudioProcessPropertyIsRunningInput` / `Output`, public since macOS
/// 14). The camera comes from CoreMediaIO (`DeviceIsRunningSomewhere`).
/// The base indicators use property listeners without permission prompts.
/// Opt-in playback measurement uses private process taps through public
/// CoreAudio APIs and requires System Audio Recording permission.
/// macOS has no public per-process camera owner, so while a camera runs it
/// is attributed to the apps that are also using the microphone (calls).
///
/// "Working" is a CPU heuristic: the app plus all its child processes (an
/// agent CLI, a build it started), sampled every 2s and only while a watched
/// app is running. That timer is outside the reveal/hide path. Agent hosts
/// (T3 Code, Claude, Codex) use the Agents widget's sessions instead while it
/// runs, so their tiles match the Agent Notch rather than idle CPU spikes.
///
/// React analogy: a store fed by event subscriptions; tiles read
/// `activity(for:)` and re-render when `byKey` changes.
final class AppActivity: ObservableObject {
    static let shared = AppActivity()

    /// Strongest activity per app, keyed by bundle id and by standardized
    /// bundle path (the same app appears under both).
    @Published private(set) var byKey: [String: ActivityKind] = [:]
    /// The dock is on screen. Animated icons pause while it is not.
    @Published private(set) var dockVisible = false
    @Published private(set) var audioMeasurementNotice: String?

    private(set) var settings = ActivityIconSettings()
    private let logger = Logger(subsystem: "com.james.portside", category: "AppActivity")
    /// CoreAudio / CoreMediaIO listeners and the CPU sampler run here.
    private let queue = DispatchQueue(label: "com.james.portside.activity", qos: .utility)
    private var started = false

    // Queue state.
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var cameraDevices: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var cameraListListener: CMIOObjectPropertyListenerBlock?
    private var rebuildPending = false
    private var sampler: DispatchSourceTimer?
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastSampleTime: UInt64 = 0
    /// Consecutive samples above / below the thresholds, per watched app key.
    private var busyStreak: [String: Int] = [:]
    private var idleStreak: [String: Int] = [:]
    private var workingKeys: Set<String> = []
    private var watched: Set<String> = []
    private var measurePlayback = false
    private var measuredAudio: Set<String> = []
    private lazy var playback = AudioPlaybackMonitor(queue: queue, onChange: { [weak self] key, playing in
        guard let self else { return }
        if playing { self.measuredAudio.insert(key) } else { self.measuredAudio.remove(key) }
        let keys = self.measuredAudio
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started, self.settings.audio, self.settings.measureAudioPlayback else { return }
            self.applyAudio(keys)
            self.publish()
        }
    }, onError: { [weak self] message in
        DispatchQueue.main.async { self?.audioMeasurementNotice = message }
    })

    // Main-thread state.
    private var rawAudio: Set<String> = []
    private var shownAudio: Set<String> = []
    private var audioDebounce: [String: DispatchWorkItem] = [:]
    private var privacy: [String: ActivityKind] = [:]
    private var working: Set<String> = []
    /// Bundle ids of apps hosting a running agent session, from the Agents
    /// widget. Nil while it is not running: agent hosts fall back to CPU.
    private var agentWorking: Set<String>?
    private var aliases: [String: String] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Spotify / Music play state from their public notifications. Open
    /// output streams often stay hot after pause; this clears the chip then.
    private var playerPlaying: [String: Bool] = [:]
    private var playerObservers: [NSObjectProtocol] = []

    /// Audio must run this long before the wave shows (skips alert sounds),
    /// and stop this long before it goes (skips gaps between tracks).
    private let audioOnDelay: TimeInterval = 0.75
    private let audioOffDelay: TimeInterval = 2.0
    private let sampleInterval: TimeInterval = 2.0
    /// Percent of one core, app plus child processes.
    private let busyPercent = 8.0
    private let idlePercent = 4.0

    // MARK: - Lifecycle

    func start(settings: ActivityIconSettings) {
        guard !started else { return configure(settings) }
        self.settings = settings
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didTerminateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let id = app.bundleIdentifier, self?.playerPlaying[id] != nil {
                    self?.playerStateChanged(bundleID: id, info: ["Player State": "Stopped"])
                }
                self?.appsChanged()
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.audioDebounce.values.forEach { $0.cancel() }
            self.audioDebounce = [:]
            self.shownAudio = []
            self.rawAudio = []
            self.publish()
            self.queue.async { [weak self] in
                self?.playback.stop()
                self?.measuredAudio = []
                self?.syncProcessListeners()
                self?.scheduleRebuild()
            }
        })
        installPlayerObservers()
        let watched = watchedKeys()
        let measure = settings.audio && settings.measureAudioPlayback
        queue.async { [weak self] in
            guard let self else { return }
            self.measurePlayback = measure
            self.installAudioListeners()
            self.installCameraListeners()
            self.watched = watched
            self.updateSampler()
            self.rebuild()
        }
        logger.info("activity monitor started")
    }

    func stop() {
        guard started else { return }
        started = false
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        removePlayerObservers()
        audioDebounce.values.forEach { $0.cancel() }
        audioDebounce.removeAll()
        queue.async { [weak self] in self?.removeAllListeners() }
    }

    /// Settings changed live.
    func configure(_ next: ActivityIconSettings) {
        let changedMode = settings.measureAudioPlayback != next.measureAudioPlayback || settings.audio != next.audio
        settings = next
        if changedMode {
            audioMeasurementNotice = nil
            audioDebounce.values.forEach { $0.cancel() }
            audioDebounce = [:]
            rawAudio = []
            shownAudio = []
            let measure = next.audio && next.measureAudioPlayback
            queue.async { [weak self] in
                guard let self else { return }
                self.playback.stop()
                self.measuredAudio = []
                self.measurePlayback = measure
                self.scheduleRebuild()
            }
        }
        appsChanged()
        publish()
    }

    func setDockVisible(_ on: Bool) {
        if dockVisible != on { dockVisible = on }
    }

    // MARK: - Lookup

    func activity(for app: PinnedApp) -> ActivityKind? {
        if let id = app.bundleIdentifier, let kind = byKey[id] { return kind }
        return byKey[DockBadges.standardPath(app.path)]
    }

    /// Apps whose "Working" follows agent sessions instead of CPU.
    static let agentHosts: Set<String> = [
        "com.t3tools.t3code",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
    ]

    /// Running agent sessions changed (nil: the Agents widget stopped).
    func setAgentWorking(_ bundleIDs: Set<String>?) {
        guard bundleIDs != agentWorking else { return }
        agentWorking = bundleIDs
        publish()
    }

    /// The strongest activity among a group's members.
    func activity(forGroup group: FolderGroup) -> ActivityKind? {
        group.apps.compactMap(activity(for:)).min()
    }

    // MARK: - Publishing (main)

    private func publish() {
        var next: [String: ActivityKind] = [:]
        func add(_ key: String, _ kind: ActivityKind) {
            guard settings.shows(kind) else { return }
            if let existing = next[key], existing <= kind { return }
            next[key] = kind
        }
        for (key, kind) in privacy { add(key, kind) }
        for key in shownAudio { add(key, settings.measureAudioPlayback ? .audio : .audioOutput) }
        // Agent hosts: the notch's session state wins over CPU.
        for key in working where agentWorking == nil || !Self.agentHosts.contains(key) { add(key, .working) }
        for key in agentWorking ?? [] where settings.workingApps.contains(key) { add(key, .working) }
        // Also key each entry by its alias (bundle id <-> path).
        for (key, kind) in next {
            if let alias = aliases[key], next[alias] == nil { next[alias] = kind }
        }
        guard next != byKey else { return }
        byKey = next
        let summary = next.filter { !$0.key.hasPrefix("/") }
            .map { "\($0.key)=\($0.value.title)" }.sorted().joined(separator: ", ")
        logger.info("activity: \(summary.isEmpty ? "none" : summary, privacy: .public)")
    }

    /// Debounce audio so alert sounds and track gaps do not flicker.
    private func applyAudio(_ raw: Set<String>) {
        let filtered = audibleAudio(from: raw)
        rawAudio = filtered
        for key in filtered.union(shownAudio).union(audioDebounce.keys) {
            let want = filtered.contains(key)
            let shown = shownAudio.contains(key)
            if want == shown {
                audioDebounce.removeValue(forKey: key)?.cancel()
                continue
            }
            guard audioDebounce[key] == nil else { continue }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.audioDebounce[key] = nil
                if self.rawAudio.contains(key) { self.shownAudio.insert(key) } else { self.shownAudio.remove(key) }
                self.publish()
            }
            audioDebounce[key] = item
            // Pause notifications clear known players immediately; stream-only
            // apps still use the longer off delay so track gaps do not flicker.
            let delay = settings.measureAudioPlayback ? (want ? 0.1 : 0.4) : (want ? audioOnDelay : audioOffDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// Drops Spotify / Music keys we know are paused, even if their output
    /// stream is still marked running.
    private func audibleAudio(from keys: Set<String>) -> Set<String> {
        keys.filter { key in
            if let playing = playerPlaying[key] { return playing }
            if let bundle = aliases.first(where: { $0.value == key })?.key,
               let playing = playerPlaying[bundle] {
                return playing
            }
            return true
        }
    }

    private func installPlayerObservers() {
        removePlayerObservers()
        let center = DistributedNotificationCenter.default()
        for player in NowPlayingWidget.players {
            let token = center.addObserver(forName: .init(player.notification), object: nil, queue: .main) { [weak self] note in
                self?.playerStateChanged(bundleID: player.bundleID, info: note.userInfo)
            }
            playerObservers.append(token)
        }
    }

    private func removePlayerObservers() {
        let center = DistributedNotificationCenter.default()
        for token in playerObservers { center.removeObserver(token) }
        playerObservers.removeAll()
        playerPlaying.removeAll()
    }

    private func playerStateChanged(bundleID: String, info: [AnyHashable: Any]?) {
        let state = info?["Player State"] as? String
        let playing = state == "Playing"
        playerPlaying[bundleID] = playing
        if playing {
            queue.async { [weak self] in self?.scheduleRebuild() }
            return
        }
        // Pause / stop: clear now. Waiting for IsRunningOutput to drop can
        // leave the speaker up for minutes on Spotify and Music.
        for key in audioKeys(matching: bundleID) {
            audioDebounce.removeValue(forKey: key)?.cancel()
            rawAudio.remove(key)
            shownAudio.remove(key)
        }
        publish()
        logger.info("activity: \(bundleID, privacy: .public) paused/stopped, audio chip cleared")
    }

    private func audioKeys(matching bundleID: String) -> Set<String> {
        var keys: Set<String> = [bundleID]
        if let path = aliases[bundleID] { keys.insert(path) }
        return keys
    }

    private func appsChanged() {
        let keys = watchedKeys()
        queue.async { [weak self] in
            guard let self else { return }
            self.watched = keys
            self.updateSampler()
            self.scheduleRebuild()
        }
    }

    private func watchedKeys() -> Set<String> {
        settings.working ? Set(settings.workingApps) : []
    }

    // MARK: - Snapshot (queue)

    private struct DockApp {
        let pid: pid_t
        let key: String
        let path: String?
    }

    /// Regular (Dock-visible) apps, keyed by bundle id or path.
    private func dockApps() -> [DockApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app in
                let path = app.bundleURL.map { DockBadges.standardPath($0.path) }
                guard let key = app.bundleIdentifier ?? path else { return nil }
                return DockApp(pid: app.processIdentifier, key: key, path: path)
            }
    }

    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        // Listeners fire in bursts (one per process); fold them into one read.
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        rebuildPending = false
        let apps = dockApps()
        let parents = Self.parentMap()
        let byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        /// The dock app that owns a process: itself, an ancestor (Electron
        /// and browser helpers), or a bundle id prefix match.
        func owner(pid: pid_t, bundleID: String?) -> String? {
            var current = pid
            for _ in 0..<12 {
                if let app = byPID[current] { return app.key }
                guard let parent = parents[current], parent > 1, parent != current else { break }
                current = parent
            }
            if let bundleID {
                return apps.first { bundleID.hasPrefix($0.key + ".") }?.key
            }
            return nil
        }

        var mic: Set<String> = []
        var audio: Set<String> = []
        var audioOwners: [String: Set<AudioObjectID>] = [:]
        for object in Self.audioProcessObjects() {
            let input = Self.audioUInt32(object, kAudioProcessPropertyIsRunningInput) != 0
            let output = Self.audioUInt32(object, kAudioProcessPropertyIsRunningOutput) != 0
            guard input || output else { continue }
            let pid = pid_t(bitPattern: Self.audioUInt32(object, kAudioProcessPropertyPID))
            guard pid != getpid() else { continue }
            guard let key = owner(pid: pid, bundleID: Self.audioBundleID(object)) ?? Self.proxyOwner(pid: pid, apps: apps) else { continue }
            if input { mic.insert(key) }
            if output {
                audio.insert(key)
                audioOwners[key, default: []].insert(object)
            }
        }
        if measurePlayback { playback.sync(audioOwners) }
        let measured = measurePlayback
        let audioSnapshot = measured ? measuredAudio : audio
        let cameraOn = cameraDevices.keys.contains { Self.cameraIsRunning($0) }

        var privacy: [String: ActivityKind] = [:]
        for key in mic { privacy[key] = cameraOn ? .camera : .microphone }
        var aliases: [String: String] = [:]
        for app in apps {
            guard let path = app.path, path != app.key else { continue }
            aliases[app.key] = path
        }
        let working = workingKeys
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            self.privacy = privacy
            self.aliases = aliases
            self.working = working
            if measured == (self.settings.audio && self.settings.measureAudioPlayback) {
                self.applyAudio(audioSnapshot)
            }
            self.publish()
        }
    }

    /// FaceTime does its call audio in the system daemon `avconferenced`, so
    /// the mic and sound show up under that process, not under the app.
    /// Credit them to FaceTime when it is running.
    private static func proxyOwner(pid: pid_t, apps: [DockApp]) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0,
              String(cString: name) == "avconferenced" else { return nil }
        return apps.first { $0.key == "com.apple.FaceTime" }?.key
    }

    // MARK: - CoreAudio (queue)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioProcessObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func audioBundleID(_ object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        let id = value?.takeRetainedValue() as String?
        return id?.isEmpty == false ? id : nil
    }

    private func installAudioListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncProcessListeners()
            self?.scheduleRebuild()
        }
        if AudioObjectAddPropertyListenerBlock(system, &addr, queue, block) == noErr {
            systemListener = block
        } else {
            logger.error("could not listen for audio process changes")
        }
        syncProcessListeners()
    }

    /// One listener per audio process object for its input/output state.
    private func syncProcessListeners() {
        let current = Set(Self.audioProcessObjects())
        for (object, block) in processListeners where !current.contains(object) {
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var addr = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
            }
            processListeners[object] = nil
        }
        for object in current where processListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var addr = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
            }
            processListeners[object] = block
        }
    }

    // MARK: - CoreMediaIO (queue)

    private static func cameraAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func cameraDeviceIDs() -> [CMIOObjectID] {
        var addr = cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func cameraIsRunning(_ device: CMIOObjectID) -> Bool {
        var addr = cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return false }
        return value != 0
    }

    private func installCameraListeners() {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var addr = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncCameraListeners()
            self?.scheduleRebuild()
        }
        if CMIOObjectAddPropertyListenerBlock(system, &addr, queue, block) == noErr {
            cameraListListener = block
        }
        syncCameraListeners()
    }

    private func syncCameraListeners() {
        let current = Set(Self.cameraDeviceIDs())
        for (device, block) in cameraDevices where !current.contains(device) {
            var addr = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            CMIOObjectRemovePropertyListenerBlock(device, &addr, queue, block)
            cameraDevices[device] = nil
        }
        for device in current where cameraDevices[device] == nil {
            var addr = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
            CMIOObjectAddPropertyListenerBlock(device, &addr, queue, block)
            cameraDevices[device] = block
        }
    }

    private func removeAllListeners() {
        playback.stop()
        measuredAudio = []
        sampler?.cancel()
        sampler = nil
        for (object, block) in processListeners {
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var addr = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
            }
        }
        processListeners.removeAll()
        if let systemListener {
            var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, systemListener)
            self.systemListener = nil
        }
        for (device, block) in cameraDevices {
            var addr = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            CMIOObjectRemovePropertyListenerBlock(device, &addr, queue, block)
        }
        cameraDevices.removeAll()
        if let cameraListListener {
            var addr = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, queue, cameraListListener)
            self.cameraListListener = nil
        }
    }

    // MARK: - Working: CPU sampler (queue)

    /// Runs only while a watched app is running.
    private func updateSampler() {
        let running = Set(dockApps().map(\.key))
        let wanted = started && !watched.isDisjoint(with: running)
        if !wanted {
            sampler?.cancel()
            sampler = nil
            lastCPU.removeAll()
            busyStreak.removeAll()
            idleStreak.removeAll()
            if !workingKeys.isEmpty {
                workingKeys.removeAll()
                scheduleRebuild()
            }
            return
        }
        guard sampler == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: sampleInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        sampler = t
    }

    private func sample() {
        let started = CACurrentMediaTime()
        let apps = dockApps().filter { watched.contains($0.key) }
        let parents = Self.parentMap()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }

        let now = mach_absolute_time()
        let wallNs = Double(Self.nanoseconds(now &- lastSampleTime))
        let firstSample = lastSampleTime == 0
        var nextCPU: [pid_t: UInt64] = [:]
        var changed = false
        var report: [String] = []

        for app in apps {
            var total: UInt64 = 0
            var stack = [app.pid]
            var seen: Set<pid_t> = []
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                stack.append(contentsOf: children[pid] ?? [])
                guard let cpu = Self.cpuTime(pid) else { continue }
                nextCPU[pid] = cpu
                // A process new since the last sample counts in full.
                total &+= cpu &- min(lastCPU[pid] ?? 0, cpu)
            }
            guard !firstSample, wallNs > 0 else { continue }
            let percent = Double(Self.nanoseconds(total)) / wallNs * 100
            report.append("\(app.key) \(String(format: "%.1f", percent))%")
            if percent >= busyPercent {
                busyStreak[app.key, default: 0] += 1
                idleStreak[app.key] = 0
            } else if percent < idlePercent {
                idleStreak[app.key, default: 0] += 1
                busyStreak[app.key] = 0
            }
            // Two samples in a row (about 4s) either way, so a click or a
            // scroll does not flip it.
            if !workingKeys.contains(app.key), busyStreak[app.key, default: 0] >= 2 {
                workingKeys.insert(app.key)
                changed = true
            } else if workingKeys.contains(app.key), idleStreak[app.key, default: 0] >= 2 {
                workingKeys.remove(app.key)
                changed = true
            }
        }
        let live = Set(apps.map(\.key))
        if !workingKeys.isSubset(of: live) {
            workingKeys.formIntersection(live)
            changed = true
        }
        lastCPU = nextCPU
        lastSampleTime = now
        let ms = (CACurrentMediaTime() - started) * 1000
        let line = report.joined(separator: ", ")
        logger.debug("cpu sample in \(ms, format: .fixed(precision: 2))ms: \(line, privacy: .public)")
        if changed { scheduleRebuild() }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    /// User plus system CPU time in mach ticks, or nil if unreadable.
    private static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_user_time &+ info.ri_system_time
    }

    /// Parent pid of every process, in one sysctl.
    private static func parentMap() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Room for processes started between the two calls.
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var map: [pid_t: pid_t] = [:]
        map.reserveCapacity(count)
        for proc in procs.prefix(count) {
            map[proc.kp_proc.p_pid] = proc.kp_eproc.e_ppid
        }
        return map
    }
}

// MARK: - Activity chip

/// Small icon on a tile's top-leading corner (badges use top-trailing).
/// Microphone and camera use the macOS privacy indicator colors (orange,
/// green). Open output streams and measured playback both use an animated
/// speaker; nothing is drawn when no output is active. Opt-in measurement
/// hides silent streams. Working uses pulsing dots. Animations pause while
/// the dock is hidden and stay still with Reduce Motion.
struct ActivityChip: View {
    let kind: ActivityKind
    let iconSize: CGFloat
    @ObservedObject private var activity = AppActivity.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func size(for iconSize: CGFloat) -> CGFloat {
        max(11, (iconSize * 0.34).rounded())
    }

    var body: some View {
        let d = Self.size(for: iconSize)
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            glyph(d)
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch kind {
        case .camera: Color(nsColor: .systemGreen)
        case .microphone: Color(nsColor: .systemOrange)
        case .audio, .audioOutput, .working: Color(white: 0.12, opacity: 0.88)
        }
    }

    @ViewBuilder private func glyph(_ d: CGFloat) -> some View {
        switch kind {
        case .camera:
            Image(systemName: "video.fill")
                .font(.system(size: d * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        case .microphone:
            Image(systemName: "mic.fill")
                .font(.system(size: d * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        case .audio, .audioOutput:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: d * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating,
                              isActive: activity.dockVisible && !reduceMotion)
        case .working:
            ThinkingLoader(
                style: .dots,
                paused: reduceMotion || !activity.dockVisible,
                size: d * 0.72,
                color: .white
            )
        }
    }
}

extension View {
    /// Overlays the activity chip on the icon's top-leading corner. Never
    /// changes the tile's layout.
    @ViewBuilder
    func activityChip(_ kind: ActivityKind?, iconSize: CGFloat) -> some View {
        if let kind {
            overlay(alignment: .topLeading) {
                ActivityChip(kind: kind, iconSize: iconSize)
                    .transition(.opacity)
            }
        } else {
            self
        }
    }
}
