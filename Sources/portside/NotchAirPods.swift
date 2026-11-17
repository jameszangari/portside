import CoreAudio
import Foundation
import os.log

/// One pair of AirPods or Beats while connected (SHELF-10): its name and
/// battery levels, 0 to 100, each nil when macOS does not report it yet.
struct AirPodsReading: Equatable {
    let address: String
    let name: String
    let productID: Int?
    var left: Int?
    var right: Int?
    var `case`: Int?
    /// Headphones with one battery (AirPods Max, most Beats).
    var single: Int?

    /// The buds' lowest level (the one that runs out first), else the
    /// headphones' own.
    var lowest: Int? { [left, right].compactMap { $0 }.min() ?? single }

    /// The parts that report a level, in the order the card shows them.
    var parts: [NotchLevelPart] {
        [("Left", left), ("Right", right), ("Case", `case`), ("Battery", single)]
            .compactMap { label, value in value.map { NotchLevelPart(label: label, percent: $0) } }
    }

    /// The card's line under the name ("Left 80%, Right 85%, Case 60%").
    var detail: String {
        let parts = parts.map { "\($0.label) \($0.percent)%" }
        return parts.isEmpty ? "Connected" : parts.joined(separator: ", ")
    }

    /// An SF Symbol for the model, from Apple's Bluetooth product IDs.
    var symbol: String { Self.symbol(productID) }

    static func symbol(_ productID: Int?) -> String {
        switch productID {
        case 0x2002?, 0x200F?: "airpods"
        case 0x2013?, 0x2019?, 0x201B?: "airpods.gen3"
        case 0x200E?, 0x2014?, 0x2024?, 0x2027?: "airpodspro"
        case 0x200A?, 0x201F?: "airpodsmax"
        default: "headphones"
        }
    }
}

/// A battery part's label and level, for the AirPods card's bars.
struct NotchLevelPart: Equatable, Hashable {
    let label: String
    let percent: Int
}

/// Reads connected AirPods and Beats from `system_profiler
/// SPBluetoothDataType -json`, the same report System Information shows.
/// No Bluetooth permission: the report is made by system_profiler.
enum AirPodsProfile {
    /// Apple's Bluetooth vendor ID; Beats use it too.
    static let appleVendor = 0x004C

    static func parse(_ data: Data) -> [AirPodsReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        return sections.flatMap { section -> [AirPodsReading] in
            let connected = section["device_connected"] as? [[String: Any]] ?? []
            return connected.flatMap { entry in
                entry.compactMap { name, value -> AirPodsReading? in
                    guard let info = value as? [String: Any], number(info["device_vendorID"]) == appleVendor,
                          info["device_minorType"] as? String == "Headphones" else { return nil }
                    return AirPodsReading(address: info["device_address"] as? String ?? name, name: name,
                                          productID: number(info["device_productID"]),
                                          left: percent(info["device_batteryLevelLeft"]),
                                          right: percent(info["device_batteryLevelRight"]),
                                          case: percent(info["device_batteryLevelCase"]),
                                          single: percent(info["device_batteryLevelMain"]))
                }
            }
        }
        .sorted { $0.name < $1.name }
    }

    /// "0x2014" or a number.
    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        guard let text = value as? String else { return nil }
        return text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
    }

    /// "85%" or a number; a level macOS has not read yet comes as 0 or is
    /// missing, so 0 counts as unknown.
    private static func percent(_ value: Any?) -> Int? {
        let level: Int? = (value as? Int) ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        guard let level, level > 0 else { return nil }
        return min(100, level)
    }
}

/// AirPods alerts: a pair connects (again once its levels arrive), or its
/// lowest level drops to the low mark.
enum AirPodsAlert: Equatable {
    case connected(AirPodsReading)
    case low(AirPodsReading)

    static func detect(previous: [AirPodsReading], current: [AirPodsReading], low: Int) -> [AirPodsAlert] {
        current.compactMap { reading in
            guard let before = previous.first(where: { $0.address == reading.address }) else { return .connected(reading) }
            // The first read after connecting often has no levels yet.
            if before.lowest == nil, reading.lowest != nil { return .connected(reading) }
            if let now = reading.lowest, let then = before.lowest, then > low, now <= low { return .low(reading) }
            return nil
        }
    }
}

