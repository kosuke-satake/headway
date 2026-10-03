import Foundation

/// One upcoming bus at a stop, combining the timetable with what the realtime feeds say.
public struct Arrival: Sendable, Identifiable, Hashable {
  public enum Status: Sendable, Hashable {
    /// A bus is reporting its position for this trip and the feed predicts a time at this stop.
    case live
    /// Only the timetable is known. Either no bus has been seen for this trip, or the feed has no prediction.
    case scheduled
  }

  public var id: String { "\(tripID)@\(serviceDate.value)#\(sequence)" }
  public let tripID: String
  public let routeID: String
  public let headsign: String
  public let serviceDate: ServiceDate
  public let sequence: Int
  public let scheduled: Date
  public let predicted: Date?
  public let status: Status
  public let vehicle: VehicleSample?

  /// The best estimate: the prediction when the bus is live, otherwise the timetable.
  public var expected: Date { status == .live ? (predicted ?? scheduled) : scheduled }

  /// Seconds later (positive) or earlier (negative) than the timetable. `nil` when only the timetable is known.
  public var delay: Int? {
    guard status == .live, let predicted else { return nil }
    return Int(predicted.timeIntervalSince(scheduled).rounded())
  }

  public func minutes(from now: Date) -> Int {
    Int((expected.timeIntervalSince(now) / 60).rounded(.down))
  }
}

public enum Arrivals {
  /// Upcoming departures from `stopID`, soonest first.
  ///
  /// The timetable is searched from 30 minutes before `now`, so a late bus whose timetable time has passed is still
  /// listed. A departure is `live` only when a bus reports a position for that trip and the trip updates predict a
  /// time at this stop; predictions for trips without a bus are just the timetable again.
  public static func upcoming(
    schedule: Schedule,
    stopID: String,
    now: Date,
    window: TimeInterval = 3 * 3600,
    predictions: [TripPrediction],
    vehicles: [VehicleSample],
    limit: Int = 40
  ) -> [Arrival] {
    var predictionByTrip: [String: TripPrediction] = [:]
    for prediction in predictions where !prediction.tripID.isEmpty { predictionByTrip[prediction.tripID] = prediction }
    var vehicleByTrip: [String: VehicleSample] = [:]
    for vehicle in vehicles where !vehicle.tripID.isEmpty { vehicleByTrip[vehicle.tripID] = vehicle }

    var arrivals: [Arrival] = []
    for departure in schedule.scheduledDepartures(from: stopID, from: now.addingTimeInterval(-30 * 60), until: now.addingTimeInterval(window)) {
      var predicted: Date?
      var skipped = false
      if let prediction = predictionByTrip[departure.tripID] {
        let stop = prediction.stops.first { $0.stopID == stopID && $0.sequence == departure.sequence }
          ?? prediction.stops.first { $0.stopID == stopID && $0.sequence == nil }
        if let stop {
          predicted = stop.arrival ?? stop.departure
          skipped = stop.skipped
        }
      }
      if skipped { continue }
      let vehicle = vehicleByTrip[departure.tripID]
      let live = vehicle != nil && predicted != nil
      let arrival = Arrival(
        tripID: departure.tripID, routeID: departure.routeID, headsign: departure.headsign,
        serviceDate: departure.serviceDate, sequence: departure.sequence, scheduled: departure.time,
        predicted: predicted, status: live ? .live : .scheduled, vehicle: vehicle)
      // Drop buses that have already gone (a 20 second grace keeps "Due" visible).
      if arrival.expected < now.addingTimeInterval(-20) { continue }
      arrivals.append(arrival)
    }
    arrivals.sort { $0.expected < $1.expected }
    return Array(arrivals.prefix(limit))
  }
}

/// One remaining stop of a trip, for the "where is this bus going next" list.
public struct TripStopEta: Sendable, Identifiable, Hashable {
  public var id: Int { sequence }
  public let sequence: Int
  public let stopID: String
  public let scheduled: Date
  public let predicted: Date?

  public var expected: Date { predicted ?? scheduled }
}

extension Arrivals {
  /// The stops `tripID` has yet to serve, with predicted times when the feed provides them.
  public static func remainingStops(
    schedule: Schedule, tripID: String, now: Date, prediction: TripPrediction?
  ) -> [TripStopEta] {
    guard let times = schedule.stopTimes[tripID], let date = schedule.serviceDate(of: tripID, near: now) else { return [] }
    let midnight = date.midnight(in: schedule.timeZone)
    var predictedBySequence: [Int: Date] = [:]
    var predictedByStop: [String: Date] = [:]
    for stop in prediction?.stops ?? [] where !stop.skipped {
      guard let time = stop.arrival ?? stop.departure else { continue }
      if let sequence = stop.sequence { predictedBySequence[sequence] = time } else { predictedByStop[stop.stopID] = time }
    }
    var result: [TripStopEta] = []
    for time in times {
      let scheduled = midnight.addingTimeInterval(TimeInterval(time.arrival))
      let predicted = predictedBySequence[time.sequence] ?? predictedByStop[time.stopID]
      let eta = TripStopEta(sequence: time.sequence, stopID: time.stopID, scheduled: scheduled, predicted: predicted)
      if eta.expected >= now.addingTimeInterval(-30) { result.append(eta) }
    }
    return result
  }
}
