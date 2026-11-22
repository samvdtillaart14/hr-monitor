import Foundation

// Whoop-achtige scores uit ruwe banddata. Exacte port van scores/whoop-scores.js;
// beide worden getest tegen dezelfde fixture (scores/test/fixtures/night.json).

/// Eén seconde banddata (R18-record of live-pakket).
public struct Sample: Sendable {
    public var t: Double          // Unix-tijd in s
    public var hr: Double         // bpm, 0 = onbekend
    public var rr: [Double]       // RR-intervallen in ms
    public var q: [Double]?       // 4 oriëntatie-floats
    public var skinTemp: Double?  // °C
    public init(t: Double, hr: Double, rr: [Double] = [], q: [Double]? = nil, skinTemp: Double? = nil) {
        self.t = t; self.hr = hr; self.rr = rr; self.q = q; self.skinTemp = skinTemp
    }
}

public struct Beat: Sendable { public var t: Double; public var rr: Double; public var ok: Bool; public var segEnd: Bool }

public struct Epoch: Sendable { public var t: Double; public var hr: Double; public var hrSd: Double; public var move: Double; public var skinTemp: Double; public var n: Int }

public enum Stage: Int, Sendable { case wake = 0, light = 1, deep = 2, rem = 3 }

public struct StressMinutes: Codable, Sendable, Equatable { public var low = 0, medium = 0, high = 0 }

public struct NightResult: Sendable {
    public var onset: Double, wake: Double
    public var inBedMin: Int, asleepMin: Int, awakeMin: Int, lightMin: Int, deepMin: Int, remMin: Int
    public var efficiency: Double
    public var disturbances: Int
    public var hrv: Double, rhr: Double, resp: Double, skinTemp: Double
    /// slaapstress 0–3 per minuut in bed (NaN = geen data)
    public var stress: [Double]
    public var stressMin: StressMinutes
    public var highStressPct: Double
    public var stages: [Stage]
    public var naps: [(onset: Double, minutes: Int)]
}

public struct StrainResult: Sendable { public var strain: Double; public var load: Double; public var zoneMin: [Double] }

/// Nachtwaarden voor Recovery en de basislijn.
public struct NightMetrics: Codable, Sendable {
    public var hrv: Double?, rhr: Double?, resp: Double?, sleepPerf: Double?, skinTemp: Double?
    /// slaapdelen in %
    public var sufficiency: Double?, efficiency: Double?, consistency: Double?
    public init(hrv: Double? = nil, rhr: Double? = nil, resp: Double? = nil, sleepPerf: Double? = nil, skinTemp: Double? = nil,
                sufficiency: Double? = nil, efficiency: Double? = nil, consistency: Double? = nil) {
        self.hrv = hrv; self.rhr = rhr; self.resp = resp; self.sleepPerf = sleepPerf; self.skinTemp = skinTemp
        self.sufficiency = sufficiency; self.efficiency = efficiency; self.consistency = consistency
    }
}

public enum WhoopScores {

    // MARK: RR-intervallen

    /// Slagreeks met tijdstempels uit de cumulatieve RR-som; artefacten gemarkeerd.
    public static func beats(_ samples: [Sample]) -> [Beat] {
        var out: [Beat] = []
        var clock: Double? = nil
        for s in samples where !s.rr.isEmpty {
            if clock == nil || abs(clock! - (s.t + 1)) > 2 {
                clock = s.t
                if !out.isEmpty { out[out.count - 1].segEnd = true }
            }
            for rr in s.rr { clock! += rr / 1000; out.append(Beat(t: clock!, rr: rr, ok: true, segEnd: false)) }
        }
        let valid = out.map { $0.rr >= 300 && $0.rr <= 2000 }
        for i in out.indices {
            if !valid[i] { out[i].ok = false; continue }
            var win: [Double] = []
            for j in max(0, i - 5)...min(out.count - 1, i + 5) where valid[j] { win.append(out[j].rr) }
            let m = M.median(win)
            if abs(out[i].rr - m) / m > 0.2 { out[i].ok = false }
        }
        return out
    }

