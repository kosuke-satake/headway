import Foundation
import Testing

@testable import HeadwayCore

/// A small network written to a temporary folder.
///
///     A --R1--> B --R1--> C --R2--> D          (R1: A 08:00, B 08:05, C 08:10; R2: C 08:15, D 08:25)
///     A ----------R3-----------> D             (A 08:02, D 09:00)
///     C2 (100 m south of C) --R4--> E          (C2 08:15, E 08:30)
///
/// Each route also runs an hour later. R2 has an extra trip leaving C 30 s after R1 arrives (too tight to use).
private func makePlannerFeed(stopAccess: [String: Int] = [:], tripAccess: [String: Int] = [:]) throws -> Schedule {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headway-plan-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  var stopTimes = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
  func trip(_ id: String, _ stops: [(String, String)]) {
    for (index, entry) in stops.enumerated() {
      stopTimes += "\(id),\(entry.1),\(entry.1),\(entry.0),\(index + 1)\n"
    }
  }
  trip("r1a", [("A", "08:00:00"), ("B", "08:05:00"), ("C", "08:10:00")])
  trip("r1b", [("A", "09:00:00"), ("B", "09:05:00"), ("C", "09:10:00")])
  trip("r2a", [("C", "08:15:00"), ("D", "08:25:00")])
  trip("r2b", [("C", "09:15:00"), ("D", "09:25:00")])
  trip("r2tight", [("C", "08:10:30"), ("D", "08:20:30")])
  trip("r3", [("A", "08:02:00"), ("D", "09:00:00")])
  trip("r4a", [("C2", "08:15:00"), ("E", "08:30:00")])
  let routeOf = ["r1a": "R1", "r1b": "R1", "r2a": "R2", "r2b": "R2", "r2tight": "R2", "r3": "R3", "r4a": "R4"]
  let shapeOf = ["R1": "s1", "R2": "s2", "R3": "s3", "R4": "s4"]
  var trips = "trip_id,route_id,service_id,trip_headsign,direction_id,shape_id,block_id,wheelchair_accessible\n"
  for (id, route) in routeOf.sorted(by: { $0.key < $1.key }) {
    trips += "\(id),\(route),wk,To \(route),0,\(shapeOf[route]!),b\(id),\(tripAccess[id] ?? 0)\n"
  }
  let stopRows = [("A", 43.0, -89.4), ("B", 43.0, -89.39), ("C", 43.0, -89.38), ("D", 43.01, -89.38), ("C2", 42.9991, -89.38), ("E", 43.01, -89.37), ("F", 43.1, -89.3)]
  var stopsText = "stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding\n"
  for (index, row) in stopRows.enumerated() {
    let names = ["Alpha", "Bravo", "Charlie", "Delta", "Charlie South", "Echo", "Far"]
    stopsText += "\(row.0),\(index + 1),\(names[index]),\(row.1),\(row.2),\(stopAccess[row.0] ?? 0)\n"
  }
  let files: [String: String] = [
    "agency.txt": "agency_id,agency_name,agency_timezone\n1,Test,America/Chicago\n",
    "routes.txt": "route_id,route_short_name,route_long_name,route_color,route_text_color,route_sort_order\nR1,1,One,FF0000,FFFFFF,1\nR2,2,Two,00FF00,000000,2\nR3,3,Three,0000FF,FFFFFF,3\nR4,4,Four,FFFF00,000000,4\n",
    "stops.txt": stopsText,
    "trips.txt": trips,
    "stop_times.txt": stopTimes,
    "shapes.txt": """
      shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence
      s1,43.0000,-89.4000,1
      s1,43.0000,-89.3950,2
      s1,43.0000,-89.3900,3
      s1,43.0000,-89.3850,4
      s1,43.0000,-89.3800,5
      s2,43.0000,-89.3800,1
      s2,43.0050,-89.3800,2
      s2,43.0100,-89.3800,3
      s3,43.0000,-89.4000,1
      s3,43.0100,-89.4000,2
      s3,43.0100,-89.3800,3
      s4,42.9991,-89.3800,1
      s4,43.0100,-89.3700,2

      """,
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nwk,1,1,1,1,1,0,0,20261001,20261231\n",
    "feed_info.txt": "feed_version,feed_start_date,feed_end_date\nv1,20261001,20261231\n",
  ]
  for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
  return try Schedule.load(directory: dir)
}

