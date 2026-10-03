import Foundation
import Testing

@testable import HeadwayCore

@Suite struct ServiceStatusTests {
  let schedule: Schedule

  init() throws { schedule = try Schedule.load(directory: try makeFeed()) }

  private func monday(_ h: Int, _ m: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: h, minute: m))!
  }

  private func bus(trip: String, id: String = "v1") -> VehicleSample {
    VehicleSample(
      entityID: id, vehicleID: id, label: "", tripID: trip, routeID: "A", directionID: nil, startDate: "",
      latitude: 43.07, longitude: -89.4, bearing: nil, speed: nil, timestamp: nil, currentStopSequence: nil, stopID: "")
  }

  private func prediction(trip: String, sequence: Int, stop: String, at time: Date, relationship: String = "SCHEDULED") -> TripPrediction {
    TripPrediction(
      entityID: "p", tripID: trip, routeID: "A", directionID: nil, startDate: "", startTime: "",
      scheduleRelationship: relationship, vehicleID: "v1", timestamp: nil, delay: nil,
      stops: [StopPrediction(stopID: stop, sequence: sequence, arrival: time, arrivalDelay: nil, departure: nil, departureDelay: nil, skipped: false)])
  }

  @Test func measuresDelayAtTheNextStop() throws {
    // t1 reaches s2 (timetable 08:10) at 08:14: four minutes late.
    let status = ServiceStatusBuilder.build(
      schedule: schedule, predictions: [prediction(trip: "t1", sequence: 2, stop: "s2", at: monday(8, 14))],
      vehicles: [bus(trip: "t1")], now: monday(8, 5))
    let route = try #require(status.routes.first)
    #expect(route.buses == 1)
    #expect(route.measured == 1)
    #expect(route.averageDelay == 240)
    #expect(route.lateBuses == 0)  // under five minutes
  }

  @Test func countsLateAndEarlyBuses() throws {
    let predictions = [
      prediction(trip: "t1", sequence: 2, stop: "s2", at: monday(8, 17)),  // 7 min late
      prediction(trip: "t2", sequence: 2, stop: "s2", at: monday(23, 55)),  // timetable 24:20 -> 25 min early
    ]
    let status = ServiceStatusBuilder.build(
      schedule: schedule, predictions: predictions, vehicles: [bus(trip: "t1"), bus(trip: "t2", id: "v2")], now: monday(8, 5))
    // t2 is not running at 08:05, so its delay cannot be measured against a service date: only t1 counts.
    let route = try #require(status.routes.first)
    #expect(route.buses == 2)
    #expect(route.lateBuses == 1)
    #expect(route.worstDelay == 420)
  }

  @Test func busWithoutPredictionIsCountedButNotMeasured() throws {
    let status = ServiceStatusBuilder.build(schedule: schedule, predictions: [], vehicles: [bus(trip: "t1")], now: monday(8, 5))
    let route = try #require(status.routes.first)
    #expect(route.buses == 1)
    #expect(route.measured == 0)
    #expect(route.averageDelay == nil)
  }

  @Test func findsTripsWithNoPosition() {
    // At 08:05 only t1 is in progress (08:00-08:10, inset by two minutes it is 08:02-08:08).
    let silent = ServiceStatusBuilder.build(schedule: schedule, predictions: [], vehicles: [], now: monday(8, 5)).silentTrips
    #expect(silent.map(\.tripID) == ["t1"])
    let covered = ServiceStatusBuilder.build(schedule: schedule, predictions: [], vehicles: [bus(trip: "t1")], now: monday(8, 5)).silentTrips
    #expect(covered.isEmpty)
  }

  @Test func reportsCancelledTripsAndSkippedStops() {
    let cancelled = prediction(trip: "t1", sequence: 1, stop: "s1", at: monday(8, 0), relationship: "CANCELED")
    var skippedStop = prediction(trip: "t2", sequence: 1, stop: "s1", at: monday(8, 0))
    skippedStop = TripPrediction(
      entityID: "p", tripID: "t2", routeID: "A", directionID: nil, startDate: "", startTime: "",
      scheduleRelationship: "SCHEDULED", vehicleID: "", timestamp: nil, delay: nil,
      stops: [StopPrediction(stopID: "s1", sequence: 1, arrival: nil, arrivalDelay: nil, departure: nil, departureDelay: nil, skipped: true)])
    let status = ServiceStatusBuilder.build(schedule: schedule, predictions: [cancelled, skippedStop], vehicles: [], now: monday(8, 5))
    #expect(status.cancelledTrips.map(\.tripID) == ["t1"])
    #expect(status.skippedStops == 1)
  }
}
