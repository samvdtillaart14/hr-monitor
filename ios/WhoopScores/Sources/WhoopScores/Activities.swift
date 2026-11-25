import Foundation

/// Samenvatting van één activiteit (workout), berekend uit de hartslag in [start, end].
public struct ActivitySummary: Codable, Sendable, Equatable {
    public var strain: Double = 0
    /// seconden per zone 0–5
    public var zoneSec: [Double] = Array(repeating: 0, count: 6)
    public var avgHr: Double = 0
    public var maxHr: Double = 0
    public var kcal: Double = 0
    /// seconden met een geldige hartslag
    public var measuredSec: Double = 0
    public init() {}
}

/// Instellingen voor automatische herkenning op hartslag.
public struct ActivityDetectionParams: Sendable {
    /// minuut telt als actief vanaf deze fractie van de hartslagreserve
    public var activeReserve: Double = 0.30
    /// gemiddelde reserve over de actieve minuten moet minstens dit zijn
    public var minMeanReserve: Double = 0.38
    /// minimale duur in minuten
    public var minMinutes: Int = 15
    /// rustige of ontbrekende minuten die binnen één activiteit mogen vallen
    public var maxGapMin: Int = 3
    /// minstens dit deel van de minuten moet actief zijn
    public var minActiveFraction: Double = 0.7
    /// aanloop: begin terugzetten zolang de hartslag al boven deze reserve lag (opwarmen telt mee)
    public var rampReserve: Double = 0.20
    /// hooguit zoveel minuten terug
    public var maxLeadMin: Int = 10
    /// minimaal aantal metingen in een minuut om hem mee te tellen
    public var minSamplesPerMin: Int = 6
    /// een activiteit die korter dan dit geleden eindigt kan nog lopen: nog niet melden
    public var settleSec: Double = 300
    public init() {}
}

public struct DetectedActivity: Sendable, Equatable {
    public var start: Double, end: Double
    public var meanReserve: Double
}

extension WhoopScores {

    /// Ondergrens (bpm) van zone 0–5 met het profiel; zone 0 begint bij 0.
    public static func zoneLowerBounds(_ p: Calibration.Profile) -> [Int] {
        (0...5).map { z in
            guard z > 0 else { return 0 }
            let f = Double(4 + z) / 10
            let v = p.zoneMode == "max" ? f * p.maxHr : p.restingHr + f * (p.maxHr - p.restingHr)
            return Int((v - 1e-6).rounded(.up))
        }
    }

    /// Herstel na inspanning: hartslagdaling 1 en 2 minuten na het einde (bpm).
    /// Eind-HR = hoogste 15-s-gemiddelde in de laatste minuut; daarna 15-s-gemiddelden rond +60 en +120 s.
    /// nil als er rond die momenten geen metingen zijn of de eind-HR te laag is (geen echte inspanning).
    public static func heartRateRecovery(_ samples: [Sample], end: Double, minPeakHr: Double = 100) -> (one: Int?, two: Int?) {
        func mean(_ a: Double, _ b: Double) -> Double? {
            let v = samples.filter { $0.t >= a && $0.t < b && $0.hr > 0 }.map(\.hr)
            return v.count >= 5 ? v.reduce(0, +) / Double(v.count) : nil
        }
        let peak = stride(from: end - 60, to: end - 14, by: 5).compactMap { mean($0, $0 + 15) }.max()
        guard let peak, peak >= minPeakHr else { return (nil, nil) }
        let d = { (t: Double) -> Int? in mean(end + t - 7.5, end + t + 7.5).map { Int((peak - $0).rounded()) } }
        return (d(60), d(120))
    }

    /// Statistieken van een activiteit uit de samples (hoeven niet gefilterd te zijn).
    public static func activitySummary(_ samples: [Sample], start: Double, end: Double, _ cal: Calibration = .standard) -> ActivitySummary {
        let s = samples.filter { $0.t >= start && $0.t <= end && $0.hr > 0 }.sorted { $0.t < $1.t }
        var out = ActivitySummary()
        guard !s.isEmpty else { return out }
        let st = strain(s, cal)
        out.strain = st.strain
        out.kcal = calories(s, cal)
        var sum = 0.0
        for i in s.indices {
            let dt = i + 1 < s.count ? min(5, s[i + 1].t - s[i].t) : 1
            out.zoneSec[hrZone(s[i].hr, cal.profile)] += dt
            out.measuredSec += dt
            sum += s[i].hr * dt
        }
        out.avgHr = out.measuredSec > 0 ? sum / out.measuredSec : 0
        // Max over 5-s-blokken: één losse uitschieter telt niet als max.
        var blocks: [Int: (Double, Int)] = [:]
        for x in s { let k = Int(x.t / 5); blocks[k, default: (0, 0)].0 += x.hr; blocks[k, default: (0, 0)].1 += 1 }
        out.maxHr = blocks.values.map { $0.0 / Double($0.1) }.max() ?? 0
        return out
    }

    /// Zoekt aaneengesloten perioden met verhoogde hartslag (boven rust, minimale duur).
    /// `exclude`: perioden die niet mogen meetellen (slaap, al bekende of verwijderde activiteiten).
    public static func detectActivities(_ samples: [Sample], _ cal: Calibration = .standard,
                                        params p: ActivityDetectionParams = .init(),
                                        exclude: [(start: Double, end: Double)] = [],
                                        now: Double = Date().timeIntervalSince1970) -> [DetectedActivity] {
        // Mediaan-HR per minuut
        var perMin: [Int: [Double]] = [:]
        for s in samples where s.hr > 0 { perMin[Int(s.t / 60), default: []].append(s.hr) }
        let prof = cal.profile
        var reserve: [Int: Double] = [:]
        for (m, v) in perMin where v.count >= p.minSamplesPerMin {
            let t = Double(m * 60)
            if exclude.contains(where: { t + 60 > $0.start && t < $0.end }) { continue }
            reserve[m] = reserveFraction(M.median(v), prof)
        }
        let active = reserve.filter { $0.value >= p.activeReserve }.keys.sorted()
        guard !active.isEmpty else { return [] }

        var out: [DetectedActivity] = []
        var runStart = active[0], last = active[0]
        func close() {
            let minutes = last - runStart + 1
            guard minutes >= p.minMinutes else { return }
            let act = active.filter { $0 >= runStart && $0 <= last }
            guard Double(act.count) / Double(minutes) >= p.minActiveFraction else { return }
            let mean = act.map { reserve[$0]! }.reduce(0, +) / Double(act.count)
            guard mean >= p.minMeanReserve else { return }
            let end = Double((last + 1) * 60)
            guard now - end >= p.settleSec else { return }
            // Aanloop meetellen: terug naar het moment dat de hartslag begon te stijgen.
            var first = runStart
            while runStart - first < p.maxLeadMin, let r = reserve[first - 1], r >= p.rampReserve,
                  out.last.map({ Double((first - 1) * 60) >= $0.end }) ?? true { first -= 1 }
            out.append(DetectedActivity(start: Double(first * 60), end: end, meanReserve: mean))
        }
        for m in active.dropFirst() {
            // Een gat mag niet over een uitgesloten periode heen lopen.
            let gapBlocked = exclude.contains { Double((last + 1) * 60) < $0.end && Double(m * 60) > $0.start }
            if m - last - 1 > p.maxGapMin || gapBlocked { close(); runStart = m }
            last = m
        }
        close()
        return out
    }
}
