import Foundation

// Slaapplanner voor vannacht: hoeveel slaap je nodig hebt, hoe laat je naar bed moet om een doel te halen,
// en wanneer de (slimme) wekker afgaat. Alleen rekenwerk; de app regelt opslag, meldingen en de band.

/// Hoe de wekker beslist wanneer hij afgaat. De ingestelde tijd is altijd de laatste mogelijke tijd.
public enum AlarmMode: String, Codable, CaseIterable, Sendable {
    /// Precies op de ingestelde tijd.
    case exact
    /// Zodra je je slaapdoel hebt gehaald (op zijn vroegst `SleepPlanner.smartWindowMin` voor de ingestelde tijd).
    case sleepGoal
    /// Zodra je geschatte herstel groen is (≥ 67 %), in hetzelfde venster.
    case recovered
}

/// Wat je morgen wilt halen: een deel van je slaapbehoefte.
public enum SleepGoal: String, Codable, CaseIterable, Sendable {
    case full, perform, minimum
    public var fraction: Double {
        switch self { case .full: return 1.0; case .perform: return 0.85; case .minimum: return 0.70 }
    }
}

/// Eén regel van het wekkerschema: tijd (minuten na middernacht) en modus.
public struct AlarmRule: Codable, Equatable, Sendable {
    public var minutes: Int
    public var mode: AlarmMode
    public var enabled: Bool
    public init(minutes: Int, mode: AlarmMode, enabled: Bool = true) {
        self.minutes = minutes; self.mode = mode; self.enabled = enabled
    }
}

/// Wekkerschema: werkdagen (ma–vr) en weekend (za–zo), plus een eenmalige afwijking voor één ochtend.
public struct AlarmSchedule: Codable, Equatable, Sendable {
    public struct Override: Codable, Equatable, Sendable {
        /// Dag waarop je wakker wordt (jjjj-mm-dd, lokale tijd).
        public var day: String
        public var rule: AlarmRule
        public init(day: String, rule: AlarmRule) { self.day = day; self.rule = rule }
    }
    /// Hoofdschakelaar: uit = geen wekker, wel een geplande wektijd.
    public var enabled: Bool
    public var weekday: AlarmRule
    public var weekend: AlarmRule
    public var override: Override?

    public init(enabled: Bool = false, weekday: AlarmRule = AlarmRule(minutes: 7 * 60, mode: .exact),
                weekend: AlarmRule = AlarmRule(minutes: 10 * 60, mode: .sleepGoal), override: Override? = nil) {
        self.enabled = enabled; self.weekday = weekday; self.weekend = weekend; self.override = override
    }

    public static let standard = AlarmSchedule()

    static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Regel voor de ochtend van `day`.
    public func rule(for day: Date, _ cal: Calendar = .current) -> AlarmRule {
        if let o = override, o.day == Self.dayKey(day, cal) { return o.rule }
        return cal.isDateInWeekend(day) ? weekend : weekday
    }

    /// Eerstvolgende wektijd na `now`: vandaag als die nog moet komen, anders morgen (of overmorgen).
    public func nextWake(after now: Date, _ cal: Calendar = .current) -> (date: Date, rule: AlarmRule) {
        let today = cal.startOfDay(for: now)
        for k in 0...2 {
            guard let d = cal.date(byAdding: .day, value: k, to: today) else { continue }
            let r = rule(for: d, cal)
            if let t = cal.date(bySettingHour: r.minutes / 60, minute: r.minutes % 60, second: 0, of: d), t > now {
                return (t, r)
            }
        }
        let d = cal.date(byAdding: .day, value: 1, to: today) ?? now
        return (d.addingTimeInterval(Double(weekday.minutes) * 60), weekday)
    }

    /// Eenmalige afwijkingen voor ochtenden die voorbij zijn, vervallen.
    public mutating func dropExpiredOverride(now: Date, _ cal: Calendar = .current) {
        if let o = override, o.day < Self.dayKey(now, cal) { override = nil }
    }
}

/// Uitkomst van de planner voor vannacht.
public struct TonightPlan: Equatable, Sendable {
    /// Opbouw van de slaapbehoefte (min): basis, belasting, schuld, dutjes, totaal.
    public var need: WhoopScores.NeedParts
    public var debtMin: Double
    public var goal: SleepGoal
    /// Slaap die je wilt halen (min) = doel × behoefte.
    public var goalSleepMin: Double
    /// Tijd in bed (min): slaap / efficiëntie + inslaaptijd.
    public var inBedMin: Double
    public var efficiency: Double
    public var latencyMin: Double
    public var bedtime: Date
    public var wake: Date
}

