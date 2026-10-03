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

public struct ServiceAlert: Sendable, Hashable {
  public let entityID: String
  public let header: String
  public let routeIDs: [String]
  public let stopIDs: [String]
}

public struct RealtimeSnapshot: Sendable {
  /// The time the producer stamped on the whole feed.
  public let feedTimestamp: Date?
  public let vehicles: [VehicleSample]
  public let predictions: [TripPrediction]
  public let alerts: [ServiceAlert]
}
