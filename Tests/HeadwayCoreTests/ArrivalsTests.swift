import Foundation
import Testing

@testable import HeadwayCore

@Suite struct ArrivalsTests {
  let schedule: Schedule

  init() throws { schedule = try Schedule.load(directory: try makeFeed()) }

  /// Monday 2026-10-05 at the given local time.
  private func monday(_ h: Int, _ m: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: h, minute: m))!
  }

  private func vehicle(trip: String) -> VehicleSample {
    VehicleSample(
      entityID: "1", vehicleID: "v1", label: "", tripID: trip, routeID: "A", directionID: nil, startDate: "",
      latitude: 43.07, longitude: -89.40, bearing: nil, speed: nil, timestamp: nil, currentStopSequence: nil,
      stopID: "")
  }

  private func prediction(trip: String, stop: String, sequence: Int, at time: Date, skipped: Bool = false) -> TripPrediction {
    TripPrediction(
      entityID: "1", tripID: trip, routeID: "A", directionID: nil, startDate: "", startTime: "",
      scheduleRelationship: "SCHEDULED", vehicleID: "v1", timestamp: nil, delay: nil,
      stops: [
        StopPrediction(
          stopID: stop, sequence: sequence, arrival: time, arrivalDelay: nil, departure: nil, departureDelay: nil,
          skipped: skipped)
      ])
  }

  @Test func timetableOnlyWhenNothingIsLive() {
    // t2 leaves at 23:50, so it only shows up with a long window.
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(7, 50), window: 20 * 3600, predictions: [], vehicles: [])
    #expect(result.map(\.tripID) == ["t1", "t2"])
    #expect(result[0].status == .scheduled)
    #expect(result[0].expected == monday(8, 0))
    #expect(result[0].delay == nil)
  }

  @Test func lastStopOfATripIsNotListed() {
    // s2 is the last stop of both trips, so nobody boards there.
    let result = Arrivals.upcoming(schedule: schedule, stopID: "s2", now: monday(7, 50), predictions: [], vehicles: [])
    #expect(result.isEmpty)
  }

  @Test func liveWhenBusAndPredictionExist() {
    let late = monday(8, 4)
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(7, 50),
      predictions: [prediction(trip: "t1", stop: "s1", sequence: 1, at: late)], vehicles: [vehicle(trip: "t1")])
    #expect(result[0].status == .live)
    #expect(result[0].expected == late)
    #expect(result[0].delay == 240)
    #expect(result[0].minutes(from: monday(7, 50)) == 14)
  }

  @Test func predictionWithoutBusStaysScheduled() {
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(7, 50),
      predictions: [prediction(trip: "t1", stop: "s1", sequence: 1, at: monday(8, 4))], vehicles: [])
    #expect(result[0].status == .scheduled)
    #expect(result[0].expected == monday(8, 0))
  }

  @Test func lateBusStillListedAfterItsTimetableTime() {
    // Timetable says 08:00, the bus is 5 minutes late, and it is 08:02 now.
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(8, 2),
      predictions: [prediction(trip: "t1", stop: "s1", sequence: 1, at: monday(8, 5))], vehicles: [vehicle(trip: "t1")])
    #expect(result.first?.tripID == "t1")
    #expect(result.first?.delay == 300)
  }

  @Test func busThatHasGoneIsDropped() {
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(8, 10), window: 20 * 3600, predictions: [], vehicles: [])
    #expect(result.map(\.tripID) == ["t2"])
  }

  @Test func skippedStopIsNotListed() {
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(7, 50), window: 20 * 3600,
      predictions: [prediction(trip: "t1", stop: "s1", sequence: 1, at: monday(8, 0), skipped: true)],
      vehicles: [vehicle(trip: "t1")])
    #expect(result.map(\.tripID) == ["t2"])
  }

  @Test func windowLimitsHowFarAheadWeLook() {
    let result = Arrivals.upcoming(
      schedule: schedule, stopID: "s1", now: monday(7, 50), window: 600, predictions: [], vehicles: [])
    #expect(result.map(\.tripID) == ["t1"])
  }

  @Test func remainingStopsUseThePredictionWhereThereIsOne() {
    let predicted = monday(8, 12)
    let stops = Arrivals.remainingStops(
      schedule: schedule, tripID: "t1", now: monday(8, 1),
      prediction: prediction(trip: "t1", stop: "s2", sequence: 2, at: predicted))
    // s1 (08:00) has just gone by more than 30 s ago, so only s2 remains.
    #expect(stops.map(\.stopID) == ["s2"])
    #expect(stops[0].scheduled == monday(8, 10))
    #expect(stops[0].expected == predicted)
  }

  @Test func serviceDateOfAPastMidnightTripIsThePreviousDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    let tuesdayAfterMidnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 0, minute: 10))!
    #expect(schedule.serviceDate(of: "t2", near: tuesdayAfterMidnight) == ServiceDate(20_261_005))
  }
}
