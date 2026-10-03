import Foundation

/// How one route is doing right now, from the buses that are reporting.
public struct RouteStatus: Sendable, Identifiable, Hashable {
  public var id: String { routeID }
  public let routeID: String
  /// Buses on this route in the position feed.
  public let buses: Int
  /// Buses for which the trip updates give a time at an upcoming stop, so a delay could be measured.
  public let measured: Int
  /// Seconds, positive when late. `nil` when nothing could be measured.
  public let averageDelay: Double?
  public let worstDelay: Double?
  public let lateBuses: Int  // more than five minutes late
  public let earlyBuses: Int  // more than two minutes early
}

/// A trip that should be running according to the timetable but has no bus reporting a position.
public struct SilentTrip: Sendable, Identifiable, Hashable {
  public var id: String { "\(tripID)@\(serviceDate.value)" }
  public let tripID: String
  public let routeID: String
  public let headsign: String
  public let serviceDate: ServiceDate
  public let scheduledStart: Date
  public let scheduledEnd: Date
}

public struct ServiceStatus: Sendable {
  public let routes: [RouteStatus]
  public let cancelledTrips: [TripPrediction]
  public let skippedStops: Int
  public let silentTrips: [SilentTrip]
  public let busesOnRoad: Int
}

public enum ServiceStatusBuilder {
  /// Seconds a bus must be late before it counts as late.
  public static let lateThreshold = 300.0
  public static let earlyThreshold = -120.0

  public static func build(
    schedule: Schedule, predictions: [TripPrediction], vehicles: [VehicleSample], now: Date
  ) -> ServiceStatus {
    var predictionByTrip: [String: TripPrediction] = [:]
    for prediction in predictions where !prediction.tripID.isEmpty { predictionByTrip[prediction.tripID] = prediction }

    var delays: [String: [Double]] = [:]
    var buses: [String: Int] = [:]
    for vehicle in vehicles {
      buses[vehicle.routeID, default: 0] += 1
      guard let delay = delay(of: vehicle, prediction: predictionByTrip[vehicle.tripID], schedule: schedule, now: now) else {
        continue
      }
      delays[vehicle.routeID, default: []].append(delay)
    }
    let routes = buses.map { routeID, count -> RouteStatus in
      let measured = delays[routeID] ?? []
      return RouteStatus(
        routeID: routeID, buses: count, measured: measured.count,
        averageDelay: measured.isEmpty ? nil : measured.reduce(0, +) / Double(measured.count),
        worstDelay: measured.max(), lateBuses: measured.filter { $0 > lateThreshold }.count,
        earlyBuses: measured.filter { $0 < earlyThreshold }.count)
    }
    .sorted { (schedule.routes[$0.routeID]?.sortOrder ?? .max, $0.routeID) < (schedule.routes[$1.routeID]?.sortOrder ?? .max, $1.routeID) }

    let cancelled = predictions.filter { $0.scheduleRelationship == "CANCELED" || $0.scheduleRelationship == "CANCELLED" }
    let skipped = predictions.reduce(0) { $0 + $1.stops.filter(\.skipped).count }

    let reporting = Set(vehicles.map(\.tripID))
    let silent = schedule.scheduledTrips(at: now, inset: 120).compactMap { trip, date -> SilentTrip? in
      guard !reporting.contains(trip.id), let times = schedule.stopTimes[trip.id], let first = times.first, let last = times.last
      else { return nil }
      let midnight = date.midnight(in: schedule.timeZone)
      return SilentTrip(
        tripID: trip.id, routeID: trip.routeID, headsign: trip.headsign, serviceDate: date,
        scheduledStart: midnight.addingTimeInterval(Double(first.departure)),
        scheduledEnd: midnight.addingTimeInterval(Double(last.arrival)))
    }
    .sorted { $0.scheduledStart < $1.scheduledStart }

    return ServiceStatus(
      routes: routes, cancelledTrips: cancelled, skippedStops: skipped, silentTrips: silent, busesOnRoad: vehicles.count)
  }

  /// Predicted time at the next stop minus the timetable, in seconds.
  static func delay(of vehicle: VehicleSample, prediction: TripPrediction?, schedule: Schedule, now: Date) -> Double? {
    guard let prediction, let date = schedule.serviceDate(of: vehicle.tripID, near: now) else { return nil }
    for stop in prediction.stops where !stop.skipped {
      guard let predicted = stop.arrival ?? stop.departure, predicted >= now.addingTimeInterval(-60),
        let sequence = stop.sequence, let scheduled = schedule.scheduledArrival(tripID: vehicle.tripID, sequence: sequence, on: date)
      else { continue }
      let delay = predicted.timeIntervalSince(scheduled)
      return abs(delay) < 3 * 3600 ? delay : nil
    }
    return nil
  }
}
