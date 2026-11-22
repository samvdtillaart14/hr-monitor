import Foundation

/// Eén periode dat het iPhone-scherm aan stond (Unix-seconden). `unlocked`: de telefoon is in die periode
/// ontgrendeld (Face ID/code), dus iemand had hem echt in handen.
public struct ScreenSpan: Codable, Sendable, Equatable {
    public var start: Double, end: Double, unlocked: Bool
    public init(start: Double, end: Double, unlocked: Bool) { self.start = start; self.end = end; self.unlocked = unlocked }
    public var seconds: Double { max(0, end - start) }
}

/// Telefoongebruik als wakker-signaal en het moment van de ochtendmelding.
public enum ScreenActivity {

    /// Periodes die als wakker tellen: ontgrendeld, of het scherm minstens `minOnSec` aan.
    /// Een kort oplichtend scherm (binnenkomende melding) zonder ontgrendelen telt niet.
    public static func wakeIntervals(_ spans: [ScreenSpan], minOnSec: Double = 30) -> [Range<Double>] {
        let keep = spans.filter { $0.end > $0.start && ($0.unlocked || $0.seconds >= minOnSec) }
            .sorted { $0.start < $1.start }
        var out: [Range<Double>] = []
        for s in keep {
            if let last = out.last, s.start <= last.upperBound { out[out.count - 1] = last.lowerBound..<max(last.upperBound, s.end) }
            else { out.append(s.start..<s.end) }
        }
        return out
    }

    /// Lokale dagindex (dagen sinds 1970 in lokale tijd).
    public static func localDay(_ t: Double, tzOffsetMin: Double) -> Int {
        Int(((t / 60 + tzOffsetMin) / 1440).rounded(.down))
    }

    /// Ochtendmelding nu sturen? Alleen tussen startHour en endHour lokale tijd en hooguit één keer per dag.
    public static func morningBriefDue(now: Double, tzOffsetMin: Double, lastBriefDay: Int?,
                                       startHour: Double = 5, endHour: Double = 12) -> Bool {
        let h = WhoopScores.localHour(now, tzOffsetMin)
        guard h >= startHour && h < endHour else { return false }
        return lastBriefDay != localDay(now, tzOffsetMin: tzOffsetMin)
    }

    /// Per epoch (60 s vanaf eps[i].t): valt er een wakker-periode in?
    static func awakeMask(_ eps: [Epoch], _ awake: [Range<Double>], epochSec: Double = 60) -> [Bool] {
        guard !awake.isEmpty else { return [Bool](repeating: false, count: eps.count) }
        return eps.map { e in awake.contains { $0.lowerBound < e.t + epochSec && $0.upperBound > e.t } }
    }
}