    /// RMSSD (ms) over opeenvolgende geldige slagen; NaN bij minder dan 10 verschillen.
    public static func rmssd(_ bs: [Beat]) -> Double {
        var s = 0.0, n = 0
        if bs.count > 1 {
            for i in 1..<bs.count where bs[i].ok && bs[i - 1].ok && !bs[i - 1].segEnd {
                let d = bs[i].rr - bs[i - 1].rr; s += d * d; n += 1
            }
        }
        return n >= 10 ? sqrt(s / Double(n)) : .nan
    }

    /// Ademfrequentie (/min) uit respiratoire sinusaritmie: piek in 0,15–0,5 Hz van het RR-tachogram.
    public static func respRateWindow(_ bs: [Beat]) -> Double {
        let good = bs.filter { $0.ok }
        guard good.count >= 40 else { return .nan }
        let t0 = good[0].t, T = good[good.count - 1].t - t0
        guard T >= 60 else { return .nan }
        let fs = 4.0, n = Int((T * fs).rounded(.down))
        var x = [Double](repeating: 0, count: n)
        var k = 0
        for i in 0..<n {
            let t = t0 + Double(i) / fs
            while k < good.count - 2 && good[k + 1].t < t { k += 1 }
            let a = good[k], b = good[k + 1]
            x[i] = a.rr + (b.rr - a.rr) * M.clamp((t - a.t) / (b.t - a.t), 0, 1)
        }
        let mi = Double(n - 1) / 2, mx = M.mean(x)
        var sxy = 0.0, sxx = 0.0
        for i in 0..<n { let di = Double(i) - mi; sxy += di * (x[i] - mx); sxx += di * di }
        let slope = sxy / sxx
        for i in 0..<n {
            x[i] = (x[i] - mx - slope * (Double(i) - mi)) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)))
        }
        var best = 0.0, bestF = Double.nan, total = 0.0
        var f = 0.15
        while f <= 0.5 + 1e-9 {
            var re = 0.0, im = 0.0
            for i in 0..<n { let w = 2 * Double.pi * f * Double(i) / fs; re += x[i] * cos(w); im -= x[i] * sin(w) }
            let p = re * re + im * im
            total += p
            if p > best { best = p; bestF = f }
            f += 0.005
        }
        return best / total > 0.03 ? bestF * 60 : .nan
    }

    // MARK: Epochs

    static func quatAngle(_ a: [Double], _ b: [Double]) -> Double {
        let na = sqrt(a.reduce(0) { $0 + $1 * $1 }), nb = sqrt(b.reduce(0) { $0 + $1 * $1 })
        guard na > 0, nb > 0 else { return 0 }
        let d = abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]) / (na * nb)
        return 2 * acos(min(1, d)) + abs(nb - 1)
    }

    public static func epochs(_ samples: [Sample], epochSec: Double = 60) -> [Epoch] {
        guard let first = samples.first else { return [] }
        let t0 = first.t
        var hrs: [[Double]] = [], temps: [[Double]] = [], moves: [Double] = [], ns: [Int] = []
        var prevQ: [Double]? = nil
        for s in samples {
            let i = Int(((s.t - t0) / epochSec).rounded(.down))
            while hrs.count <= i { hrs.append([]); temps.append([]); moves.append(0); ns.append(0) }
            ns[i] += 1
            if s.hr > 0 { hrs[i].append(s.hr) }
            if let st = s.skinTemp, st.isFinite { temps[i].append(st) }
            if let q = s.q, q.count == 4 { if let p = prevQ { moves[i] += quatAngle(p, q) }; prevQ = q }
        }
        return hrs.indices.map { i in
            Epoch(t: t0 + Double(i) * epochSec, hr: hrs[i].isEmpty ? .nan : M.mean(hrs[i]), hrSd: M.sd(hrs[i]),
                  move: moves[i], skinTemp: temps[i].isEmpty ? .nan : M.mean(temps[i]), n: ns[i])
        }
    }

    // MARK: Slaap

    public struct SleepDetection: Sendable {
        public var periods: [Range<Int>]
        public var moveThr: Double
        public var candidate: [Bool]
    }

    /// Slaapperiodes: weinig beweging én hartslag dicht bij rust.
    public static func detectSleep(_ eps: [Epoch], _ cal: Calibration = .standard) -> SleepDetection {
        let c = cal.sleep
        let moveS = M.movingMedian(eps.map { $0.move }, 7)   // mediaan: een omdraaimoment maakt je niet wakker
        let moveThr = c.moveThreshold > 0 ? c.moveThreshold
            : max(1e-3, 3 * M.percentile(moveS.indices.filter { eps[$0].n > 0 }.map { moveS[$0] }, 0.1))   // gaten tellen niet mee
        // rustreferentie: gekalibreerde rust-HR, of hoger als de nacht zelf hoger ligt (alcohol, ziekte, warmte)
        let p5 = M.percentile(eps.map { $0.hr }, 0.05)
        let rhr = max(cal.profile.restingHr, p5.isFinite ? p5 : 0)
        let cand = eps.indices.map { i in
            moveS[i] < moveThr && (!eps[i].hr.isFinite || eps[i].hr < rhr + c.hrAboveRest) && eps[i].n > 0
        }
        var runs: [Range<Int>] = []
        var i = 0
        while i < cand.count {
            if !cand[i] { i += 1; continue }
            var j = i; while j < cand.count && cand[j] { j += 1 }
            if let last = runs.last, i - last.upperBound <= c.maxGapMin { runs[runs.count - 1] = last.lowerBound..<j }
            else { runs.append(i..<j) }
            i = j + 1
        }
        // los staartje aan het eind van een blok (na >= 5 min wakker) weghalen
        for r in runs.indices {
            let lo = runs[r].lowerBound
            var end = runs[r].upperBound
            while true {
                var e = end; while e > lo && !cand[e - 1] { e -= 1 }
                var s = e; while s > lo && cand[s - 1] { s -= 1 }
                var g = s; while g > lo && !cand[g - 1] { g -= 1 }
                if g > lo && e - s < c.edgeRunMin && s - g >= 5 { end = g } else { end = e; break }
            }
            runs[r] = lo..<end
        }
        return SleepDetection(periods: runs.filter { $0.count >= c.minPeriodMin }, moveThr: moveThr, candidate: cand)
    }

    static func localHour(_ t: Double, _ tzOffsetMin: Double) -> Double {
        let m = (t / 60 + tzOffsetMin).truncatingRemainder(dividingBy: 1440)
        return (m < 0 ? m + 1440 : m) / 60
    }

    /// Hoofdslaap: het langste blok; ligt dat in de nacht, dan horen alle nachtblokken binnen
    /// nightMergeGapMin erbij (de tussentijd telt als wakker). De rest zijn dutjes.
    public static func mainSleep(_ eps: [Epoch], periods: [Range<Int>], _ cal: Calibration = .standard,
                                 tzOffsetMin: Double = Double(TimeZone.current.secondsFromGMT()) / 60) -> (main: Range<Int>, naps: [Range<Int>])? {
        let c = cal.sleep
        guard var longest = periods.first else { return nil }
        for p in periods where p.count > longest.count { longest = p }
        func inNight(_ t: Double) -> Bool {
            let h = localHour(t, tzOffsetMin)
            return c.nightStartHour > c.nightEndHour ? (h >= c.nightStartHour || h < c.nightEndHour) : (h >= c.nightStartHour && h < c.nightEndHour)
        }
        func night(_ p: Range<Int>) -> Bool {
            for i in stride(from: p.lowerBound, to: p.upperBound, by: 5) where inNight(eps[i].t) { return true }
            return inNight(eps[p.upperBound - 1].t)
        }
        var main = longest
        var parts = [longest]
        if night(longest) {
            var grew = true
            while grew {
                grew = false
                for p in periods where !parts.contains(p) {
                    let g = night(p) ? c.nightMergeGapMin : c.nightExtendGapMin   // aansluitend blok buiten de nacht: alleen bij korte onderbreking
                    if p.upperBound <= main.lowerBound && main.lowerBound - p.upperBound <= g {
                        main = p.lowerBound..<main.upperBound; parts.append(p); grew = true
                    } else if p.lowerBound >= main.upperBound && p.lowerBound - main.upperBound <= g {
                        main = main.lowerBound..<p.upperBound; parts.append(p); grew = true
                    }
                }
            }
        }
        return (main, periods.filter { !parts.contains($0) })
    }

    /// Fase per epoch. Diep/REM via rangorde, zodat de verdeling de gekalibreerde fracties volgt.
    public static func stageSleep(_ eps: [Epoch], period: Range<Int>, candidate: [Bool], moveThr: Double,
                                  _ cal: Calibration = .standard, rmssdPerEpoch: [Double]? = nil) -> [Stage] {
        let c = cal.sleep
        let idx = Array(period), N = idx.count
        var stages: [Stage] = idx.map { !candidate[$0] || (c.wakeMoveFactor > 0 && eps[$0].move > c.wakeMoveFactor * moveThr) ? .wake : .light }
        let sl = (0..<N).filter { stages[$0] != .wake }
        guard !sl.isEmpty else { return stages }
        let zHr = M.zscores(sl.map { eps[idx[$0]].hr })
        let zSd = M.zscores(sl.map { eps[idx[$0]].hrSd })
        let zRm = M.zscores(sl.map { rmssdPerEpoch?[idx[$0]] ?? .nan })
        let pos = sl.map { Double($0) / Double(max(1, N - 1)) }
        var deep = sl.indices.map { j in -zHr[j] - zSd[j] + 0.5 * zRm[j] + 0.8 * (1 - pos[j]) }
        var rem = sl.indices.map { j in zSd[j] + 0.5 * zHr[j] - 0.3 * zRm[j] + 0.8 * pos[j] - (sl[j] < 45 ? 3 : 0) }
        deep = M.movingAvg(deep, 5); rem = M.movingAvg(rem, 5)
        let nDeep = Int((c.deepFrac * Double(sl.count)).rounded()), nRem = Int((c.remFrac * Double(sl.count)).rounded())
        func order(_ sc: [Double]) -> [Int] { sc.indices.sorted { sc[$0] != sc[$1] ? sc[$0] > sc[$1] : $0 < $1 } }
        var taken = [Bool](repeating: false, count: sl.count)
        for j in order(deep).prefix(nDeep) { stages[sl[j]] = .deep; taken[j] = true }
        var r = 0
        for j in order(rem) { if r >= nRem { break }; if taken[j] { continue }; stages[sl[j]] = .rem; r += 1 }
        return stages
    }

    /// Volledige nachtanalyse: slaap, fases, HRV, rust-HR, ademfrequentie, huidtemperatuur.
    public static func analyzeNight(_ samples: [Sample], _ cal: Calibration = .standard, baseline: Calibration.Baseline? = nil,
                                    tzOffsetMin: Double = Double(TimeZone.current.secondsFromGMT()) / 60) -> NightResult? {
        let baseline = baseline ?? cal.recovery.baseline
        let eps = epochs(samples)
        let det = detectSleep(eps, cal)
        guard let ms = mainSleep(eps, periods: det.periods, cal, tzOffsetMin: tzOffsetMin) else { return nil }
        let main = ms.main
        let bs = beats(samples)
        let t0 = eps[0].t
        var epochBeats = [[Beat]](repeating: [], count: eps.count)
        for b in bs { let i = Int(((b.t - t0) / 60).rounded(.down)); if i >= 0 && i < eps.count { epochBeats[i].append(b) } }
        let rmEp = epochBeats.map(rmssd)
        let stages = stageSleep(eps, period: main, candidate: det.candidate, moveThr: det.moveThr, cal, rmssdPerEpoch: rmEp)
        let at = { (k: Int) in main.lowerBound + k }

        struct Win { var k: Int; var rmssd: Double; var hr: Double; var deep: Bool }
        var wins: [Win] = []
        var k = 0
        while k + 5 <= stages.count {
            defer { k += 5 }
            let st = stages[k..<(k + 5)]
            if st.contains(.wake) { continue }
            let wb = Array(epochBeats[at(k)..<at(k + 5)].joined())
            let v = rmssd(wb)
            if !v.isFinite { continue }
            let hr = M.mean(eps[at(k)..<at(k + 5)].map { $0.hr }.filter { $0.isFinite })
            wins.append(Win(k: k, rmssd: v, hr: hr, deep: st.filter { $0 == .deep }.count >= 3))
        }
        var chosen = cal.sleep.hrvFrom == "lastDeep" ? wins.filter { $0.deep } : []
        if !chosen.isEmpty {
            var lastBlock = [chosen[chosen.count - 1]]
            var i = chosen.count - 2
            while i >= 0 && chosen[i].k == lastBlock[0].k - 5 { lastBlock.insert(chosen[i], at: 0); i -= 1 }
            if lastBlock.count >= 2 { chosen = lastBlock }
        } else { chosen = wins }
        let hrv = chosen.isEmpty ? .nan : M.mean(chosen.map { $0.rmssd })
        let rhr = chosen.isEmpty ? .nan : M.mean(chosen.map { $0.hr })

        var rates: [Double] = []
        if stages.count >= 2 {
            for k in 0...(stages.count - 2) where stages[k] != .wake && stages[k + 1] != .wake {
                let r = respRateWindow(Array(epochBeats[at(k)..<at(k + 2)].joined()))
                if r.isFinite { rates.append(r) }
            }
        }
        let resp = rates.isEmpty ? .nan : M.median(rates)
        let temps = stages.indices.compactMap { k -> Double? in stages[k] != .wake && eps[at(k)].skinTemp.isFinite ? eps[at(k)].skinTemp : nil }
        var cnt = [0, 0, 0, 0]; for s in stages { cnt[s.rawValue] += 1 }
        var disturbances = 0
        for k in stages.indices.dropFirst() where stages[k] == .wake && stages[k - 1] != .wake { disturbances += 1 }
        let asleep = cnt[1] + cnt[2] + cnt[3]
        let st = cal.stress
        let stress: [Double] = stages.indices.map { k in
            let lo = max(0, k - 2), hi = min(stages.count, k + 3)
            let hr = M.mean(eps[at(lo)..<at(hi)].map { $0.hr }.filter { $0.isFinite })
            guard hr.isFinite else { return .nan }
            let rm = rmssd(Array(epochBeats[at(lo)..<at(hi)].joined()))
            let v = st.offset + (hr - baseline.rhrMean) / st.hrScale - (rm > 0 ? (log(rm) - baseline.lnHrvMean) / st.hrvScale : 0)
            return M.clamp(v, 0, 3)
        }
        var sm = StressMinutes()
        for v in stress where v.isFinite { if v >= 2 { sm.high += 1 } else if v >= 1 { sm.medium += 1 } else { sm.low += 1 } }
        let stTotal = sm.low + sm.medium + sm.high
        let cr = cal.corrections
        return NightResult(
            onset: eps[main.lowerBound].t, wake: eps[main.upperBound - 1].t + 60,
            inBedMin: stages.count, asleepMin: asleep, awakeMin: cnt[0], lightMin: cnt[1], deepMin: cnt[2], remMin: cnt[3],
            efficiency: 100 * Double(asleep) / Double(stages.count), disturbances: disturbances,
            hrv: M.correct(hrv, cr.hrv), rhr: M.correct(rhr, cr.rhr), resp: M.correct(resp, cr.resp),
            skinTemp: M.correct(temps.isEmpty ? .nan : M.mean(temps), cr.skinTemp),
            stress: stress, stressMin: sm, highStressPct: stTotal > 0 ? 100 * Double(sm.high) / Double(stTotal) : .nan,
            stages: stages,
            naps: ms.naps.map { (onset: eps[$0.lowerBound].t, minutes: $0.count) })
    }

    // MARK: Slaapbehoefte en -prestatie

    public struct NeedParts: Sendable, Equatable { public var healthy, strain, debt, naps, total: Double }

    /// Opbouw van de slaapbehoefte zoals de Whoop-app hem toont (minuten).
    public static func sleepNeedParts(debtMin: Double = 0, prevDayStrain: Double = 0, napMin: Double = 0, _ cal: Calibration = .standard) -> NeedParts {
        let c = cal.sleep
        let h = c.needBaseMin, s = c.needPerStrainMin * max(0, prevDayStrain - c.strainRef), d = c.needPerDebtMin * debtMin, n = -napMin
        return NeedParts(healthy: h, strain: s, debt: d, naps: n, total: max(0, h + s + d + n))
    }

    /// Slaapschuld (min) voor vannacht, uit de schuld en het tekort van de vorige nacht.
    public static func sleepDebt(prevDebtMin: Double = 0, prevNeedMin: Double = .nan, prevAsleepMin: Double = .nan, _ cal: Calibration = .standard) -> Double {
        let c = cal.sleep
        let deficit = prevNeedMin.isFinite && prevAsleepMin.isFinite ? prevNeedMin - prevAsleepMin : 0
        return M.clamp(c.debtCarry * prevDebtMin + c.debtFromDeficit * deficit, 0, c.debtCapMin)
    }

    public static func sleepNeedMin(debtMin: Double = 0, prevDayStrain: Double = 0, napMin: Double = 0, _ cal: Calibration = .standard) -> Double {
        let c = cal.sleep
        return max(0, c.needBaseMin + c.needPerDebtMin * debtMin + c.needPerStrainMin * max(0, prevDayStrain - c.strainRef) - napMin)
    }

    /// Toereikendheid: geslapen / behoefte, max 100 %.
    public static func sleepSufficiency(asleepMin: Double, needMin: Double) -> Double {
        needMin > 0 ? min(100, 100 * asleepMin / needMin) : .nan
    }

    /// Slaapprestatie zoals Whoop (sinds 2023): toereikendheid, efficiëntie en consistentie samen.
    public static func sleepPerformance(asleepMin: Double, needMin: Double, efficiency: Double? = nil, consistency: Double? = nil,
                                        _ cal: Calibration = .standard) -> Double {
        let c = cal.sleep, suf = sleepSufficiency(asleepMin: asleepMin, needMin: needMin)
        guard suf.isFinite else { return .nan }
        let eff = efficiency.flatMap { $0.isFinite ? $0 : nil } ?? 85, con = consistency.flatMap { $0.isFinite ? $0 : nil } ?? 70
        return M.clamp(c.perfIntercept + c.perfSufficiency * suf + c.perfEfficiency * eff + c.perfConsistency * con, 0, 100)
    }

    /// Consistentie (%): gemiddelde overlap (doorsnede/vereniging op de 24-uursklok) van de laatste slaap met de 3 nachten ervoor.
    /// `nights`: (onset, wake) in Unix-s, oudste eerst, laatste = vannacht.
    public static func sleepConsistency(_ nights: [(onset: Double, wake: Double)], tzOffsetMin: Double = 0) -> Double {
        guard nights.count >= 2 else { return .nan }
        func mask(_ n: (onset: Double, wake: Double)) -> [Bool] {
            var m = [Bool](repeating: false, count: 1440)
            let a = Int(((n.onset / 60 + tzOffsetMin).truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440))
            let d = min(1440, Int(((n.wake - n.onset) / 60).rounded(.down)))
            if d > 0 { for i in 0..<d { m[(a + i) % 1440] = true } }
            return m
        }
        let last = mask(nights[nights.count - 1])
        let prev = nights.dropLast().suffix(3).map(mask)
        return M.mean(prev.map { m in
            var and = 0, or = 0
            for i in 0..<1440 { if m[i] && last[i] { and += 1 }; if m[i] || last[i] { or += 1 } }
            return or > 0 ? 100 * Double(and) / Double(or) : 0
        })
    }

    // MARK: Strain

    static func reserveFraction(_ hr: Double, _ p: Calibration.Profile) -> Double {
        p.zoneMode == "max" ? hr / p.maxHr : (hr - p.restingHr) / (p.maxHr - p.restingHr)
    }

    public static func hrZone(_ hr: Double, _ p: Calibration.Profile) -> Int {
        let x = reserveFraction(hr, p)
        if x < 0.5 { return 0 }
        return min(5, 1 + Int(((x - 0.5) * 10 + 1e-9).rounded(.down)))
    }

    public static func strainFromLoad(_ T: Double, _ cal: Calibration = .standard) -> Double {
        T > 0 ? min(21, cal.strain.a * log(1 + T / cal.strain.b)) : 0
    }

    public static func loadFromZoneMinutes(_ zoneMin: [Double], _ cal: Calibration = .standard) -> Double {
        zip(zoneMin, cal.strain.zoneWeights).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Strain over een reeks samples (workout of hele cyclus).
    public static func strain(_ samples: [Sample], _ cal: Calibration = .standard) -> StrainResult {
        let p = cal.profile
        var zoneMin = [Double](repeating: 0, count: 6)
        for i in samples.indices {
            let s = samples[i]
            guard s.hr > 0 else { continue }
            let dt = i + 1 < samples.count ? min(5, samples[i + 1].t - s.t) : 1
            let z = hrZone(s.hr, p)
            if z == 0 && reserveFraction(s.hr, p) < cal.strain.zone0Floor { continue }
            zoneMin[z] += dt / 60
        }
        let load = loadFromZoneMinutes(zoneMin, cal)
        return StrainResult(strain: strainFromLoad(load, cal), load: load, zoneMin: zoneMin)
    }

    // MARK: Calorieën

    /// Energieverbruik (kcal): rustmetabolisme (Mifflin-St Jeor) plus activiteit (Keytel, boven rust-HR + 20).
    /// Rustverbruik (kcal/min) volgens Mifflin-St Jeor, zonder kcalScale.
    public static func restingKcalPerMin(_ cal: Calibration = .standard) -> Double {
        let p = cal.profile
        return (10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age + (p.male ? 5 : -161)) / 1440
    }

    /// Seconden die de samples dekken (zelfde tijdstappen als `calories` en `strain`: gat hooguit 5 s).
    public static func measuredSeconds(_ samples: [Sample]) -> Double {
        var t = 0.0
        for i in samples.indices { t += i + 1 < samples.count ? max(0, min(5, samples[i + 1].t - samples[i].t)) : 1 }
        return t
    }

    public static func calories(_ samples: [Sample], _ cal: Calibration = .standard) -> Double {
        let p = cal.profile
        let bmrPerMin = restingKcalPerMin(cal)
        var kcal = 0.0
        for i in samples.indices {
            let s = samples[i]
            let dt = (i + 1 < samples.count ? min(5, samples[i + 1].t - s.t) : 1) / 60
            var perMin = bmrPerMin
            if s.hr > p.restingHr + 20 {
                let k = p.male ? (-55.0969 + 0.6309 * s.hr + 0.1988 * p.weightKg + 0.2017 * p.age) / 4.184
                               : (-20.4022 + 0.4472 * s.hr - 0.1263 * p.weightKg + 0.074 * p.age) / 4.184
                perMin = max(bmrPerMin, k)
            }
            kcal += perMin * dt
        }
        return kcal * p.kcalScale
    }

    // MARK: Recovery

    static let floors = (lnHrvSd: 0.05, rhrSd: 1.0, respSd: 0.3, tempSd: 0.1)

    /// Basislijn uit eerdere nachten (laatste `windowDays`); valt terug op de gekalibreerde basislijn.
    /// Basislijn uit de laatste `windowDays` nachten. Met minder dan `minHistory` nachten: de gekalibreerde
    /// basislijn als die persoonlijk is, anders het gemiddelde van je eigen nachten tot nu toe (inclusief `night`)
    /// met de standaardspreiding. Een populatiebasislijn (HRV 60 ms) gaf bij HRV ~30 ms een herstel van 1–2 %.
    public static func baseline(from history: [NightMetrics], _ cal: Calibration = .standard, night: NightMetrics? = nil) -> Calibration.Baseline {
        let r = cal.recovery
        let h = history.suffix(r.windowDays)
        func col(_ f: (NightMetrics) -> Double?) -> [Double] { h.compactMap(f).filter { $0.isFinite } }
        let lh = col { n in n.hrv.flatMap { $0 > 0 ? log($0) : nil } }
        if lh.count < r.minHistory {
            guard !r.baselinePersonal, let night else { return r.baseline }
            let own = Array(h) + [night]
            func m(_ f: (NightMetrics) -> Double?, _ fb: Double) -> Double {
                let v = own.compactMap(f).filter { $0.isFinite }
                return v.isEmpty ? fb : M.mean(v)
            }
            var b = r.baseline
            b.lnHrvMean = m({ n in n.hrv.flatMap { $0 > 0 ? log($0) : nil } }, b.lnHrvMean)
            b.rhrMean = m({ $0.rhr }, b.rhrMean); b.respMean = m({ $0.resp }, b.respMean); b.tempMean = m({ $0.skinTemp }, b.tempMean)
            return b
        }
        func pick(_ v: [Double], _ m: Double, _ s: Double) -> (Double, Double) { v.count >= r.minHistory ? (M.mean(v), M.sd(v)) : (m, s) }
        let b = r.baseline
        let hv = pick(lh, b.lnHrvMean, b.lnHrvSd), rh = pick(col { $0.rhr }, b.rhrMean, b.rhrSd)
        let rs = pick(col { $0.resp }, b.respMean, b.respSd), tp = pick(col { $0.skinTemp }, b.tempMean, b.tempSd)
        return .init(lnHrvMean: hv.0, lnHrvSd: hv.1, rhrMean: rh.0, rhrSd: rh.1, respMean: rs.0, respSd: rs.1, tempMean: tp.0, tempSd: tp.1)
    }

    /// Recovery 1–99 %.
    public static func recovery(_ night: NightMetrics, history: [NightMetrics] = [], _ cal: Calibration = .standard) -> Int {
        let r = cal.recovery, b = baseline(from: history, cal, night: night)
        func z(_ v: Double?, _ m: Double, _ s: Double, _ fl: Double) -> Double {
            guard let v, v.isFinite else { return 0 }
            return (v - m) / max(s, fl)
        }
        let zH = (night.hrv ?? 0) > 0 ? z(log(night.hrv!), b.lnHrvMean, b.lnHrvSd, floors.lnHrvSd) : 0
        let zR = z(night.rhr, b.rhrMean, b.rhrSd, floors.rhrSd)
        let zP = z(night.resp, b.respMean, b.respSd, floors.respSd)
        let zT = z(night.skinTemp, b.tempMean, b.tempSd, floors.tempSd)
        func frac(_ v: Double?, _ ref: Double) -> Double { v.flatMap { $0.isFinite ? $0 / 100 : nil } ?? ref }
        let sp = frac(night.sleepPerf, r.sleepRef)
        let x = r.intercept + r.wHrv * zH + r.wRhr * zR + r.wResp * zP + r.wSleep * (sp - r.sleepRef) + r.wTemp * zT
            + r.wHrvSleep * zH * sp
            + r.wSuf * (frac(night.sufficiency, r.sufRef) - r.sufRef)
            + r.wEff * (frac(night.efficiency, r.effRef) - r.effRef)
            + r.wCons * (frac(night.consistency, r.consRef) - r.consRef)
        return Int(M.clamp((100 * M.sigmoid(x)).rounded(), 1, 99))
    }

    // MARK: SpO₂ (voorlopig)

    /// Ratio-of-ratios; pas bruikbaar als de ruwe optische (rood/IR) data gedecodeerd is.
    public static func spo2(ratio R: Double, a: Double = 110, b: Double = 25) -> Double { M.clamp(a - b * R, 70, 100) }
}