@Suite struct PlannerAccessibilityTests {
  private func monday(_ schedule: Schedule, _ h: Int, _ m: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: h, minute: m))!
  }

  private func point(_ schedule: Schedule, _ id: String) -> PlanPoint {
    let stop = schedule.stops[id]!
    return PlanPoint(name: stop.name, coordinate: Coordinate(latitude: stop.latitude, longitude: stop.longitude), stopID: id)
  }

  @Test func inaccessibleStopsCannotBeUsedForTransfers() throws {
    // Charlie (the transfer stop) is not accessible: the only wheelchair journey from A to D is the direct bus.
    let schedule = try makePlannerFeed(stopAccess: ["C": 2])
    var options = PlanOptions()
    options.accessibleOnly = true
    let journeys = TripPlanner(schedule: schedule).plan(
      from: point(schedule, "A"), to: point(schedule, "D"), departAt: monday(schedule, 7, 55), options: options)
    #expect(!journeys.isEmpty)
    #expect(journeys.allSatisfy { $0.transfers == 0 })
    // Without the option the transfer journey is still offered.
    let all = TripPlanner(schedule: schedule).plan(
      from: point(schedule, "A"), to: point(schedule, "D"), departAt: monday(schedule, 7, 55))
    #expect(all.contains { $0.transfers == 1 })
  }

  @Test func inaccessibleTripsAreSkipped() throws {
    let schedule = try makePlannerFeed(tripAccess: ["r3": 2])
    var options = PlanOptions()
    options.accessibleOnly = true
    let journeys = TripPlanner(schedule: schedule).plan(
      from: point(schedule, "A"), to: point(schedule, "D"), departAt: monday(schedule, 7, 55), options: options)
    #expect(!journeys.contains { $0.rides.contains { $0.tripID == "r3" } })
    #expect(journeys.contains { $0.rides.map(\.tripID) == ["r1a", "r2a"] })
  }

  @Test func unknownAccessibilityIsAllowed() throws {
    // The feed says nothing (0) about accessibility: the option must not rule everything out.
    let schedule = try makePlannerFeed()
    var options = PlanOptions()
    options.accessibleOnly = true
    #expect(!TripPlanner(schedule: schedule).plan(
      from: point(schedule, "A"), to: point(schedule, "D"), departAt: monday(schedule, 7, 55), options: options).isEmpty)
  }
}

@Suite struct TripPlannerTests {
  let schedule: Schedule
  let planner: TripPlanner

  init() throws {
    schedule = try makePlannerFeed()
    planner = TripPlanner(schedule: schedule)
  }

