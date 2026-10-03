import CoreLocation
import HeadwayCore
import QuartzCore

/// Moves bus markers smoothly between the positions the feed reports.
///
/// Each bus glides from where it is drawn now to its newly reported position over one update interval. The markers
/// therefore trail the real bus by up to one interval, but they never jump.
final class BusAnimator {
  private struct Track {
    var vehicle: VehicleSample
    var from: CLLocationCoordinate2D
    var to: CLLocationCoordinate2D
  }

  private var tracks: [String: Track] = [:]
  private var startTime: CFTimeInterval = 0
  private var duration: CFTimeInterval = 10

  /// A bus that moved farther than this between reports is shown at its new place at once (it is not a glide).
  private let snapDistance: CLLocationDistance = 800

  func update(vehicles: [VehicleSample], smooth: Bool, duration: Double, now: CFTimeInterval) {
    let displayed = Dictionary(uniqueKeysWithValues: positions(at: now).list.map { ($0.vehicle.id, $0.coordinate) })
    var next: [String: Track] = [:]
    for vehicle in vehicles {
      let target = CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude)
      var from = target
      if smooth, let shown = displayed[vehicle.id] {
        let distance = CLLocation(latitude: shown.latitude, longitude: shown.longitude)
          .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        if distance <= snapDistance { from = shown }
      }
      next[vehicle.id] = Track(vehicle: vehicle, from: from, to: target)
    }
    tracks = next
    startTime = now
    self.duration = max(1, smooth ? duration : 1)
  }

  /// Where each bus should be drawn at `now`, and whether every bus has arrived.
  func positions(at now: CFTimeInterval) -> (list: [(vehicle: VehicleSample, coordinate: CLLocationCoordinate2D)], finished: Bool) {
    let t = min(1, max(0, (now - startTime) / duration))
    let list = tracks.values.map { track -> (VehicleSample, CLLocationCoordinate2D) in
      (
        track.vehicle,
        CLLocationCoordinate2D(
          latitude: track.from.latitude + (track.to.latitude - track.from.latitude) * t,
          longitude: track.from.longitude + (track.to.longitude - track.from.longitude) * t)
      )
    }
    return (list, t >= 1)
  }
}
