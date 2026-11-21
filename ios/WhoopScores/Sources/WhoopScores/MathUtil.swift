import Foundation

// Identiek aan de hulpfuncties in scores/whoop-scores.js.
enum M {
    static func mean(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.reduce(0, +) / Double(a.count) }
    static func sd(_ a: [Double]) -> Double {
        guard a.count >= 2 else { return 0 }
        let m = mean(a)
        return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count - 1))
    }
    static func percentile(_ arr: [Double], _ p: Double) -> Double {
        let a = arr.filter { $0.isFinite }.sorted()
        guard !a.isEmpty else { return .nan }
        let i = Double(a.count - 1) * p, lo = Int(i.rounded(.down)), hi = Int(i.rounded(.up))
        return a[lo] + (a[hi] - a[lo]) * (i - Double(lo))
    }
    static func median(_ a: [Double]) -> Double { percentile(a, 0.5) }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
    static func zscores(_ a: [Double]) -> [Double] {
        let v = a.filter { $0.isFinite }
        let m = mean(v); var s = sd(v); if s == 0 { s = 1 }
        return a.map { $0.isFinite ? ($0 - m) / s : 0 }
    }
    static func movingAvg(_ a: [Double], _ w: Int) -> [Double] {
        let h = w / 2
        return a.indices.map { i in
            var s = 0.0, n = 0.0
            for j in (i - h)...(i + h) where j >= 0 && j < a.count { s += a[j]; n += 1 }
            return s / n
        }
    }
    static func correct(_ v: Double, _ c: [Double]) -> Double { v.isFinite && c.count == 2 ? c[0] + c[1] * v : v }
}
