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
        var rr: [Int] = []
        var motion: [Float] = []
        var temp2: Double = 0, temp3: Double = 0
        /// Stappenteller (u16LE @61), cumulatief sinds de laatste herstart van de band.
        var steps: Int?
    }

    @Published private(set) var frames = 0
    @Published private(set) var badFrames = 0
    @Published private(set) var typeCounts: [UInt8: Int] = [:]
    @Published private(set) var lastRecord: Record?
    @Published private(set) var records = 0
    @Published private(set) var lastLiveTime: Date?
    @Published private(set) var lastResponse: String?
    @Published private(set) var liveHR: Int?
    @Published private(set) var liveRR: [Int] = []
    @Published private(set) var logLines: [String] = []
    private var seq: UInt8 = 0

    /// Bouwt een commandoframe (type 0x23) met geldige CRC16-header en CRC32-trailer.
    /// Gecontroleerd tegen het bekende hello-frame AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D.
    func frame(cmd: UInt8, body: [UInt8]) -> Data {
        seq &+= 1
        var payload: [UInt8] = [0x23, seq, cmd] + body
        while payload.count % 4 != 0 { payload.append(0) }
        let len = payload.count + 4
        var f: [UInt8] = [0xAA, 0x01, UInt8(len & 0xFF), UInt8(len >> 8), 0x00, 0x01]
        let c16 = Self.crc16Modbus(f[0..<6])
        f += [UInt8(c16 & 0xFF), UInt8(c16 >> 8)]
        f += payload
        let c32 = Self.crc32(payload)
        f += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8(c32 >> 24)]
        return Data(f)
    }

    static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for x in b { c ^= UInt32(x); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 } }
        return ~c
    }

    var onRecord: ((Record) -> Void)?
    /// Live HR en RR-intervallen (ms) uit het realtime-pakket 0x28.
    var onLive: ((Int, [Int]) -> Void)?
    /// Einde van een historie-burst (0x31 sub 2): de 8 bytes trim (u32 trim + u32, @21) voor de ack (cmd 23).
    var onHistoryEnd: (([UInt8]) -> Void)?
    /// Antwoord op een commando (0x24): cmd, resultaat (0 fout, 1 ok, 2 bezig, 3 niet ondersteund).
    var onResponse: ((UInt8, UInt8) -> Void)?
    /// Zelfde antwoord met de body (vanaf byte 13, zonder CRC32), bv. voor het uitlezen van de bandwekker.
    var onResponseBody: ((UInt8, UInt8, [UInt8]) -> Void)?
    /// Historie volledig overgedragen (0x31 sub 3).
    var onHistoryComplete: (() -> Void)?
    @Published private(set) var bursts = 0
    private var seen = Set<UInt32>()
    private var file: FileHandle?
    private var writeFailed = false
    private let iso = ISO8601DateFormatter()

    static func crc16Modbus(_ b: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0xFFFF
        for x in b { c ^= UInt16(x); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 } }
        return c
    }

    /// CRC32 over byte 8 tot de laatste 4 bytes klopt met de trailer (geverifieerd op alle frames in Sams opnames).
    static func trailerOK(_ f: [UInt8]) -> Bool {
        guard f.count >= 12 else { return false }
        let n = f.count
        let stored = UInt32(f[n - 4]) | UInt32(f[n - 3]) << 8 | UInt32(f[n - 2]) << 16 | UInt32(f[n - 1]) << 24
        return crc32(Array(f[8..<(n - 4)])) == stored
    }

    /// Records met een onmogelijke tijd (klok van de band niet gezet, kapot frame) slaan we over:
    /// die zouden anders als een dag in 1970 of ver in de toekomst worden opgeslagen.
    static func plausibleTime(_ t: UInt32, now: Date = Date()) -> Bool {
        t >= 1_577_836_800 && TimeInterval(t) <= now.timeIntervalSince1970 + 86_400   // 2020-01-01 … morgen
    }

    private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private var buffers: [String: [UInt8]] = [:]
    @Published private(set) var imuFrames = 0
    @Published private(set) var lastAccel: (Int, Int, Int)?

    /// Leegt de fragmentbuffers (bij een nieuwe verbinding hoort oude halve data er niet meer bij).
    func resetBuffers() { buffers = [:] }

    /// Voegt fragmenten samen: grote frames (bv. IMU, 1244 B) komen verdeeld over meerdere notificaties.
    func handle(_ data: Data, channel: String) {
        var buf = buffers[channel, default: []] + [UInt8](data)
        var i = 0
        while i < buf.count {
            if buf[i] != 0xAA || (i + 1 < buf.count && buf[i + 1] != 0x01) { i += 1; continue }
            // Pas de lengte vertrouwen als de header-CRC klopt; anders is deze 0xAA toevallig een databyte.
            guard buf.count - i >= 8 else { break }
            let header = buf[i..<(i + 6)]
            guard Self.crc16Modbus(header) == UInt16(u16(buf, i + 6)) else { i += 1; continue }
            let total = u16(buf, i + 2) + 8
            guard total >= 12, total <= 4096 else { i += 1; badFrames += 1; continue }
            guard buf.count - i >= total else { break }
            // Ook de CRC32-trailer controleren: valt er een notificatie weg, dan zou een frame anders de bytes van de
            // volgende frames opslokken (die gaan dan verloren). Met de controle zoekt de parser byte voor byte verder.
            let f = Array(buf[i..<(i + total)])
            guard Self.trailerOK(f) else { i += 1; badFrames += 1; continue }
            handle(Data(f))
            i += total
        }
        buf.removeFirst(i)
        // Nooit eindeloos wachten op een onvolledig frame.
        if buf.count > 8192 { buf.removeAll() }
        buffers[channel] = buf
    }

    func handle(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] == 0xAA, b[1] == 0x01, u16(b, 2) + 8 == b.count,
              Self.crc16Modbus(b[0..<6]) == UInt16(u16(b, 6)) else { badFrames += 1; return }
        frames += 1
        BandLog.shared.append(b)
        let type = b[8]
        typeCounts[type, default: 0] += 1

        switch type {
        case 0x2F where b[9] == 0x12 && b.count >= 124:
            let t = u32(b, 15)
            guard Self.plausibleTime(t) else { break }
            let hr = Int(b[22])
            let raw = Double(u16(b, 73)) / 100
            var rec = Record(time: t, hr: hr, skinTemp: (5...45).contains(raw) ? raw : nil)
            // Gevonden in Sams data: RR-aantal @23, RR u16LE in ms @24+2i; 4 floats @41 (oriëntatie/beweging, |q|≈1 in rust);
            // u16 @69 en @71 / 10 ≈ 29–31 °C (extra temperaturen, voorlopig).
            let n = min(Int(b[23]), 4)
            rec.rr = (0..<n).map { u16(b, 24 + 2 * $0) }
            rec.motion = (0..<4).map { Float(bitPattern: u32(b, 41 + 4 * $0)) }
            rec.temp2 = Double(u16(b, 69)) / 10
            rec.temp3 = Double(u16(b, 71)) / 10
            rec.steps = u16(b, 61)
            lastRecord = rec
            if seen.count > 200_000 { seen.removeAll() }   // geheugen begrenzen; DayStore ontdubbelt ook
            if seen.insert(t).inserted {
                records += 1
                write(rec)
                onRecord?(rec)
            }
        case 0x2B where b.count >= 1244:
            imu(b)
        case 0x2F where b[9] == 0x15 && b.count >= 1244:
            imu(b)
        case 0x31 where b.count >= 15:
            // Metadata: sub @10 = 1 START, 2 END (trim @21, 8 bytes), 3 COMPLETE. Tijd u32LE @11.
            let t = u32(b, 11)
            lastLiveTime = Date(timeIntervalSince1970: TimeInterval(t))
            if b[10] == 2, b.count >= 33 {
                bursts += 1
                onHistoryEnd?(Array(b[21..<29]))
            } else if b[10] == 3 {
                onHistoryComplete?()
            }
        case 0x28 where b.count >= 18:
            // Type 40: realtime HR/RR (na cmd 3). Tijd u32LE @10, HR u8 @16, aantal RR u8 @17, RR u16LE @18 in 1/1024 s.
            lastLiveTime = Date(timeIntervalSince1970: TimeInterval(u32(b, 10)))
            liveHR = Int(b[16])
            let n = min(Int(b[17]), (b.count - 22) / 2)
            liveRR = (0..<max(0, n)).map { (u16(b, 18 + 2 * $0) * 1000 + 512) / 1024 }
            onLive?(Int(b[16]), liveRR)
        case 0x32 where b.count > 25:
            // Type 50: tekstlog van de firmware.
            let txt = String(decoding: b[21..<(b.count - 4)].filter { $0 >= 0x20 && $0 < 0x7F || $0 == 0x0A }, as: UTF8.self)
            for line in txt.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                logLines.append(String(line))
            }
            if logLines.count > 50 { logLines.removeFirst(logLines.count - 50) }
        case 0x24 where b.count >= 13:
            let res = ["mislukt", "ok", "bezig", "niet ondersteund"]
            lastResponse = "cmd \(b[10]) → " + (Int(b[12]) < res.count ? res[Int(b[12])] : "code \(b[12])")
            onResponse?(b[10], b[12])
            onResponseBody?(b[10], b[12], b.count > 17 ? Array(b[13..<(b.count - 4)]) : [])
        default:
            break
        }
    }

    /// R21 IMU: accel X/Y/Z i16LE @28/228/428 (+2i), aantal @24.
    private func imu(_ b: [UInt8]) {
        imuFrames += 1
        let i16 = { (i: Int) in Int(Int16(bitPattern: UInt16(self.u16(b, i)))) }
        lastAccel = (i16(28), i16(228), i16(428))
    }

    /// Historische records worden direct naar whoop_historie_<datum>.csv geschreven.
    private func write(_ r: Record) {
        if file == nil {
            if writeFailed { return }
            let url = Recorder.folder.appendingPathComponent(Recorder.fileName(.whoopHistory))
            guard FileManager.default.createFile(atPath: url.path, contents: Data("tijd;hr_bpm;huidtemp_c;rr_ms;q0;q1;q2;q3;temp2_c;temp3_c\n".utf8)) else { writeFailed = true; return }
            file = FileHandle.appending(to: url)
        }
        let t = iso.string(from: Date(timeIntervalSince1970: TimeInterval(r.time)))
        let temp = r.skinTemp.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
        let nl = { (d: Double) in String(format: "%.3f", d).replacingOccurrences(of: ".", with: ",") }
        let q = r.motion.map { nl(Double($0)) }.joined(separator: ";")
        let rr = r.rr.map(String.init).joined(separator: " ")
        if let f = file, !f.safeWrite(Data("\(t);\(r.hr);\(temp);\(rr);\(q);\(nl(r.temp2));\(nl(r.temp3))\n".utf8)) {
            try? f.close(); file = nil; writeFailed = true
        }
    }

    func reset() {
        try? file?.close(); file = nil; writeFailed = false
        seen = []; records = 0; frames = 0; badFrames = 0; typeCounts = [:]; lastRecord = nil
    }
}