public enum SleepPlanner {
    /// Slimme modi gaan op zijn vroegst zoveel minuten voor de ingestelde tijd af.
    public static let smartWindowMin = 90.0
    /// Herstel vanaf deze waarde telt als groen.
    public static let greenRecovery = 67
    /// Inslaaptijd als er nog niets is gemeten.
    public static let defaultLatencyMin = 15.0
    /// Slaapefficiëntie (%) als er nog geen nachten zijn.
    public static let defaultEfficiency = 90.0

    /// Slaapbehoefte voor vannacht uit eigen data:
    /// - prevDebtMin/prevNeedMin/prevAsleepMin: de afgelopen nacht (schuld waarmee die begon, behoefte en geslapen tijd);
    /// - strainToday: belasting van vandaag tot nu;
    /// - napMinToday: dutjes van vandaag.
    public static func tonightNeed(prevDebtMin: Double?, prevNeedMin: Double?, prevAsleepMin: Double?,
                                   strainToday: Double, napMinToday: Double, _ cal: Calibration = .standard) -> (parts: WhoopScores.NeedParts, debtMin: Double) {
        let debt = WhoopScores.sleepDebt(prevDebtMin: prevDebtMin ?? 0, prevNeedMin: prevNeedMin ?? .nan,
                                         prevAsleepMin: prevAsleepMin ?? .nan, cal)
        return (WhoopScores.sleepNeedParts(debtMin: debt, prevDayStrain: strainToday, napMin: napMinToday, cal), debt)
    }

    /// Bedtijd om `goal` van `needMin` te halen vóór `wake`.
    public static func plan(need: WhoopScores.NeedParts, debtMin: Double = 0, goal: SleepGoal, wake: Date,
                            efficiency: Double? = nil, latencyMin: Double? = nil) -> TonightPlan {
        let eff = M.clamp((efficiency.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? defaultEfficiency), 60, 100)
        let lat = M.clamp(latencyMin.flatMap { $0.isFinite ? $0 : nil } ?? defaultLatencyMin, 0, 60)
        let sleep = need.total * goal.fraction
        // Afronden op 5 min: een planning op de minuut suggereert meer precisie dan er is.
        let inBed = (sleep / (eff / 100) + lat) / 5
        let inBedMin = inBed.rounded(.up) * 5
        return TonightPlan(need: need, debtMin: debtMin, goal: goal, goalSleepMin: sleep, inBedMin: inBedMin,
                           efficiency: eff, latencyMin: lat, bedtime: wake.addingTimeInterval(-inBedMin * 60), wake: wake)
    }

    /// Gebruikelijk slaapvenster (minuten na middernacht, lokaal) uit de laatste nachten: mediaan van inslapen en opstaan.
    /// Minder dan 3 nachten: het opgegeven venster.
    public static func usualWindow(_ nights: [(onset: Double, wake: Double)], tzOffsetSec: Int,
                                   fallback: (bed: Int, wake: Int)) -> (bed: Int, wake: Int, measured: Bool) {
        let recent = nights.suffix(14)
        guard recent.count >= 3 else { return (fallback.bed, fallback.wake, false) }
        func local(_ t: Double) -> Int { ((Int((t + Double(tzOffsetSec)) / 60) % 1440) + 1440) % 1440 }
        // Bedtijden rond middernacht: na 12:00 als negatief tellen, zodat 23:30 en 00:30 een uur verschillen.
        let beds = recent.map { n -> Double in let m = local(n.onset); return Double(m >= 720 ? m - 1440 : m) }
        let wakes = recent.map { Double(local($0.wake)) }
        let b = Int(M.median(beds).rounded()), w = Int(M.median(wakes).rounded())
        return ((b + 1440) % 1440, w, true)
    }

    /// Moet de wekker nu afgaan?
    /// - latest: ingestelde tijd (dan altijd); daarvoor alleen in het venster van een slimme modus.
    public static func shouldWake(mode: AlarmMode, now: Date, latest: Date, asleepMin: Double?, goalSleepMin: Double,
                                  recovery: Int?) -> Bool {
        if now >= latest { return true }
        guard mode != .exact, now >= latest.addingTimeInterval(-smartWindowMin * 60) else { return false }
        switch mode {
        case .exact: return false
        case .sleepGoal: return (asleepMin ?? 0) >= goalSleepMin
        case .recovered: return (recovery ?? 0) >= greenRecovery
        }
    }

