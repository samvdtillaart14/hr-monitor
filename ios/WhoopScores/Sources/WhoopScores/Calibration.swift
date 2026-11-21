import Foundation

/// Parameters van alle scores. Standaardwaarden tot er een kalibratie uit de Whoop-export is
/// (`node scores/calibrate.mjs <export-map> > whoop-calibration.json`). Zelfde JSON als de JS-versie.
public struct Calibration: Codable, Equatable, Sendable {
    public struct Profile: Codable, Equatable, Sendable {
        public var maxHr: Double = 190
        public var restingHr: Double = 55
        /// "hrr" (hartslagreserve, Whoop-standaard) of "max" (% van max HR)
        public var zoneMode: String = "hrr"
        /// voor calorieën
        public var weightKg: Double = 75, heightCm: Double = 180, age: Double = 30
        public var male: Bool = true
        public var kcalScale: Double = 1
    }
    public struct Strain: Codable, Equatable, Sendable {
        /// strain = min(21, a · ln(1 + T/b)), T = gewogen zoneminuten
        public var a: Double = 3.7
        public var b: Double = 8
        public var zoneWeights: [Double] = [0.7, 1, 3.8, 8.2, 14.3, 22]
        public var zone0Floor: Double = 0.3
    }
    public struct Baseline: Codable, Equatable, Sendable {
        public var lnHrvMean: Double = log(60), lnHrvSd: Double = 0.25
        public var rhrMean: Double = 55, rhrSd: Double = 3
        public var respMean: Double = 15, respSd: Double = 0.8
        public var tempMean: Double = 33.5, tempSd: Double = 0.3
        public init() {}
        public init(lnHrvMean: Double, lnHrvSd: Double, rhrMean: Double, rhrSd: Double, respMean: Double, respSd: Double, tempMean: Double, tempSd: Double) {
            self.lnHrvMean = lnHrvMean; self.lnHrvSd = lnHrvSd; self.rhrMean = rhrMean; self.rhrSd = rhrSd
            self.respMean = respMean; self.respSd = respSd; self.tempMean = tempMean; self.tempSd = tempSd
        }
    }
    public struct Recovery: Codable, Equatable, Sendable {
        public var windowDays: Int = 30
        public var intercept: Double = 0.4
        public var wHrv: Double = 1.0, wRhr: Double = -0.5, wResp: Double = -0.2, wSleep: Double = 1.5, wTemp: Double = 0
        /// HRV × slaapprestatie, en de slaapdelen apart (toereikendheid, efficiëntie, consistentie)
        public var wHrvSleep: Double = 0, wSuf: Double = 0, wEff: Double = 0, wCons: Double = 0
        public var sleepRef: Double = 0.85, sufRef: Double = 0.8, effRef: Double = 0.85, consRef: Double = 0.7
        public var baseline = Baseline()
        public var minHistory: Int = 4
    }
    public struct Sleep: Codable, Equatable, Sendable {
        public var needBaseMin: Double = 460, needPerDebtMin: Double = 0.3, needPerStrainMin: Double = 3, strainRef: Double = 10
        /// prestatie = c0 + c1·toereikendheid + c2·efficiëntie + c3·consistentie (alle in %)
        public var perfIntercept: Double = -72.7, perfSufficiency: Double = 0.771, perfEfficiency: Double = 0.754, perfConsistency: Double = 0.386
        public var deepFrac: Double = 0.20, remFrac: Double = 0.22
        /// 0 = automatisch per opname
        public var moveThreshold: Double = 0
        public var hrAboveRest: Double = 20, maxGapMin: Int = 15, minPeriodMin: Int = 30
        /// slaapschuld = min(cap, carry·schuld gisteren + fromDeficit·(behoefte − geslapen) gisteren)
        public var debtCarry: Double = 0.1, debtFromDeficit: Double = 0.55, debtCapMin: Double = 127
    }
    /// slaapstress 0–3: offset + (HR − basis-rust-HR)/hrScale − (ln RMSSD − basis-ln-HRV)/hrvScale
    public struct Stress: Codable, Equatable, Sendable {
        public var offset: Double = 1.0, hrScale: Double = 10, hrvScale: Double = 0.5
    }
    /// whoop ≈ a + b·eigen, als [a, b]
    public struct Corrections: Codable, Equatable, Sendable {
        public var hrv: [Double] = [0, 1], rhr: [Double] = [0, 1], resp: [Double] = [0, 1], skinTemp: [Double] = [0, 1]
    }

    public var version = 1
    public var profile = Profile()
    public var strain = Strain()
    public var recovery = Recovery()
    public var sleep = Sleep()
    public var corrections = Corrections()
    public var stress = Stress()

    public init() {}
    public static let standard = Calibration()

    /// Laadt een kalibratie; ontbrekende velden (oudere bestanden) krijgen de standaardwaarde.
    public static func load(from url: URL) throws -> Calibration {
        try decodeLenient(Data(contentsOf: url))
    }

    public static func decodeLenient(_ data: Data) throws -> Calibration {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Calibration.standard))
        let loaded = try JSONSerialization.jsonObject(with: data)
        func merge(_ a: Any, _ b: Any) -> Any {
            guard let da = a as? [String: Any], let db = b as? [String: Any] else { return b }
            var out = da
            for (k, v) in db { out[k] = da[k].map { merge($0, v) } ?? v }
            return out
        }
        return try JSONDecoder().decode(Calibration.self, from: JSONSerialization.data(withJSONObject: merge(base, loaded)))
    }
}
