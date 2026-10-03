import CoreLocation
import MapKit

/// Turns a GPS position into a human place name, preferring the nearest
/// climbing gym ("Movement Gowanus") over a street address.
enum PlaceResolver {
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1)
            .distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }

    static func name(latitude: Double, longitude: Double) async -> String? {
        if let gym = await nearestGym(latitude: latitude, longitude: longitude) {
            return gym
        }
        // Fallback: neighbourhood or city.
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        return placemark.subLocality ?? placemark.locality ?? placemark.name
    }

    private static func nearestGym(latitude: Double, longitude: Double) async -> String? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: 250)

        var categories: [MKPointOfInterestCategory] = [.fitnessCenter]
        if #available(iOS 18.0, *) {
            categories.insert(.rockClimbing, at: 0)
        }
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)

        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }

        var best: (name: String, score: Double)?
        for item in response.mapItems {
            guard let name = item.name else { continue }
            let c = item.placemark.coordinate
            var score = distance(latitude, longitude, c.latitude, c.longitude)
            if isClimbing(item) { score -= 10_000 }      // a climbing gym always wins
            if best == nil || score < best!.score {
                best = (name, score)
            }
        }
        return best?.name
    }

    private static func isClimbing(_ item: MKMapItem) -> Bool {
        if #available(iOS 18.0, *) {
            if item.pointOfInterestCategory == .rockClimbing { return true }
        }
        let name = (item.name ?? "").lowercased()
        return name.contains("climb") || name.contains("boulder") || name.contains("bloc")
    }
}

/// One-shot "where am I" for photos taken inside the app. Imported photos
/// use their own GPS data instead. Permission is asked only the first time
/// the camera is used.
@MainActor
final class LocationGrabber: NSObject, CLLocationManagerDelegate {
    static let shared = LocationGrabber()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func currentLocation() async -> CLLocation? {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        if continuation != nil { return nil }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            continuation = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    private func authorizationChanged() {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated { self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.finish(nil) }
    }
}
