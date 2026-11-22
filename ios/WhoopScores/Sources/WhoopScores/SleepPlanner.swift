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

    // MARK: Wekker op de band (experimenteel)

    /// Commando "wekker zetten". Op de Whoop 4.0 is dit 0x42 (66) met `01` + u32 Unix-tijd (LE) + nullen
    /// (openbaar reverse-engineeringwerk). Op de 5.0/MG is dat nog niet geverifieerd: de band antwoordt met
    /// resultaat 1 (ok) of 3 (niet ondersteund), zo is het te controleren.
    public static let bandAlarmCmd: UInt8 = 0x42

    public static func bandAlarmBody(unix: UInt32) -> [UInt8] {
        [0x01, UInt8(unix & 0xFF), UInt8((unix >> 8) & 0xFF), UInt8((unix >> 16) & 0xFF), UInt8(unix >> 24), 0, 0, 0, 0]
    }

    /// Een commando om de bandwekker te wissen kennen we niet. Uitzetten = de wekker ver in de toekomst zetten.
    public static func bandAlarmParkedTime(now: Date) -> UInt32 {
        UInt32(now.addingTimeInterval(365 * 86400).timeIntervalSince1970)
    }

    /// "8:05" (uren:minuten).
    public static func hm(_ min: Double) -> String {
        guard min.isFinite else { return "--" }
        let m = Int(min.rounded()); return "\(m / 60):\(String(format: "%02d", abs(m % 60)))"
    }
}
