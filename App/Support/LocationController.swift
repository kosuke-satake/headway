import CoreLocation
import Observation

/// When-in-use location. Permission is only requested when the user asks to see their position.
@MainActor @Observable
final class LocationController: NSObject, CLLocationManagerDelegate {
  private(set) var location: CLLocation?
  private(set) var status: CLAuthorizationStatus

  @ObservationIgnored private let manager = CLLocationManager()

  var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
  var isDenied: Bool { status == .denied || status == .restricted }

  override init() {
    status = manager.authorizationStatus
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    manager.distanceFilter = 20
    if isAuthorized { manager.startUpdatingLocation() }
  }

  /// Starts updates, asking for permission first if it was never asked.
  func start() {
    switch status {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
    default: break
    }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let newStatus = manager.authorizationStatus
    Task { @MainActor in
      self.status = newStatus
      if self.isAuthorized { manager.startUpdatingLocation() }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last else { return }
    Task { @MainActor in self.location = latest }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
