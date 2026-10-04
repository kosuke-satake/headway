import CoreLocation
import HeadwayCore
import QuartzCore

/// One bus as drawn on the map.
struct DrawnBus {
  let vehicle: VehicleSample
  let coordinate: CLLocationCoordinate2D
  /// Seconds since the bus made the report this position comes from.
  let age: TimeInterval
}

/// Moves bus markers smoothly and, when asked, estimates where each bus is *now*.
///
/// The city's feed is not instant: a bus reports every 30 seconds and the feed is rebuilt every 30 seconds, so a
/// position is about 25 seconds old on arrival. Between reports the marker is moved along the bus's route at its
/// reported speed (dead reckoning). When the next report arrives the marker eases to the new estimate instead of
/// jumping. Buses that are standing still, off their route, or have no speed stay where they reported.
final class BusAnimator {
  private struct Track {
    var vehicle: VehicleSample
    var reportAge: TimeInterval  // age of the report when it was received
    var received: CFTimeInterval  // media time at which it was received
    var path: [Coordinate]?  // route ahead of the report, long enough for `maxExtrapolation` seconds
    var speed: Double
    var shownFrom: CLLocationCoordinate2D?  // where the marker was drawn when this report arrived
  }

  /// Longest time a bus is moved forward without news. After that the marker waits for the next report.
  static let maxExtrapolation: TimeInterval = 50
  private static let blendDuration: CFTimeInterval = 2
  /// A marker that would have to move farther than this to reach the new estimate jumps instead of gliding.
  private let snapDistance: CLLocationDistance = 800

  private var tracks: [String: Track] = [:]

  func update(vehicles: [VehicleSample], schedule: Schedule?, estimate: Bool, smooth: Bool, now: CFTimeInterval, wall: Date) {
    let shown = Dictionary(uniqueKeysWithValues: positions(at: now).list.map { ($0.vehicle.id, $0.coordinate) })
    var next: [String: Track] = [:]
    for vehicle in vehicles {
      if let existing = tracks[vehicle.id], existing.vehicle.timestamp == vehicle.timestamp,
        existing.vehicle.latitude == vehicle.latitude, existing.vehicle.longitude == vehicle.longitude
      {
        next[vehicle.id] = existing  // the same report again: nothing to change
        continue
      }
      let age = vehicle.timestamp.map { min(max(0, wall.timeIntervalSince($0)), Self.maxExtrapolation) } ?? 0
      let path = estimate ? schedule?.pathAhead(of: vehicle, seconds: Self.maxExtrapolation) : nil
      var from: CLLocationCoordinate2D?
      if smooth, let current = shown[vehicle.id] {
        let target = CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude)
        let distance = CLLocation(latitude: current.latitude, longitude: current.longitude)
          .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        if distance <= snapDistance { from = current }
      }
      next[vehicle.id] = Track(
        vehicle: vehicle, reportAge: age, received: now, path: path, speed: vehicle.speed ?? 0, shownFrom: from)
    }
    tracks = next
  }

  /// Where each bus should be drawn at `now`, and whether anything is still moving.
  func positions(at now: CFTimeInterval) -> (list: [DrawnBus], finished: Bool) {
    var finished = true
    let list = tracks.values.map { track -> DrawnBus in
      let sinceReceived = now - track.received
      let age = track.reportAge + sinceReceived
      let reported = CLLocationCoordinate2D(latitude: track.vehicle.latitude, longitude: track.vehicle.longitude)
      var target = reported
      if let path = track.path {
        // The report was valid `reportAge` seconds before it arrived, so the bus has covered that distance already.
        let elapsed = min(Self.maxExtrapolation, age)
        let point = Geometry.point(on: path, at: track.speed * elapsed)
        target = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        if age < Self.maxExtrapolation { finished = false }
      }
      var drawn = target
      if let from = track.shownFrom, sinceReceived < Self.blendDuration {
        let s = sinceReceived / Self.blendDuration
        let eased = s * s * (3 - 2 * s)
        drawn = CLLocationCoordinate2D(
          latitude: from.latitude + (target.latitude - from.latitude) * eased,
          longitude: from.longitude + (target.longitude - from.longitude) * eased)
        finished = false
      }
      return DrawnBus(vehicle: track.vehicle, coordinate: drawn, age: age)
    }
    return (list, finished)
  }
}
