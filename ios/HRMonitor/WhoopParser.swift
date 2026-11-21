import Foundation

/// Decoder voor de eigen WHOOP 5.0/MG-service (FD4B0001-…).
///
/// Frame (geverifieerd op Sams band, firmware 50.43.2.0):
///   [0] AA  [1] 01  [2..3] lengte u16LE (= totaal − 8)  [4..5] header
///   [6..7] CRC16-Modbus over bytes 0..5 (LE)  [8] pakkettype  [9] layout/seq  …  laatste 4 bytes CRC32
///
/// Pakkettypen die we zagen: 0x2F (47) historische records, 0x31 (49) live, 0x24 (36) commando-antwoord.
/// Layout R18 (type 0x2F, byte 9 = 0x12, 124 bytes): Unix-tijd u32LE @15, hartslag u8 @22, huidtemp u16LE @73 / 100 °C.
/// Offsets voor R18 komen uit openbaar reverse-engineeringwerk (ryanbr/noop) en zijn nog niet door ons geverifieerd.
final class WhoopParser: ObservableObject {
    struct Record: Identifiable {
        var id: UInt32 { time }
        let time: UInt32
        let hr: Int
        let skinTemp: Double?
    }

    @Published private(set) var frames = 0
    @Published private(set) var badFrames = 0
    @Published private(set) var typeCounts: [UInt8: Int] = [:]
    @Published private(set) var lastRecord: Record?
    @Published private(set) var records = 0
    @Published private(set) var lastLiveTime: Date?

    private var seen = Set<UInt32>()
    private var file: FileHandle?
    private let iso = ISO8601DateFormatter()

    static func crc16Modbus(_ b: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0xFFFF
        for x in b { c ^= UInt16(x); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 } }
        return c
    }

    private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    func handle(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] == 0xAA, b[1] == 0x01, u16(b, 2) + 8 == b.count,
              Self.crc16Modbus(b[0..<6]) == UInt16(u16(b, 6)) else { badFrames += 1; return }
        frames += 1
        let type = b[8]
        typeCounts[type, default: 0] += 1

        switch type {
        case 0x2F where b[9] == 0x12 && b.count >= 124:
            let t = u32(b, 15)
            let hr = Int(b[22])
            let raw = Double(u16(b, 73)) / 100
            let rec = Record(time: t, hr: hr, skinTemp: (5...45).contains(raw) ? raw : nil)
            lastRecord = rec
            if seen.insert(t).inserted {
                records += 1
                write(rec)
            }
        case 0x31 where b.count >= 15:
            let t = u32(b, 11)
            lastLiveTime = Date(timeIntervalSince1970: TimeInterval(t))
        default:
            break
        }
    }

    /// Historische records worden direct naar whoop_historie_<datum>.csv geschreven.
    private func write(_ r: Record) {
        if file == nil {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let url = Recorder.folder.appendingPathComponent("whoop_historie_\(df.string(from: Date())).csv")
            FileManager.default.createFile(atPath: url.path, contents: Data("tijd;hr_bpm;huidtemp_c\n".utf8))
            file = try? FileHandle(forWritingTo: url)
            file?.seekToEndOfFile()
        }
        let t = iso.string(from: Date(timeIntervalSince1970: TimeInterval(r.time)))
        let temp = r.skinTemp.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
        file?.write(Data("\(t);\(r.hr);\(temp)\n".utf8))
    }

    func reset() {
        try? file?.close(); file = nil
        seen = []; records = 0; frames = 0; badFrames = 0; typeCounts = [:]; lastRecord = nil
    }
}
