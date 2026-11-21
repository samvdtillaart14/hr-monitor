import Foundation
import CoreBluetooth
import UIKit

/// Verbindt met een BLE-hartslagband (standaard Heart Rate Service 0x180D),
/// blijft op de achtergrond verbonden (UIBackgroundModes: bluetooth-central)
/// en herverbindt automatisch met het laatst gebruikte apparaat.
final class BLEManager: NSObject, ObservableObject {
    static let hrService = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    private static let lastDeviceKey = "lastDeviceUUID"
    private static let restoreID = "nl.samvdtillaart.hrmonitor.central"

    enum State: Equatable { case off, idle, scanning, connecting, connected, unauthorized }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let bpm: Int
    }

    @Published var state: State = .idle
    @Published var found: [Found] = []
    @Published var deviceName: String?
    @Published var bpm: Int?
    @Published var contact: String = "-"
    @Published var lastRR: Double?
    @Published var rmssd: Double?
    @Published var battery: Int?
    @Published var samples: [Sample] = []   // laatste 5 min voor de grafiek
    @Published var sessionMin: Int?
    @Published var sessionMax: Int?
    @Published var sessionAvg: Double?
    @Published var sessionStart: Date?

    let recorder = Recorder()
    let raw = RawLogger()
    let whoop = WhoopParser()

    /// Alle gevonden characteristics, voor de verkenner.
    struct CharInfo: Identifiable {
        var id: String { service + "/" + uuid }
        let service: String
        let uuid: String
        let props: String
        var notifying = false
        var last = ""
        var count = 0
    }
    @Published var chars: [CharInfo] = []
    private var charRefs: [String: CBCharacteristic] = [:]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var rrWindow: [(Date, Double)] = []
    private var sum = 0.0, count = 0
    private var userDisconnected = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                                             CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: acties

    func scan() {
        guard central.state == .poweredOn else { return }
        found = []
        state = .scanning
        // Eerst apparaten die de Heart Rate Service adverteren; zonder filter
        // vindt iOS ook banden die de service pas na verbinden tonen.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.state == .scanning { self?.stopScan() }
        }
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ id: UUID) {
        guard let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        userDisconnected = false
        peripheral = p
        p.delegate = self
        state = .connecting
        deviceName = p.name
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastDeviceKey)
        // connect() verloopt niet: iOS verbindt zodra de band in bereik is, ook op de achtergrond.
        central.connect(p, options: nil)
    }

    /// Schrijft hex-bytes naar een characteristic (voor commando's aan de band).
    func write(hex: String, to id: String) -> String? {
        guard let ch = charRefs[id], let p = peripheral else { return "Characteristic niet gevonden" }
        let clean = hex.replacingOccurrences(of: "0x", with: "").filter(\.isHexDigit)
        guard clean.count % 2 == 0, !clean.isEmpty else { return "Oneven of leeg aantal hex-tekens" }
        var bytes = [UInt8](); var i = clean.startIndex
        while i < clean.endIndex { let j = clean.index(i, offsetBy: 2); bytes.append(UInt8(clean[i..<j], radix: 16)!); i = j }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(bytes), for: ch, type: type)
        raw.log(service: ch.service?.uuid.uuidString ?? "", char: ch.uuid.uuidString, kind: "WRITE", data: Data(bytes))
        return nil
    }

    /// Stuurt een Whoop-commando naar FD4B0002 (met CRC's). Alleen voor veilige, lezende commando's.
    func sendWhoop(cmd: UInt8, body: [UInt8]) -> String? {
        guard let p = peripheral, let ch = charRefs.first(where: { $0.key.hasPrefix("FD4B0001") && $0.key.hasSuffix("FD4B0002-CCE1-4033-93CE-002D5875F58A") })?.value
        else { return "Whoop-service niet gevonden. Verbind eerst." }
        let f = whoop.frame(cmd: cmd, body: body)
        p.writeValue(f, for: ch, type: .withResponse)
        raw.log(service: ch.service?.uuid.uuidString ?? "", char: ch.uuid.uuidString, kind: "WRITE", data: f)
        return nil
    }

    func read(_ id: String) { if let ch = charRefs[id] { peripheral?.readValue(for: ch) } }

    func disconnect() {
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
        state = .idle
    }

    func resetSession() {
        samples = []; rrWindow = []; sum = 0; count = 0
        sessionMin = nil; sessionMax = nil; sessionAvg = nil; rmssd = nil
        sessionStart = state == .connected ? Date() : nil
    }

    private func reconnectLast() {
        guard let s = UserDefaults.standard.string(forKey: Self.lastDeviceKey), let id = UUID(uuidString: s) else { return }
        connect(id)
    }

    // MARK: decodering Heart Rate Measurement (Bluetooth SIG, 0x2A37)

    private func handleHR(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2 else { return }
        let flags = b[0]
        var i = 1
        let hr: Int
        if flags & 0x01 != 0 {
            guard b.count >= 3 else { return }
            hr = Int(b[1]) | Int(b[2]) << 8; i = 3
        } else { hr = Int(b[1]); i = 2 }
        if flags & 0x08 != 0 { i += 2 }   // Energy Expended
        var rrs: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < b.count {
                rrs.append(Double(Int(b[i]) | Int(b[i + 1]) << 8) / 1024.0 * 1000.0)
                i += 2
            }
        }
        if flags & 0x04 != 0 { contact = flags & 0x02 != 0 ? "goed" : "geen contact" } else { contact = "niet gemeld" }

        let now = Date()
        if sessionStart == nil { sessionStart = now }
        if hr > 0 {
            bpm = hr
            sum += Double(hr); count += 1
            sessionMin = min(sessionMin ?? hr, hr)
            sessionMax = max(sessionMax ?? hr, hr)
            sessionAvg = sum / Double(count)
            samples.append(Sample(time: now, bpm: hr))
            samples.removeAll { now.timeIntervalSince($0.time) > 300 }
        }
        if let last = rrs.last { lastRR = last }
        rrWindow.append(contentsOf: rrs.map { (now, $0) })
        rrWindow.removeAll { now.timeIntervalSince($0.0) > 60 }
        let w = rrWindow.map(\.1)
        if w.count > 4 {
            var s = 0.0, n = 0
            for k in 1..<w.count { let d = w[k] - w[k - 1]; if abs(d) < 300 { s += d * d; n += 1 } }
            if n > 0 { rmssd = (s / Double(n)).squareRoot() }
        }
        recorder.append(time: now, bpm: hr, rr: rrs, battery: battery)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            if state == .off || state == .unauthorized { state = .idle }
            if peripheral == nil { reconnectLast() }
        case .unauthorized: state = .unauthorized
        default: state = .off
        }
    }

    /// iOS heeft de app op de achtergrond opnieuw gestart voor een BLE-gebeurtenis.
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p
            p.delegate = self
            peripherals[p.identifier] = p
            deviceName = p.name
            state = p.state == .connected ? .connected : .connecting
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String)
        guard let name, !name.isEmpty else { return }   // naamloze apparaten overslaan
        peripherals[p.identifier] = p
        if let k = found.firstIndex(where: { $0.id == p.identifier }) { found[k].rssi = rssi.intValue }
        else { found.append(Found(id: p.identifier, name: name, rssi: rssi.intValue)) }
        found.sort { ($0.name.lowercased().contains("whoop") ? 0 : 1, -$0.rssi) < ($1.name.lowercased().contains("whoop") ? 0 : 1, -$1.rssi) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected
        deviceName = p.name
        if sessionStart == nil { sessionStart = Date() }
        chars = []; charRefs = [:]
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if !userDisconnected { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        bpm = nil
        if userDisconnected { state = .idle; return }
        state = .connecting
        c.connect(p, options: nil)   // wacht tot de band terug in bereik is
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            let pr = ch.properties
            var names: [String] = []
            if pr.contains(.read) { names.append("read") }
            if pr.contains(.write) { names.append("write") }
            if pr.contains(.writeWithoutResponse) { names.append("writeNR") }
            if pr.contains(.notify) { names.append("notify") }
            if pr.contains(.indicate) { names.append("indicate") }
            let info = CharInfo(service: s.uuid.uuidString, uuid: ch.uuid.uuidString, props: names.joined(separator: " · "))
            charRefs[info.id] = ch
            if !chars.contains(where: { $0.id == info.id }) { chars.append(info) }
            // Alles op notify/indicate zetten, zodat de verkenner alle data ziet.
            if pr.contains(.notify) || pr.contains(.indicate) { p.setNotifyValue(true, for: ch) }
            if pr.contains(.read) { p.readValue(for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        let id = (ch.service?.uuid.uuidString ?? "") + "/" + ch.uuid.uuidString
        if let k = chars.firstIndex(where: { $0.id == id }) { chars[k].notifying = ch.isNotifying }
        if let error { raw.log(service: ch.service?.uuid.uuidString ?? "", char: ch.uuid.uuidString, kind: "ERROR", data: Data(), note: error.localizedDescription) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        let sid = ch.service?.uuid.uuidString ?? ""
        let id = sid + "/" + ch.uuid.uuidString
        if let k = chars.firstIndex(where: { $0.id == id }) {
            chars[k].last = d.map { String(format: "%02x", $0) }.joined(separator: " ")
            chars[k].count += 1
        }
        raw.log(service: sid, char: ch.uuid.uuidString, kind: ch.isNotifying ? "NOTIFY" : "READ", data: d)
        if sid.hasPrefix("FD4B") { whoop.handle(d, channel: ch.uuid.uuidString) }
        if ch.uuid == Self.hrMeasurement { handleHR(d) }
        else if ch.uuid == Self.batteryLevel, let v = d.first { battery = Int(v) }
    }
}
