import Foundation

/// One bus as reported by the GTFS-Realtime vehicle positions feed.
public struct VehicleSample: Sendable, Identifiable, Hashable {
  public var id: String { vehicleID.isEmpty ? entityID : vehicleID }
  public let entityID: String
  public let vehicleID: String
  public let label: String
  /// Empty when the bus reports a position but is not linked to a scheduled trip.
  public let tripID: String
  public let routeID: String
  public let directionID: Int?
  public let startDate: String
  public let latitude: Double
  public let longitude: Double
  public let bearing: Double?
  public let speed: Double?
  public let timestamp: Date?
  public let currentStopSequence: Int?
  public let stopID: String
}

public struct StopPrediction: Sendable, Hashable {
  public let stopID: String
  public let sequence: Int?
  public let arrival: Date?
  public let arrivalDelay: Int?
  public let departure: Date?
  public let departureDelay: Int?
  public let skipped: Bool
}

/// Predictions for one trip from the trip updates feed.
public struct TripPrediction: Sendable, Hashable {
  public let entityID: String
  public let tripID: String
  public let routeID: String
  public let directionID: Int?
  public let startDate: String
  public let startTime: String
  /// `SCHEDULED`, `ADDED`, `UNSCHEDULED`, `CANCELED`, ... or empty when the feed does not say.
  public let scheduleRelationship: String
  public let vehicleID: String
  public let timestamp: Date?
  public let delay: Int?
  public let stops: [StopPrediction]
}

public struct ServiceAlert: Sendable, Hashable, Identifiable {
  public var id: String { entityID }
  public let entityID: String
  public let header: String
  /// The longer text, when the city provides one.
  public let detail: String
  /// A page with more information, such as a detour map, when the city provides one.
  public let url: URL?
  /// `DETOUR`, `NO_SERVICE`, `REDUCED_SERVICE`, `SIGNIFICANT_DELAYS`, `STOP_MOVED`, ... or empty.
  public let effect: String
  /// When the alert applies. Empty means "always" (the feed gave no period).
  public let activePeriods: [AlertPeriod]
  public let routeIDs: [String]
  public let stopIDs: [String]
}

public struct AlertPeriod: Sendable, Hashable {
  public let start: Date?
  public let end: Date?

  public func contains(_ moment: Date) -> Bool {
    (start.map { moment >= $0 } ?? true) && (end.map { moment <= $0 } ?? true)
  }
}

extension ServiceAlert {
  public func isActive(at moment: Date) -> Bool {
    activePeriods.isEmpty || activePeriods.contains { $0.contains(moment) }
  }

  /// True when the alert has a period that starts after `moment`.
  public func isUpcoming(at moment: Date) -> Bool {
    !isActive(at: moment) && activePeriods.contains { ($0.start ?? .distantPast) > moment }
  }
}

public struct RealtimeSnapshot: Sendable {
  /// The time the producer stamped on the whole feed.
  public let feedTimestamp: Date?
  /// The server's clock when it answered (the HTTP `Date` header). Compared with `feedTimestamp` it says how old the
  /// feed is, without trusting the phone's own clock. Set by `RealtimeClient`.
  public internal(set) var serverDate: Date? = nil
  public let vehicles: [VehicleSample]
  public let predictions: [TripPrediction]
  public let alerts: [ServiceAlert]
}
