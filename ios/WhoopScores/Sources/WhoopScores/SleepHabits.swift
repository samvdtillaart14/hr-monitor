import Foundation

/// Slaapgewoontes: slaapschuld over een week en tijd tot inslapen (telefoon weg → band ziet slaap).
public enum SleepHabits {

    /// Slaapschuld (min) over de laatste `days` nachten: opgeteld tekort t.o.v. de eigen slaapbehoefte.
    /// Een nacht met meer slaap dan nodig lost schuld af, maar de schuld wordt nooit negatief.
    public static func weekDebtMin(_ nights: [(asleepMin: Double, needMin: Double)], days: Int = 7) -> Double {
        var debt = 0.0
        for n in nights.suffix(days) where n.asleepMin.isFinite && n.needMin.isFinite && n.needMin > 0 {
            debt = max(0, debt + n.needMin - n.asleepMin)
        }
        return debt
    }

    /// Tijd tot inslapen (min): van het laatste moment dat het telefoonscherm uitging tot de band slaap ziet.
    /// `awake`: schermperiodes (zie `ScreenActivity.wakeIntervals`). Geen telefoongebruik in de `windowMin`
    /// minuten vóór het inslapen → nil (onbekend: je kunt ook zonder telefoon in bed hebben gelegen).
    public static func latencyMin(onset: Double, awake: [Range<Double>], windowMin: Double = 120) -> Int? {
        let lastOff = awake.filter { $0.lowerBound < onset && $0.upperBound > onset - windowMin * 60 }
            .map { min($0.upperBound, onset) }.max()
        guard let lastOff else { return nil }
        return Int(((onset - lastOff) / 60).rounded())
    }
}
