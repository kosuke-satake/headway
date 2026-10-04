import Foundation

/// One position report of a bus.
public struct PositionSample: Sendable, Hashable {
  public let time: Date
  public let coordinate: Coordinate

  public init(time: Date, coordinate: Coordinate) {
    self.time = time
    self.coordinate = coordinate
  }
}

/// When a bus really passed a stop, compared with the timetable.
public struct ArrivalObservation: Sendable, Hashable {
  public let tripID: String
  public let serviceDate: ServiceDate
  public let stopID: String
  public let sequence: Int
  public let scheduled: Date
  public let actual: Date

  /// Seconds late (positive) or early (negative).
  public var delay: Double { actual.timeIntervalSince(scheduled) }
}

/// Works out the real arrival times at a trip's stops from the bus's position reports.
///
/// Each report is turned into a distance along the route; each stop is too. The time the bus reached a stop's
/// distance is found by interpolating between the two reports on either side. Reports 75 seconds or more apart are
/// not interpolated across (the bus may have stopped reporting), and reports far from the route line are ignored.
public final class ArrivalEstimator {
  public let schedule: Schedule
  private var shapes: [String: ShapeIndex] = [:]

  /// A report farther than this from the route line is not used (the bus is on a detour or in the garage).
  public static let maxOffset = 80.0
  /// Longest gap between two reports that is still interpolated across.
  public static let maxGap: TimeInterval = 75
  /// A bus counts as arrived a little before the stop's exact position, since buses stop short of the pole.
  public static let arrivalTolerance = 12.0

  public init(schedule: Schedule) {
    self.schedule = schedule
  }

  public func shape(for trip: Trip) -> ShapeIndex? {
    if let cached = shapes[trip.shapeID] { return cached }
    guard let points = schedule.shapes[trip.shapeID], points.count > 1 else { return nil }
    let index = ShapeIndex(points)
    shapes[trip.shapeID] = index
    return index
  }

  public func observations(tripID: String, serviceDate: ServiceDate, samples: [PositionSample]) -> [ArrivalObservation] {
    guard let trip = schedule.trips[tripID], let shape = shape(for: trip), let times = schedule.stopTimes[tripID],
      samples.count >= 2
    else { return [] }

    // 1. Reports -> distance along the route, kept non-decreasing.
    var track: [(time: Date, along: Double)] = []
    var segment = 0
    var lastAlong = -Double.infinity
    for sample in samples.sorted(by: { $0.time < $1.time }) {
      // After the first report only look near where the bus was, so a loop route cannot jump to its other end.
      let projection =
        track.isEmpty
        ? shape.project(sample.coordinate)
        : shape.project(sample.coordinate, first: max(0, segment - 2), last: segment + 400)
      guard let projection, projection.offset <= Self.maxOffset else { continue }
      if projection.along < lastAlong - 40 { continue }  // a backwards jump: GPS noise
      let along = max(projection.along, lastAlong)
      segment = projection.segment
      lastAlong = along
      track.append((sample.time, along))
    }
    guard track.count >= 2 else { return [] }

    // 2. Stops -> distance along the route, in order.
    let midnight = serviceDate.midnight(in: schedule.timeZone)
    var observations: [ArrivalObservation] = []
    var stopSegment = 0
    var lastStopAlong = 0.0
    for time in times {
      guard let stop = schedule.stops[time.stopID],
        let projection = shape.project(Coordinate(latitude: stop.latitude, longitude: stop.longitude), first: stopSegment)
      else { continue }
      if projection.offset > 120 { continue }  // the stop is not on this line (a side street or a flag stop)
      let along = max(projection.along, lastStopAlong)
      stopSegment = projection.segment
      lastStopAlong = along

      // 3. When did the bus reach that distance?
      let target = along - Self.arrivalTolerance
      guard let upper = track.firstIndex(where: { $0.along >= target }), upper > 0 else { continue }
      let before = track[upper - 1], after = track[upper]
      let gap = after.time.timeIntervalSince(before.time)
      guard gap <= Self.maxGap else { continue }
      let travelled = after.along - before.along
      let fraction = travelled < 1 ? 1 : min(1, max(0, (target - before.along) / travelled))
      let actual = before.time.addingTimeInterval(gap * fraction)
      let scheduled = midnight.addingTimeInterval(Double(time.arrival))
      // A day's worth of difference means the wrong service date was assumed; drop it rather than record nonsense.
      if abs(actual.timeIntervalSince(scheduled)) > 3 * 3600 { continue }
      observations.append(
        ArrivalObservation(
          tripID: tripID, serviceDate: serviceDate, stopID: time.stopID, sequence: time.sequence, scheduled: scheduled,
          actual: actual))
    }
    return observations
  }
}