  private func monday(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: h, minute: m, second: s))!
  }

  private func stop(_ id: String) -> PlanPoint {
    let s = schedule.stops[id]!
    return PlanPoint(name: s.name, coordinate: Coordinate(latitude: s.latitude, longitude: s.longitude), stopID: id)
  }

  private func point(_ lat: Double, _ lon: Double, _ name: String = "Somewhere") -> PlanPoint {
    PlanPoint(name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
  }

  @Test func findsTheFastJourneyWithATransfer() {
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55))
    let fastest = journeys.min { $0.arrival < $1.arrival }
    #expect(fastest?.arrival == monday(8, 25))
    #expect(fastest?.transfers == 1)
    #expect(fastest?.rides.map(\.tripID) == ["r1a", "r2a"])
  }

  @Test func offersTheDirectBusAsAnAlternative() {
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55))
    let direct = journeys.first { $0.transfers == 0 }
    #expect(direct?.rides.map(\.tripID) == ["r3"])
    #expect(direct?.arrival == monday(9, 0))
  }

  @Test func laterBusesAreOffered() {
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55))
    #expect(journeys.contains { $0.rides.first?.tripID == "r1b" })
  }

  @Test func tooTightATransferIsNotUsed() {
    // r2tight leaves C 30 s after r1a arrives; the minimum is 60 s, so the planner must take r2a.
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55))
    #expect(!journeys.contains { $0.rides.contains { $0.tripID == "r2tight" } })
  }

  @Test func walksBetweenNearbyStopsToTransfer() throws {
    let journeys = planner.plan(from: stop("A"), to: stop("E"), departAt: monday(7, 55))
    let journey = try #require(journeys.first)
    #expect(journey.rides.map(\.tripID) == ["r1a", "r4a"])
    #expect(journey.arrival == monday(8, 30))
    let walks = journey.legs.compactMap { leg -> WalkLeg? in if case .walk(let w) = leg { return w } else { return nil } }
    #expect(walks.count == 1)
    #expect(walks[0].meters > 80 && walks[0].meters < 130)
    // Charlie is reached at 08:10, the walk takes under two minutes, and R4 leaves at 08:15.
    #expect(walks[0].end < monday(8, 15))
  }

  @Test func walksToTheFirstStopFromAnArbitraryPoint() throws {
    // About 150 m west of Alpha.
    let origin = point(43.0, -89.4018, "Home")
    let journeys = planner.plan(from: origin, to: stop("C"), departAt: monday(7, 55))
    let journey = try #require(journeys.first)
    guard case .walk(let lead) = journey.legs[0] else {
      Issue.record("expected a walking leg first")
      return
    }
    #expect(lead.meters > 120 && lead.meters < 180)
    #expect(journey.rides.first?.tripID == "r1a")
    #expect(journey.arrival == monday(8, 10))
    #expect(journey.departure < monday(8, 0))
    // The walk is moved as late as possible: it ends exactly when the bus leaves.
    #expect(lead.end == monday(8, 0))
    #expect(journey.departure > monday(7, 56))
  }

  @Test func walksFromTheLastStopToAnArbitraryPoint() throws {
    // About 100 m east of Charlie.
    let destination = point(43.0, -89.3789, "Office")
    let journeys = planner.plan(from: stop("A"), to: destination, departAt: monday(7, 55))
    let journey = try #require(journeys.first)
    guard case .walk(let tail) = journey.legs.last! else {
      Issue.record("expected a walking leg last")
      return
    }
    #expect(tail.meters > 80 && tail.meters < 130)
    #expect(journey.arrival > monday(8, 10))
  }

  @Test func closePointsAreJustAWalk() throws {
    let a = point(43.0, -89.4, "One")
    let b = point(43.0, -89.396, "Two")  // about 320 m
    let journeys = planner.plan(from: a, to: b, departAt: monday(7, 55))
    let journey = try #require(journeys.first)
    #expect(journey.rides.isEmpty)
    #expect(journey.legs.count == 1)
  }

  @Test func nothingRunsAtNight() {
    #expect(planner.plan(from: stop("A"), to: stop("D"), departAt: monday(3, 0)).isEmpty)
  }

  @Test func unreachableDestinationGivesNoJourney() {
    #expect(planner.plan(from: stop("A"), to: stop("F"), departAt: monday(7, 55)).isEmpty)
  }

  @Test func aLiveDelayCausesAMissedConnection() {
    // r1a is 10 minutes late everywhere, so it reaches C at 08:20 and r2a (08:15) has gone.
    let delayed = TripPrediction(
      entityID: "1", tripID: "r1a", routeID: "R1", directionID: nil, startDate: "", startTime: "",
      scheduleRelationship: "SCHEDULED", vehicleID: "bus1", timestamp: nil, delay: nil,
      stops: [("A", 1, 8, 10), ("B", 2, 8, 15), ("C", 3, 8, 20)].map { id, sequence, h, m in
        StopPrediction(
          stopID: id, sequence: sequence, arrival: monday(h, m), arrivalDelay: nil, departure: nil, departureDelay: nil,
          skipped: false)
      })
    let bus = VehicleSample(
      entityID: "1", vehicleID: "bus1", label: "", tripID: "r1a", routeID: "R1", directionID: nil, startDate: "",
      latitude: 43, longitude: -89.4, bearing: nil, speed: nil, timestamp: nil, currentStopSequence: nil, stopID: "")
    let journeys = planner.plan(
      from: stop("A"), to: stop("D"), departAt: monday(7, 55), predictions: [delayed], vehicles: [bus])
    #expect(!journeys.contains { $0.rides.map(\.tripID) == ["r1a", "r2a"] })
    // The journey that uses the late bus connects to the next R2 trip instead.
    #expect(journeys.contains { $0.rides.map(\.tripID) == ["r1a", "r2b"] } || journeys.contains { $0.rides.map(\.tripID) == ["r3"] })
  }

  @Test func liveRidesCarryTheirDelay() throws {
    let delayed = TripPrediction(
      entityID: "1", tripID: "r1a", routeID: "R1", directionID: nil, startDate: "", startTime: "",
      scheduleRelationship: "SCHEDULED", vehicleID: "bus1", timestamp: nil, delay: nil,
      stops: [("A", 1, 8, 10), ("B", 2, 8, 15), ("C", 3, 8, 20)].map { id, sequence, h, m in
        StopPrediction(
          stopID: id, sequence: sequence, arrival: monday(h, m), arrivalDelay: nil, departure: nil, departureDelay: nil,
          skipped: false)
      })
    let bus = VehicleSample(
      entityID: "1", vehicleID: "bus1", label: "", tripID: "r1a", routeID: "R1", directionID: nil, startDate: "",
      latitude: 43, longitude: -89.4, bearing: nil, speed: nil, timestamp: nil, currentStopSequence: nil, stopID: "")
    let journeys = planner.plan(
      from: stop("A"), to: stop("C"), departAt: monday(7, 55), predictions: [delayed], vehicles: [bus])
    let journey = try #require(journeys.first { $0.rides.first?.tripID == "r1a" })
    #expect(journey.usesLiveData)
    #expect(journey.rides[0].delay == 600)
    #expect(journey.arrival == monday(8, 20))
  }

  @Test func journeyDetails() throws {
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55))
    let journey = try #require(journeys.first { $0.transfers == 1 })
    #expect(journey.rides.count == 2)
    #expect(journey.duration == 25 * 60)
    // Arrive 08:10, leave 08:15.
    #expect(journey.transferBuffers == [300])
    #expect(journey.rides[0].stopCount == 2)
    #expect(journey.rides[1].stopCount == 1)
    #expect(!journey.usesLiveData)
  }

  @Test func polylinesFollowTheRouteShape() throws {
    let journeys = planner.plan(from: stop("A"), to: stop("C"), departAt: monday(7, 55))
    let journey = try #require(journeys.first)
    let lines = journey.polylines(schedule: schedule)
    #expect(lines.count == 1)
    #expect(lines[0].routeID == "R1")
    // Alpha, three shape points between, Charlie: more than a straight line.
    #expect(lines[0].coordinates.count >= 5)
    #expect(lines[0].coordinates.first == stop("A").coordinate)
    #expect(lines[0].coordinates.last == stop("C").coordinate)
  }

  @Test func arriveByFindsTheLatestBusThatIsStillInTime() throws {
    // To arrive at D by 09:30: r1b+r2b arrives 09:25 (leaves 09:00); r1a+r2a arrives 08:25; r3 arrives 09:00.
    let journeys = planner.plan(from: stop("A"), to: stop("D"), arriveBy: monday(9, 30), earliestStart: monday(7, 0))
    let best = try #require(journeys.first)
    #expect(best.arrival <= monday(9, 30))
    // The latest departure is the 09:00 bus; the journeys are ordered latest first.
    #expect(best.rides.first?.tripID == "r1b")
    #expect(best.arrival == monday(9, 25))
    #expect(zip(journeys, journeys.dropFirst()).allSatisfy { $0.departure >= $1.departure })
  }

  @Test func arriveByIgnoresJourneysThatAreTooLate() {
    let journeys = planner.plan(from: stop("A"), to: stop("D"), arriveBy: monday(8, 30), earliestStart: monday(7, 0))
    #expect(!journeys.isEmpty)
    #expect(journeys.allSatisfy { $0.arrival <= monday(8, 30) })
    #expect(!journeys.contains { $0.rides.first?.tripID == "r1b" })
  }

  @Test func arriveByWithNothingInTimeIsEmpty() {
    #expect(planner.plan(from: stop("A"), to: stop("D"), arriveBy: monday(7, 30), earliestStart: monday(7, 0)).isEmpty)
  }

  @Test func limitingRidesRemovesTransferJourneys() {
    var options = PlanOptions()
    options.maxRides = 1
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55), options: options)
    #expect(!journeys.isEmpty)
    #expect(journeys.allSatisfy { $0.transfers == 0 })
    #expect(journeys.first?.rides.first?.tripID == "r3")
  }

  @Test func slowerWalkingTakesLonger() throws {
    let origin = point(43.0, -89.4018, "Home")
    var slow = PlanOptions()
    slow.walkSpeed = 0.7
    let normal = try #require(planner.plan(from: origin, to: stop("C"), departAt: monday(7, 55)).first)
    let slower = try #require(planner.plan(from: origin, to: stop("C"), departAt: monday(7, 55), options: slow).first)
    // The walk is shifted to end when the bus leaves, so compare its length.
    func walkTime(_ journey: Journey) -> TimeInterval {
      guard case .walk(let walk) = journey.legs[0] else { return 0 }
      return walk.end.timeIntervalSince(walk.start)
    }
    #expect(walkTime(slower) > walkTime(normal) * 1.5)
  }

  @Test func longerRequiredTransferTimeRulesOutTightConnections() {
    // r1a reaches C at 08:10 and r2a leaves at 08:15: a 5-minute connection. Asking for 10 minutes rules it out.
    var options = PlanOptions()
    options.minTransferSeconds = 600
    let journeys = planner.plan(from: stop("A"), to: stop("D"), departAt: monday(7, 55), options: options)
    #expect(!journeys.contains { $0.rides.map(\.tripID) == ["r1a", "r2a"] })
  }
}
