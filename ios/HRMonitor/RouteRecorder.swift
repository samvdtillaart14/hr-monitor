import Foundation
import CoreLocation

/// Eén GPS-punt van een route.
struct RoutePoint: Codable {
    var t: Double          // Unix-tijd
    var lat: Double, lon: Double
    var alt: Double
    var acc: Double        // horizontale nauwkeurigheid (m)
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
}

/// Afstand, tempo en km-splits van een route.
enum Route {
    static var folder: URL {
        let u = Recorder.folder.appendingPathComponent("routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    static func load(_ id: UUID) -> [RoutePoint] {
        (try? JSONDecoder().decode([RoutePoint].self, from: Data(contentsOf: url(id)))) ?? []
    }
    static func save(_ p: [RoutePoint], _ id: UUID) {
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: url(id), options: .atomic) }
    }
    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    static func distance(_ p: [RoutePoint]) -> Double {
        zip(p, p.dropFirst()).reduce(0) { $0 + $1.0.location.distance(from: $1.1.location) }
    }

    /// Tijd (s) per volle kilometer, plus de rest-afstand en -tijd.
    static func splits(_ p: [RoutePoint]) -> (km: [Double], restM: Double, restSec: Double) {
        guard let first = p.first else { return ([], 0, 0) }
        var out: [Double] = [], d = 0.0, kmStart = first.t, next = 1000.0
        for (a, b) in zip(p, p.dropFirst()) {
            let seg = a.location.distance(from: b.location)
            while d + seg >= next, seg > 0 {
                let f = (next - d) / seg
                let t = a.t + f * (b.t - a.t)
                out.append(t - kmStart); kmStart = t; next += 1000
            }
            d += seg
        }
        return (out, d - (next - 1000), (p.last?.t ?? kmStart) - kmStart)
    }
}

/// Neemt de GPS-route op tijdens een gestarte activiteit, ook met het scherm uit
/// (achtergrondlocatie; iOS toont dan de blauwe locatie-indicator).
@MainActor
final class RouteRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var activityId: UUID?
    @Published private(set) var points: [RoutePoint] = []
    @Published private(set) var distance = 0.0
    @Published private(set) var denied = false
    private let lm = CLLocationManager()
    private var unsaved = 0

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = 5
        lm.activityType = .fitness
        lm.pausesLocationUpdatesAutomatically = false
    }

    func start(_ id: UUID) {
        activityId = id
        points = Route.load(id)            // hervatten na herstart van de app
        distance = Route.distance(points)
        unsaved = 0
        switch lm.authorizationStatus {
        case .notDetermined: lm.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true; return
        default: break
        }
        begin()
    }

    private func begin() {
        guard activityId != nil else { return }
        let s = lm.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return }
        denied = false
        lm.allowsBackgroundLocationUpdates = true
        lm.showsBackgroundLocationIndicator = true
        lm.startUpdatingLocation()
    }

    /// Stopt en bewaart; geeft de afstand in meters.
    @discardableResult
    func stop() -> Double {
        lm.stopUpdatingLocation()
        lm.allowsBackgroundLocationUpdates = false
        if let id = activityId { Route.save(points, id) }
        let d = distance
        activityId = nil; points = []; distance = 0
        return d
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        MainActor.assumeIsolated {
            let s = m.authorizationStatus
            if s == .denied || s == .restricted { denied = activityId != nil } else { begin() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        MainActor.assumeIsolated { add(locs) }
    }

    private func add(_ locs: [CLLocation]) {
        guard let id = activityId else { return }
        for l in locs where l.horizontalAccuracy > 0 && l.horizontalAccuracy <= 25 && l.timestamp.timeIntervalSinceNow > -30 {
            let p = RoutePoint(t: l.timestamp.timeIntervalSince1970, lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                               alt: l.altitude, acc: l.horizontalAccuracy)
            if let last = points.last {
                let d = last.location.distance(from: p.location), dt = p.t - last.t
                // GPS-sprongen (> 15 m/s ≈ 54 km/h) en stilstand-ruis negeren
                guard dt > 0, d / dt < 15, d >= max(3, l.horizontalAccuracy / 3) else { continue }
                distance += d
            }
            points.append(p); unsaved += 1
        }
        if unsaved >= 20 { Route.save(points, id); unsaved = 0 }
    }
}