/// Watches for AirPods and Beats while the shelf is on. A CoreAudio device
/// list listener (public, no permission) notices a Bluetooth audio device
/// coming or going; then `system_profiler` is read off the main queue,
/// again a few seconds later (levels arrive after the connection), and
/// every 5 minutes while one stays connected. With `live` on, a Bluetooth
/// LE scan (`AirPodsLiveScanner`) also reads again 2 s after the pair's
/// advertised levels change. Main queue only.
final class AirPodsMonitor {
    static let refresh: TimeInterval = 300
    /// After a connection, when to read again for the levels.
    static let followUps: [TimeInterval] = [1.5, 6]
    /// `refresh` reads again at most this often.
    static let refreshGap: TimeInterval = 30
    /// A live change reads this long after the advert (the report catches
    /// up), and at most this often.
    static let liveDelay: TimeInterval = 2
    static let liveGap: TimeInterval = 5

    var onChange: (([AirPodsReading]) -> Void)?
    /// Live levels from Bluetooth LE adverts (asks for Bluetooth access).
    var live = false {
        didSet { if live != oldValue { watchLive() } }
    }
    private(set) var running = false
    private let scanner = AirPodsLiveScanner()
    private var liveTask: DispatchWorkItem?
    private(set) var readings: [AirPodsReading] = []
    private var listener: AudioObjectPropertyListenerBlock?
    /// Pending reads by number.
    private var reads: [Int: DispatchWorkItem] = [:]
    private var readCount = 0
    /// The first read since `start` was reported, even when it found none.
    private var reported = false
    private var bluetooth = false
    private var lastRead = Date.distantPast
    private let logger = Logger(subsystem: "com.james.portside", category: "AirPods")

    func start() {
        guard !running else { return }
        running = true
        var addr = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            listener = block
        }
        scanner.onChange = { [weak self] in self?.liveChanged() }
        bluetooth = Self.hasBluetoothAudio()
        if bluetooth {
            read(after: 0)
        } else {
            // Nothing connected: report that now, so a pair connecting
            // later reads as a connection, not the starting state.
            reported = true
            onChange?([])
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let listener {
            var addr = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        }
        listener = nil
        reads.values.forEach { $0.cancel() }
        reads = [:]
        readings = []
        reported = false
        liveTask?.cancel()
        liveTask = nil
        scanner.stop()
    }

    /// Scans while live is on and a pair is connected.
    private func watchLive() {
        guard running, live else {
            scanner.stop()
            return
        }
        scanner.watch(Set(readings.compactMap(\.productID)))
    }

    private func liveChanged() {
        guard running, liveTask == nil else { return }
        let wait = max(Self.liveDelay, Self.liveGap - Date().timeIntervalSince(lastRead))
        let task = DispatchWorkItem { [weak self] in
            self?.liveTask = nil
            self?.readNow()
        }
        liveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: task)
    }

    /// Reads the levels again now (the AirPods page opened), unless a read
    /// finished in the last 30 s or no pair is connected.
    func refresh() {
        guard running, !readings.isEmpty, Date().timeIntervalSince(lastRead) > Self.refreshGap else { return }
        lastRead = Date()
        readNow()
    }

    private func devicesChanged() {
        let now = Self.hasBluetoothAudio()
        defer { bluetooth = now }
        if now {
            reads.values.forEach { $0.cancel() }
            reads = [:]
            Self.followUps.forEach { read(after: $0) }
        } else if bluetooth, !readings.isEmpty {
            reads.values.forEach { $0.cancel() }
            reads = [:]
            readings = []
            onChange?([])
            watchLive()
        }
    }

    private func read(after delay: TimeInterval) {
        readCount += 1
        let number = readCount
        let task = DispatchWorkItem { [weak self] in
            self?.reads[number] = nil
            self?.readNow()
        }
        reads[number] = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func readNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.profile()
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.lastRead = Date()
                if found != self.readings || !self.reported {
                    self.reported = true
                    self.readings = found
                    self.onChange?(found)
                    self.watchLive()
                }
                // One refresh timer while a pair stays connected.
                if !found.isEmpty, self.reads.isEmpty { self.read(after: Self.refresh) }
            }
        }
    }

    private static func profile() -> [AirPodsReading] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Logger(subsystem: "com.james.portside", category: "AirPods").info("system_profiler failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AirPodsProfile.parse(data)
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Any Bluetooth audio device present (AirPods show up as one).
    static func hasBluetoothAudio() -> Bool {
        var addr = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains { id in
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &transportAddr, 0, nil, &transportSize, &transport) == noErr else { return false }
            return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }
}
