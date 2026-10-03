import Foundation
import SwiftProtobuf

public enum RealtimeDecoder {
  /// Decodes a GTFS-Realtime `FeedMessage`. Any of the three feeds (vehicles, trips, alerts) can be passed.
  public static func decode(_ data: Data) throws -> RealtimeSnapshot {
    let message = try TransitRealtime_FeedMessage(serializedBytes: data)
    var vehicles: [VehicleSample] = []
    var predictions: [TripPrediction] = []
    var alerts: [ServiceAlert] = []

    for entity in message.entity {
      if entity.hasVehicle, entity.vehicle.hasPosition {
        vehicles.append(vehicleSample(entity.id, entity.vehicle))
      }
      if entity.hasTripUpdate {
        predictions.append(tripPrediction(entity.id, entity.tripUpdate))
      }
      if entity.hasAlert {
        alerts.append(serviceAlert(entity.id, entity.alert))
      }
    }
    return RealtimeSnapshot(
      feedTimestamp: message.header.hasTimestamp ? date(message.header.timestamp) : nil,
      vehicles: vehicles,
      predictions: predictions,
      alerts: alerts
    )
  }

  private static func date(_ seconds: UInt64) -> Date? {
    seconds == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(seconds))
  }

  private static func vehicleSample(_ entityID: String, _ v: TransitRealtime_VehiclePosition) -> VehicleSample {
    VehicleSample(
      entityID: entityID,
      vehicleID: v.hasVehicle ? v.vehicle.id : "",
      label: v.hasVehicle ? v.vehicle.label : "",
      tripID: v.hasTrip ? v.trip.tripID : "",
      routeID: v.hasTrip ? v.trip.routeID : "",
      directionID: v.hasTrip && v.trip.hasDirectionID ? Int(v.trip.directionID) : nil,
      startDate: v.hasTrip ? v.trip.startDate : "",
      latitude: Double(v.position.latitude),
      longitude: Double(v.position.longitude),
      bearing: v.position.hasBearing ? Double(v.position.bearing) : nil,
      speed: v.position.hasSpeed ? Double(v.position.speed) : nil,
      timestamp: v.hasTimestamp ? date(v.timestamp) : nil,
      currentStopSequence: v.hasCurrentStopSequence ? Int(v.currentStopSequence) : nil,
      stopID: v.stopID
    )
  }

  private static func tripPrediction(_ entityID: String, _ u: TransitRealtime_TripUpdate) -> TripPrediction {
    let relationship: String
    if u.trip.hasScheduleRelationship {
      relationship = "\(u.trip.scheduleRelationship)".uppercased()
    } else {
      relationship = ""
    }
    return TripPrediction(
      entityID: entityID,
      tripID: u.trip.tripID,
      routeID: u.trip.routeID,
      directionID: u.trip.hasDirectionID ? Int(u.trip.directionID) : nil,
      startDate: u.trip.startDate,
      startTime: u.trip.startTime,
      scheduleRelationship: relationship,
      vehicleID: u.hasVehicle ? u.vehicle.id : "",
      timestamp: u.hasTimestamp ? date(u.timestamp) : nil,
      delay: u.hasDelay ? Int(u.delay) : nil,
      stops: u.stopTimeUpdate.map { s in
        StopPrediction(
          stopID: s.stopID,
          sequence: s.hasStopSequence ? Int(s.stopSequence) : nil,
          arrival: s.hasArrival && s.arrival.hasTime ? date(UInt64(max(0, s.arrival.time))) : nil,
          arrivalDelay: s.hasArrival && s.arrival.hasDelay ? Int(s.arrival.delay) : nil,
          departure: s.hasDeparture && s.departure.hasTime ? date(UInt64(max(0, s.departure.time))) : nil,
          departureDelay: s.hasDeparture && s.departure.hasDelay ? Int(s.departure.delay) : nil,
          skipped: s.scheduleRelationship == .skipped
        )
      }
    )
  }

  private static func serviceAlert(_ entityID: String, _ a: TransitRealtime_Alert) -> ServiceAlert {
    func text(_ translated: TransitRealtime_TranslatedString) -> String {
      translated.translation.first(where: { $0.language.isEmpty || $0.language.hasPrefix("en") })?.text
        ?? translated.translation.first?.text ?? ""
    }
    return ServiceAlert(
      entityID: entityID,
      header: text(a.headerText),
      detail: text(a.descriptionText),
      routeIDs: a.informedEntity.filter { $0.hasRouteID }.map(\.routeID),
      stopIDs: a.informedEntity.filter { $0.hasStopID }.map(\.stopID)
    )
  }
}
