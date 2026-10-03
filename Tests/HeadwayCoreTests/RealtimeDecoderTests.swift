import Foundation
import SwiftProtobuf
import Testing

@testable import HeadwayCore

@Suite struct RealtimeDecoderTests {
  private func feed() throws -> Data {
    var message = TransitRealtime_FeedMessage()
    message.header.gtfsRealtimeVersion = "2.0"
    message.header.timestamp = 1_790_000_000

    var vehicle = TransitRealtime_FeedEntity()
    vehicle.id = "v1"
    vehicle.vehicle.trip.tripID = "t1"
    vehicle.vehicle.trip.routeID = "A"
    vehicle.vehicle.vehicle.id = "2353"
    vehicle.vehicle.position.latitude = 43.07
    vehicle.vehicle.position.longitude = -89.4
    vehicle.vehicle.position.bearing = 90
    vehicle.vehicle.timestamp = 1_789_999_990
    message.entity.append(vehicle)

    var noPosition = TransitRealtime_FeedEntity()
    noPosition.id = "v2"
    noPosition.vehicle.trip.tripID = "t2"
    message.entity.append(noPosition)

    var update = TransitRealtime_FeedEntity()
    update.id = "u1"
    update.tripUpdate.trip.tripID = "t1"
    update.tripUpdate.trip.routeID = "A"
    update.tripUpdate.vehicle.id = "2353"
    var stop = TransitRealtime_TripUpdate.StopTimeUpdate()
    stop.stopID = "s2"
    stop.stopSequence = 2
    stop.arrival.time = 1_790_000_300
    var skipped = TransitRealtime_TripUpdate.StopTimeUpdate()
    skipped.stopID = "s3"
    skipped.scheduleRelationship = .skipped
    update.tripUpdate.stopTimeUpdate = [stop, skipped]
    message.entity.append(update)

    var alert = TransitRealtime_FeedEntity()
    alert.id = "a1"
    var header = TransitRealtime_TranslatedString.Translation()
    header.text = "L - Detour"
    header.language = "en"
    alert.alert.headerText.translation = [header]
    var body = TransitRealtime_TranslatedString.Translation()
    body.text = "Buses skip Aberg Ave."
    alert.alert.descriptionText.translation = [body]
    var entity = TransitRealtime_EntitySelector()
    entity.routeID = "L"
    alert.alert.informedEntity = [entity]
    message.entity.append(alert)
    return try message.serializedData()
  }

  @Test func decodesVehicles() throws {
    let snapshot = try RealtimeDecoder.decode(try feed())
    #expect(snapshot.feedTimestamp == Date(timeIntervalSince1970: 1_790_000_000))
    // The entity without a position is dropped.
    #expect(snapshot.vehicles.count == 1)
    let bus = try #require(snapshot.vehicles.first)
    #expect(bus.vehicleID == "2353")
    #expect(bus.tripID == "t1")
    #expect(bus.routeID == "A")
    #expect(abs(bus.latitude - 43.07) < 1e-4)
    #expect(bus.bearing == 90)
    #expect(bus.timestamp == Date(timeIntervalSince1970: 1_789_999_990))
  }

  @Test func decodesPredictionsIncludingSkippedStops() throws {
    let snapshot = try RealtimeDecoder.decode(try feed())
    let prediction = try #require(snapshot.predictions.first)
    #expect(prediction.tripID == "t1")
    #expect(prediction.vehicleID == "2353")
    #expect(prediction.stops.count == 2)
    #expect(prediction.stops[0].arrival == Date(timeIntervalSince1970: 1_790_000_300))
    #expect(prediction.stops[0].sequence == 2)
    #expect(prediction.stops[1].skipped)
    #expect(prediction.stops[1].arrival == nil)
  }

  @Test func decodesAlerts() throws {
    let snapshot = try RealtimeDecoder.decode(try feed())
    let alert = try #require(snapshot.alerts.first)
    #expect(alert.header == "L - Detour")
    #expect(alert.detail == "Buses skip Aberg Ave.")
    #expect(alert.routeIDs == ["L"])
  }

  @Test func feedWithNoEntitiesDecodes() throws {
    var message = TransitRealtime_FeedMessage()
    message.header.gtfsRealtimeVersion = "2.0"
    let snapshot = try RealtimeDecoder.decode(try message.serializedData())
    #expect(snapshot.vehicles.isEmpty && snapshot.predictions.isEmpty && snapshot.alerts.isEmpty)
  }

  @Test func emptyBytesAreAnErrorBecauseTheHeaderIsRequired() {
    // The old transitdata.cityofmadison.com URLs returned tiny empty files; they must read as failures.
    #expect(throws: (any Error).self) { try RealtimeDecoder.decode(Data()) }
  }

  @Test func garbageThrows() {
    #expect(throws: (any Error).self) { try RealtimeDecoder.decode(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])) }
  }
}