    // MARK: Wekker op de band

    /// Wekkercommando's van de band (nummers uit openbaar werk aan het Whoop-protocol, o.a. noop).
    /// De Whoop 5.0 weigerde `01` + tijd + 4 nullen; de app probeert daarom meerdere vormen voor SET
    /// en onthoudt welke de band accepteert. GET leest de ingestelde wekker terug (ter controle en om de
    /// juiste vorm te leren), RUN laat de band direct trillen, DISABLE zet de wekker uit.
    public enum BandAlarm {
        public static let set: UInt8 = 66, get: UInt8 = 67, run: UInt8 = 68, disable: UInt8 = 69
        public static func isAlarmCommand(_ c: UInt8) -> Bool { (66...69).contains(c) }
        /// Body voor GET, RUN en DISABLE.
        public static let simpleBody: [UInt8] = [0x01]
        public static let variantCount = 5
        /// Vaste staart van SET op de Whoop 5.0 (uit een Bluetooth-log van de Whoop-app, 22-11-2026):
        /// `00 00` na de tijd, dan `2F 98` + 8 nullen, `07`, `1E 00`. Betekenis niet zeker (vermoedelijk
        /// trilpatroon, herhalingen en duur 30 s); de band accepteerde dit 5 van de 5 keer.
        static let whoop5Tail: [UInt8] = [0, 0, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x07, 0x1E, 0x00]

        static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

        /// Vormen van SET, in de volgorde waarin ze geprobeerd worden.
        /// 0: Whoop 5.0: `04 01` + u32 Unix-tijd (UTC) + vaste staart (21 bytes), zoals de Whoop-app hem stuurt
        /// 1: `01` + u32 Unix-tijd + `00 00` (7 bytes, noop "Rev1", Whoop 4.0)
        /// 2: u32 Unix-tijd + 4 nullen (zonder vormbyte)
        /// 3: `01` + u32 Unix-tijd + u32 tijdzone-offset in s (lokale tijd)
        /// 4: `02` + u32 Unix-tijd + `00 00`
        /// - alarmId: wekkernummer (alleen vorm 0); de Whoop-app gebruikt 1.
        public static func setBody(unix: UInt32, variant: Int, tzOffsetSec: Int = 0, alarmId: UInt8 = 1) -> [UInt8] {
            switch variant {
            case 1: return [0x01] + le32(unix) + [0, 0]
            case 2: return le32(unix) + [0, 0, 0, 0]
            case 3: return [0x01] + le32(unix) + le32(UInt32(bitPattern: Int32(tzOffsetSec)))
            case 4: return [0x02] + le32(unix) + [0, 0]
            default: return [0x04, alarmId] + le32(unix) + whoop5Tail
            }
        }

        /// Korte trilling als bevestiging: een eigen wekker (nummer 8, de echte wekkers gebruiken 1–7) over een paar
        /// seconden, met de staart van de 5.0-wekker maar 1 herhaling en 1 s duur (vermoedelijk @13 herhalingen, @14 duur).
        public static let buzzAlarmId: UInt8 = 8
        public static func buzzBody(unix: UInt32) -> [UInt8] {
            var tail = whoop5Tail
            tail[12] = 0x01; tail[13] = 0x01
            return [0x04, buzzAlarmId] + le32(unix) + tail
        }

        /// Unix-tijd uit een GET-antwoord: eerste plausibele u32 (2020–2100) in de body.
        public static func parseGet(_ body: [UInt8]) -> UInt32? {
            guard body.count >= 4 else { return nil }
            // Offset 1 eerst (na de vormbyte), daarna de rest.
            for i in [1] + (0...(body.count - 4)).filter({ $0 != 1 }) where i + 4 <= body.count {
                let v = UInt32(body[i]) | UInt32(body[i + 1]) << 8 | UInt32(body[i + 2]) << 16 | UInt32(body[i + 3]) << 24
                if v > 1_577_836_800 && v < 4_102_444_800 { return v }
            }
            return nil
        }
    }

    /// "8:05" (uren:minuten).
    public static func hm(_ min: Double) -> String {
        guard min.isFinite else { return "--" }
        let m = Int(min.rounded()); return "\(m / 60):\(String(format: "%02d", abs(m % 60)))"
    }
}
