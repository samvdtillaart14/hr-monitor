import Foundation

/// Inzichten bovenop de nachtwaarden: ziekte-waarschuwing, weekrapport en dagboek-effecten.
/// Werkt alleen op NightMetrics, dus onafhankelijk van de bron (Whoop nu, later bv. Garmin).
public enum Insights {

    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func sd(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }

    // MARK: ziekte-waarschuwing

    public struct Deviation: Equatable, Sendable {
        public let metric: String      // "rhr", "hrv", "skin", "resp", "spo2"
        public let value: Double, baseline: Double
        /// afwijking in standaarddeviaties, in de "ziek"-richting (positief = slechter)
        public var z: Double = 0
        public var delta: Double { value - baseline }
    }

    /// Afwijkingen van vannacht t.o.v. de eigen basislijn (min. 5 eerdere nachten).
    /// Een afwijking telt als hij én buiten 1,5 SD valt én groter is dan een vaste drempel
    /// (rust-HR +3 bpm, HRV −15%, huidtemp +0,4 °C, ademfrequentie +1/min, SpO2 −2%).
    public static func deviations(_ n: NightMetrics, history: [NightMetrics]) -> [Deviation] {
        signals(n, history: history).filter(\.deviates).map(\.deviation)
    }

    /// Stand van elk signaal t.o.v. je basislijn (voor de kaart op Gezondheid), ook als het niet afwijkt.
    public struct Signal: Sendable {
        public let deviation: Deviation
        public let deviates: Bool
    }
    public static func signals(_ n: NightMetrics, history: [NightMetrics]) -> [Signal] {
        var out: [Signal] = []
        func check(_ name: String, _ v: Double?, _ hist: [Double], minDelta: (Double) -> Double, up: Bool) {
            guard let v, hist.count >= 5, let m = mean(hist), let s = sd(hist) else { return }
            let d = up ? v - m : m - v
            var dev = Deviation(metric: name, value: v, baseline: m)
            dev.z = d / max(s, 1e-6)
            out.append(Signal(deviation: dev, deviates: d > max(1.5 * s, minDelta(m))))
        }
        check("rhr", n.rhr, history.compactMap(\.rhr), minDelta: { _ in 3 }, up: true)
        check("hrv", n.hrv, history.compactMap(\.hrv), minDelta: { 0.15 * $0 }, up: false)
        check("skin", n.skinTemp, history.compactMap(\.skinTemp), minDelta: { _ in 0.4 }, up: true)
        check("resp", n.resp, history.compactMap(\.resp), minDelta: { _ in 1 }, up: true)
        check("spo2", n.spo2, history.compactMap(\.spo2), minDelta: { _ in 2 }, up: false)
        return out
    }

    /// Waarschuwen als minstens twee waarden tegelijk afwijken (één alleen is vaak alcohol, laat eten of een slechte nacht).
    /// Ook waarschuwen als één signaal twee nachten op rij afwijkt (bv. huidtemp of rust-HR blijft verhoogd):
    /// een enkele nacht kan alcohol zijn, twee nachten achter elkaar is vaker beginnende ziekte.
    /// `history` loopt tot en met gisteravond (laatste element = vorige nacht).
    public static func illnessWarning(_ n: NightMetrics, history: [NightMetrics]) -> [Deviation]? {
        let d = deviations(n, history: history)
        if d.count >= 2 { return d }
        guard d.count == 1, let prev = history.last else { return nil }
        let before = deviations(prev, history: Array(history.dropLast()))
        return before.contains { $0.metric == d[0].metric } ? d : nil
    }

    // MARK: weekrapport

    public struct WeekSummary: Equatable, Sendable {
        public var nights = 0
        public var recovery: Double?, sleepMin: Double?, sleepPerf: Double?, hrv: Double?, rhr: Double?, consistency: Double?
        public init() {}
    }

