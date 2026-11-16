import CoreBluetooth
import Foundation
import os.log

/// The levels in an Apple proximity pairing advertisement (type 0x07), the
/// one AirPods and Beats send out while out of the case. Levels come in 10%
/// steps (a nibble each, 15 for unknown), so they only tell that something
/// changed; `AirPodsMonitor` then reads the exact levels from
/// system_profiler. Which nibble is left and which right depends on the
/// bud in use, and does not matter for that.
struct AirPodsAdvert: Equatable {
    let productID: Int
    let pods: UInt8
    let `case`: UInt8

    /// `data` is the advertisement's manufacturer data: Apple's company ID
    /// (0x004C, little endian), type 0x07, length, then the message.
    static func parse(_ data: Data) -> AirPodsAdvert? {
        let bytes = [UInt8](data)
        guard bytes.count >= 11, bytes[0] == 0x4C, bytes[1] == 0x00, bytes[2] == 0x07 else { return nil }
        return AirPodsAdvert(productID: Int(bytes[5]) | Int(bytes[6]) << 8, pods: bytes[8], case: bytes[9] & 0x0F)
    }
}

/// SHELF-10c live levels: scans Bluetooth LE advertisements (public
/// CoreBluetooth; asks for Bluetooth access the first time) while a pair is
/// connected, and calls `onChange` when the connected model's levels or
/// case change. Only for Settings > Top Notch > Live AirPods levels; off,
/// no scan and no permission prompt. Main queue only.
final class AirPodsLiveScanner: NSObject, CBCentralManagerDelegate {
    /// Adverts weaker than this are other people's AirPods.
    static let nearby = -65

    var onChange: (() -> Void)?
    private var central: CBCentralManager?
    private var wanted: Set<Int> = []
    private var last: [Int: AirPodsAdvert] = [:]
    private let logger = Logger(subsystem: "com.james.portside", category: "AirPods")

    static var denied: Bool { [.denied, .restricted].contains(CBManager.authorization) }

    /// Scans for these connected models; none stops scanning.
    func watch(_ productIDs: Set<Int>) {
        guard productIDs != wanted else { return }
        wanted = productIDs
        last = last.filter { productIDs.contains($0.key) }
        if productIDs.isEmpty {
            central?.stopScan()
            return
        }
        if let central {
            centralManagerDidUpdateState(central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        central?.stopScan()
        central = nil
        wanted = []
        last = [:]
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, !wanted.isEmpty else {
            if central.state == .unauthorized { logger.info("live AirPods levels: Bluetooth access denied") }
            return
        }
        // Duplicates on: a pair repeats its advert, and only a repeat
        // carries a new level.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue > Self.nearby, RSSI.intValue < 0,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advert = AirPodsAdvert.parse(data), wanted.contains(advert.productID) else { return }
        let before = last.updateValue(advert, forKey: advert.productID)
        if let before, before != advert { onChange?() }
    }
}
