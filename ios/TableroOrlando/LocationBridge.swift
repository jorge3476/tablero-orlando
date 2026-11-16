import CoreLocation

/// GPS del iPad para el tablero (velocidad, posición y rumbo).
final class LocationBridge: NSObject, CLLocationManagerDelegate {

    var onFix: ((String) -> Void)?
    var onDenied: (() -> Void)?

    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onDenied?()
        default:
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard running else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            onDenied?()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        let fix: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lon": loc.coordinate.longitude,
            "acc": loc.horizontalAccuracy,
            "speed": loc.speed >= 0 ? loc.speed as Any : NSNull() as Any,
            "heading": loc.course >= 0 ? loc.course as Any : NSNull() as Any,
            "t": loc.timestamp.timeIntervalSince1970 * 1000
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fix),
           let json = String(data: data, encoding: .utf8) {
            onFix?(json)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Sin señal por un momento: se sigue intentando solo.
    }
}