    public static func summary(_ ns: [NightMetrics]) -> WeekSummary {
        var w = WeekSummary()
        w.nights = ns.count
        w.recovery = mean(ns.compactMap(\.recovery))
        w.sleepMin = mean(ns.compactMap(\.asleepMin))
        w.sleepPerf = mean(ns.compactMap(\.sleepPerf))
        w.hrv = mean(ns.compactMap(\.hrv))
        w.rhr = mean(ns.compactMap(\.rhr))
        w.consistency = mean(ns.compactMap(\.consistency))
        return w
    }

    /// Eén concreet advies: het zwakste punt van deze week (sleutel + tekst).
    public static func advice(this w: WeekSummary, prev p: WeekSummary) -> (key: String, text: String) {
        if w.nights < 3 { return ("data", "Te weinig nachten gemeten deze week. Laat Pulse 's nachts verbonden, dan wordt het rapport volgende week concreet.") }
        if let m = w.sleepMin, m < 420 {
            let short = Int((450 - m).rounded())
            return ("sleep", "Je sliep gemiddeld \(Int(m) / 60):\(String(format: "%02d", Int(m) % 60)) per nacht. Ga deze week \(short) minuten eerder naar bed.")
        }
        if let c = w.consistency, c < 70 {
            return ("consistency", "Je bedtijden wisselden sterk (regelmaat \(Int(c))%). Kies één vaste bedtijd en houd die ook in het weekend aan, met hooguit 30 minuten speling.")
        }
        if let a = w.rhr, let b = p.rhr, a - b >= 2 {
            return ("rhr", String(format: "Je rust-HR lag %.0f bpm hoger dan vorige week. Plan twee rustige dagen en laat alcohol en laat eten even staan.", a - b))
        }
        if let a = w.hrv, let b = p.hrv, b > 0, a < 0.9 * b {
            return ("hrv", String(format: "Je HRV daalde %.0f%% t.o.v. vorige week. Houd de belasting de komende dagen licht en slaap minstens 8 uur.", 100 * (1 - a / b)))
        }
        if let r = w.recovery, r >= 67 {
            return ("good", "Goed hersteld deze week. Ruimte voor één zwaardere training.")
        }
        return ("keep", "Stabiele week. Houd je huidige bedtijd en ritme vast.")
    }

    // MARK: dagboek

    public struct Effect: Equatable, Sendable {
        public let tag: String
        public let withCount: Int, withoutCount: Int
        /// verschil (met − zonder) in de nacht erna
        public let recovery: Double?, hrv: Double?, rhr: Double?, sleepPerf: Double?
    }

    /// Effect van een dagboekfactor op de nacht erna.
    /// - entries: dagboek per avond (jjjj-mm-dd → factoren); de nacht erna staat onder de volgende dag.
    /// - nights: nachtwaarden per ochtend (jjjj-mm-dd).
    /// - nextDay: geeft de sleutel van de dag erna.
    public static func effects(entries: [String: Set<String>], nights: [String: NightMetrics], tags: [String],
                               minEach: Int = 5, nextDay: (String) -> String) -> [Effect] {
        var out: [Effect] = []
        for tag in tags {
            var with: [NightMetrics] = [], without: [NightMetrics] = []
            for (day, set) in entries {
                guard let n = nights[nextDay(day)] else { continue }
                if set.contains(tag) { with.append(n) } else { without.append(n) }
            }
            guard with.count >= minEach, without.count >= minEach else { continue }
            func diff(_ k: KeyPath<NightMetrics, Double?>) -> Double? {
                guard let a = mean(with.compactMap { $0[keyPath: k] }), let b = mean(without.compactMap { $0[keyPath: k] }) else { return nil }
                return a - b
            }
            out.append(Effect(tag: tag, withCount: with.count, withoutCount: without.count,
                              recovery: diff(\.recovery), hrv: diff(\.hrv), rhr: diff(\.rhr), sleepPerf: diff(\.sleepPerf)))
        }
        // grootste effect op herstel eerst
        return out.sorted { abs($0.recovery ?? 0) > abs($1.recovery ?? 0) }
    }
}
