import XCTest
import WhoopScores
@testable import AppCore

/// PROF-01…04 uit docs/TESTPLAN.md: profiel en kalibratie zoals de scores ze krijgen.
final class UserProfileTests: XCTestCase {
    private let keys = [UserProfile.maxHrKey, UserProfile.restHrAutoKey, UserProfile.weightKey, UserProfile.heightKey,
                        "profile.birth", "profile.male"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        _ = TS.documents
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) }
        UserProfile.removeCalibration()
    }
    override func tearDown() {
        for k in keys { if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        UserProfile.removeCalibration()
    }

    func testPROF01_restHrIsMedianOfPlausibleNights() {
        UserProfile.updateRestHr(from: [60, 62, 200, .nan, 58, 10])
        XCTAssertEqual(UserProfile.measuredRestHr, 60)
        UserProfile.updateRestHr(from: [])          // niets nieuws: oude waarde blijft
        XCTAssertEqual(UserProfile.measuredRestHr, 60)
    }

    func testPROF02_calibrationUsesProfileWithSaneBounds() {
        let d = UserDefaults.standard
        d.set(88.0, forKey: UserProfile.weightKey); d.set(194.0, forKey: UserProfile.heightKey)
        d.set(Date(timeIntervalSince1970: 986_515_200).timeIntervalSince1970, forKey: "profile.birth")  // 06-04-2001
        d.set(true, forKey: "profile.male")
        d.set(185.0, forKey: UserProfile.maxHrKey)
        d.set(178.0, forKey: UserProfile.restHrAutoKey)                     // onzin-rust-HR
        let c = UserProfile.calibration()
        XCTAssertEqual(c.profile.weightKg, 88); XCTAssertEqual(c.profile.heightCm, 194)
        XCTAssertEqual(c.profile.maxHr, 185)
        XCTAssertLessThanOrEqual(c.profile.restingHr, 165, "rust-HR altijd ≥ 20 onder max-HR (anders delen door ~0 in de zones)")
        XCTAssertGreaterThan(c.profile.age, 24)
    }

    func testPROF03_outOfRangeWeightIgnored() {
        UserDefaults.standard.set(5.0, forKey: UserProfile.weightKey)
        XCTAssertEqual(UserProfile.calibration().profile.weightKg, Calibration.standard.profile.weightKg)
    }

    func testPROF04_importCalibration() throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
        try Data("geen json".utf8).write(to: bad)
        XCTAssertThrowsError(try UserProfile.importCalibration(from: bad))
        XCTAssertNil(UserProfile.importedCalibration)
        let good = FileManager.default.temporaryDirectory.appendingPathComponent("good-\(UUID()).json")
        try Data(#"{"recovery":{"intercept":0.7}}"#.utf8).write(to: good)
        try UserProfile.importCalibration(from: good)
        XCTAssertEqual(UserProfile.importedCalibration?.recovery.intercept, 0.7)
        XCTAssertEqual(UserProfile.importedCalibration?.strain, Calibration.standard.strain, "ontbrekende delen krijgen de standaard")
    }
}
