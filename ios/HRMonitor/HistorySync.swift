import Foundation

/// Beslislogica van de historie-sync (zelf bevestigen met cmd 23), los van CoreBluetooth zodat hij testbaar is.
/// BLEManager voert de acties uit (frame sturen, timers, UserDefaults, statusteksten).
///
/// Verloop per burst: band stuurt START → records → END (met 8 bytes trim) → wij of de Whoop-app sturen
/// cmd 23 met die trim → band antwoordt 0x24 (cmd 23, resultaat) → volgende burst … → COMPLETE.
struct HistorySync {
    static let ackCmd: UInt8 = 23

    private(set) var acksSent = 0
    private(set) var whoopAckedThisSync = false
    private(set) var ourAckPending = false
    private(set) var pendingTrim: [UInt8]?

    /// Mogelijke opbouw van de ack. Variant 0 = `01` + 8 bytes uit END (trim u32 + u32),
    /// variant 1 = `01` + trim u32 + 4 nullen (zoals bij de Whoop 4). Bij "mislukt" schakelt de app om.
    static func ackBody(_ trim: [UInt8], variant: Int) -> [UInt8] {
        variant == 1 ? [0x01] + Array(trim.prefix(4)) + [0, 0, 0, 0] : [0x01] + trim
    }

    /// Is dit ruwe frame een cmd-23-commando (type 0x23, cmd @10)? Handmatig versturen wordt geblokkeerd.
    static func isAckCommand(_ bytes: [UInt8]) -> Bool {
        bytes.count > 10 && bytes[0] == 0xAA && bytes[8] == 0x23 && bytes[10] == ackCmd
    }

    /// END van een burst: trim onthouden. Geeft het aantal seconden dat we wachten voor we zelf bevestigen.
    /// Eerste burst (of als de Whoop-app eerder bevestigde): 3 s, zodat een draaiende Whoop-app voorgaat.
    mutating func burstEnded(trim: [UInt8]) -> Double {
        pendingTrim = trim
        return (whoopAckedThisSync || acksSent == 0) ? 3 : 0.3
    }

    /// Na het wachten: de body om te sturen, of nil als de burst al bevestigd is of er intussen een nieuwere kwam.
    mutating func ackDue(trim: [UInt8], variant: Int) -> [UInt8]? {
        guard let t = pendingTrim, t == trim else { return nil }
        pendingTrim = nil
        return Self.ackBody(t, variant: variant)
    }

    /// Onze ack is verstuurd.
    mutating func ackSent() { ourAckPending = true; acksSent += 1 }

    enum Outcome: Equatable { case ignored, accepted, whoopAcked, rejected }

    /// Antwoord van de band (type 0x24).
    mutating func response(cmd: UInt8, result: UInt8) -> Outcome {
        // 2 = bezig: het eindantwoord volgt nog, dus nog niet beslissen wiens ack het was.
        guard cmd == Self.ackCmd, result != 2 else { return .ignored }
        let ours = ourAckPending
        ourAckPending = false
        if result == 1 {
            pendingTrim = nil
            if ours { return .accepted }
            whoopAckedThisSync = true
            return .whoopAcked
        }
        return ours && result == 0 ? .rejected : .ignored
    }

    /// Einde van een sync (COMPLETE) of start van een nieuwe: tellers terug. Geeft het aantal eigen acks.
    @discardableResult
    mutating func reset() -> Int {
        let n = acksSent
        acksSent = 0; whoopAckedThisSync = false
        return n
    }
}
