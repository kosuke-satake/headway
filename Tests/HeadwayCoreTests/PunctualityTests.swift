import Foundation
import Testing

@testable import HeadwayCore

/// A straight route east along latitude 43.0 with four stops 1,000 m apart, scheduled at 08:00, 08:05, 08:10, 08:15.
private func makeLineSchedule() throws -> Schedule {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headway-punct-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  // 1,000 m of longitude at latitude 43 is about 0.012283 degrees.
  let step = 1_000 / (111_320 * cos(43.0 * .pi / 180))
  func lon(_ k: Double) -> Double { -89.40 + k * step }
  let files: [String: String] = [
    "agency.txt": "agency_id,agency_name,agency_timezone\n1,Test,America/Chicago\n",
    "routes.txt": "route_id,route_short_name,route_long_name,route_color,route_text_color,route_sort_order\nR,R,Line,FF0000,FFFFFF,1\n",
    "stops.txt": "stop_id,stop_code,stop_name,stop_lat,stop_lon\n"
      + (0..<4).map { "s\($0),\($0),Stop \($0),43.0,\(lon(Double($0)))" }.joined(separator: "\n") + "\n",
    "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id,shape_id,block_id\nt,R,wk,East,0,sh,b\n",
    "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nt,08:00:00,08:00:00,s0,1\nt,08:05:00,08:05:00,s1,2\nt,08:10:00,08:10:00,s2,3\nt,08:15:00,08:15:00,s3,4\n",
    "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n"
      + (0..<7).map { "sh,43.0,\(lon(Double($0) * 0.5)),\($0 + 1)" }.joined(separator: "\n") + "\n",
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nwk,1,1,1,1,1,0,0,20261001,20261231\n",
  ]
  for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
  return try Schedule.load(directory: dir)
}

@Suite struct ArrivalEstimatorTests {
  let schedule: Schedule
  let estimator: ArrivalEstimator
  let step: Double

  init() throws {
    schedule = try makeLineSchedule()
    estimator = ArrivalEstimator(schedule: schedule)
    step = 1_000 / (111_320 * cos(43.0 * .pi / 180))
  }

  private func monday(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: h, minute: m, second: s))!
  }

  /// Reports every `every` seconds from `from` to `to`, for a bus that is `delay` seconds late and moves at constant
  /// speed (1,000 m per 5 minutes).
  private func reports(delay: Double, every: Double = 30, from: Double = -120, to: Double = 15 * 60 + 300) -> [PositionSample] {
    var samples: [PositionSample] = []
    var t = from
    while t <= to {
      let along = (t - delay) / 300  // stops passed, in stop spacings
      samples.append(
        PositionSample(
          time: monday(8, 0).addingTimeInterval(t),
          coordinate: Coordinate(latitude: 43.0, longitude: -89.40 + along * step)))
      t += every
    }
    return samples
  }

  private func observe(_ samples: [PositionSample]) -> [ArrivalObservation] {
    estimator.observations(tripID: "t", serviceDate: ServiceDate(20_261_005), samples: samples)
  }

  @Test func measuresTheDelayAtEachStop() {
    let found = observe(reports(delay: 180))
    // The bus is 3 minutes late all the way. The first stop has no report before it on the line, so the other three
    // stops are observed.
    #expect(found.count == 3)
    for observation in found where observation.sequence >= 2 {
      #expect(abs(observation.delay - 180) < 8, "stop \(observation.sequence): \(observation.delay)")
    }
  }

  @Test func measuresEarlyBuses() {
    let found = observe(reports(delay: -90, from: -400))
    let second = found.first { $0.sequence == 3 }
    #expect(second != nil)
    #expect(abs((second?.delay ?? 0) + 90) < 8)
  }

  @Test func doesNotInterpolateAcrossALongGap() {
    // No reports between 08:06 and 08:12: the third stop (due 08:10) must not get an observation.
    let all = reports(delay: 0)
    let gap = all.filter { $0.time < monday(8, 6) || $0.time > monday(8, 12) }
    let found = observe(gap)
    #expect(!found.contains { $0.sequence == 3 })
    #expect(found.contains { $0.sequence == 4 })
  }

  @Test func ignoresReportsFarFromTheRoute() {
    var all = reports(delay: 60)
    // One report 500 m north of the line, in the middle of the trip.
    all.append(PositionSample(time: monday(8, 7, 20), coordinate: Coordinate(latitude: 43.0045, longitude: -89.40 + 1.5 * step)))
    let found = observe(all)
    for observation in found where observation.sequence >= 2 { #expect(abs(observation.delay - 60) < 8) }
  }

  @Test func ignoresBackwardsGPSJumps() {
    var all = reports(delay: 0)
    // A report that puts the bus 300 m back at 08:07:30.
    all.append(PositionSample(time: monday(8, 7, 30), coordinate: Coordinate(latitude: 43.0, longitude: -89.40 + 0.9 * step)))
    let found = observe(all)
    for observation in found where observation.sequence >= 2 { #expect(abs(observation.delay) < 10) }
  }

  @Test func needsAtLeastTwoReports() {
    #expect(observe([reports(delay: 0)[0]]).isEmpty)
    #expect(observe([]).isEmpty)
  }

  @Test func tripWithoutShapeGivesNothing() {
    #expect(estimator.observations(tripID: "missing", serviceDate: ServiceDate(20_261_005), samples: reports(delay: 0)).isEmpty)
  }
}

@Suite struct PunctualityTableTests {
  private let zone = TimeZone(identifier: "America/Chicago")!

  private func monday(_ h: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: h, minute: 30))!
  }

  @Test func cellFromDelays() throws {
    // 20 buses: 4 early (-120 s), 12 on time (0), 4 late (600 s).
    let delays = Array(repeating: -120.0, count: 4) + Array(repeating: 0.0, count: 12) + Array(repeating: 600.0, count: 4)
    let cell = try #require(PunctualityCell(delays: delays))
    #expect(cell.n == 20)
    #expect(cell.early == 4 && cell.late == 4 && cell.onTime == 12)
    #expect(cell.earlyShare == 0.2 && cell.onTimeShare == 0.6)
    #expect(cell.p50 == 0 && cell.p10 == -120 && cell.p90 == 600)
    #expect(PunctualityCell(delays: []) == nil)
  }

  @Test func thresholdsAreExclusive() throws {
    let cell = try #require(PunctualityCell(delays: [-60, 300, -61, 301]))
    #expect(cell.early == 1 && cell.late == 1)
  }

  private func table() -> PunctualityTable {
    PunctualityTable(
      generated: Date(timeIntervalSince1970: 1_790_000_000), firstDay: "2026-10-03", lastDay: "2026-10-30", days: 20,
      observations: 1000,
      routeCells: [
        PunctualityTable.routeKey(route: "A", dayType: .weekday, hour: 17): PunctualityCell(n: 200, early: 10, late: 40, p10: -30, p50: 60, p90: 400),
        PunctualityTable.routeKey(route: "A", dayType: .weekday, hour: 18): PunctualityCell(n: 100, early: 5, late: 10, p10: -20, p50: 30, p90: 200),
        PunctualityTable.routeKey(route: "B", dayType: .weekday, hour: 17): PunctualityCell(n: 5, early: 0, late: 0, p10: 0, p50: 0, p90: 0),
      ],
      stopCells: [
        PunctualityTable.stopKey(route: "A", stop: "s1", dayType: .weekday, hour: 17): PunctualityCell(n: 20, early: 8, late: 2, p10: -90, p50: -30, p90: 100),
        PunctualityTable.stopKey(route: "A", stop: "s2", dayType: .weekday, hour: 17): PunctualityCell(n: 4, early: 0, late: 0, p10: 0, p50: 0, p90: 0),
      ])
  }

  @Test func prefersTheStopThenFallsBackToTheRoute() throws {
    let table = table()
    let atStop = try #require(table.match(route: "A", stop: "s1", at: monday(17), in: zone))
    #expect(atStop.scope == .stop && atStop.cell.n == 20)
    // s2 has only 4 observations: use the route at the same hour.
    let fallback = try #require(table.match(route: "A", stop: "s2", at: monday(17), in: zone))
    #expect(fallback.scope == .route && fallback.cell.n == 200)
    // No stop given.
    #expect(try #require(table.match(route: "A", stop: nil, at: monday(17), in: zone)).scope == .route)
  }

  @Test func usesANeighbouringHourWhenTheHourIsMissing() throws {
    // 19:30 has no cell, 18 is the neighbour with enough data.
    let match = try #require(table().match(route: "A", stop: nil, at: monday(19), in: zone))
    #expect(match.hour == 18)
  }

  @Test func staysSilentWithoutEnoughData() {
    #expect(table().match(route: "B", stop: nil, at: monday(17), in: zone) == nil)  // only 5 observations
    #expect(table().match(route: "Z", stop: nil, at: monday(17), in: zone) == nil)
    #expect(table().match(route: "A", stop: nil, at: monday(3), in: zone) == nil)
  }

  @Test func dayTypesAreKeptApart() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 17, minute: 30))!
    #expect(table().match(route: "A", stop: nil, at: saturday, in: zone) == nil)
    #expect(DayType(ServiceDate(20_261_003), in: zone) == .saturday)
    #expect(DayType(ServiceDate(20_261_004), in: zone) == .sunday)
    #expect(DayType(ServiceDate(20_261_005), in: zone) == .weekday)
  }

  @Test func roundTripsThroughJSON() throws {
    let original = table()
    let decoded = try PunctualityTable.decode(try original.encoded())
    #expect(decoded.routeCells == original.routeCells)
    #expect(decoded.stopCells == original.stopCells)
    #expect(decoded.days == 20)
    #expect(decoded.generated == original.generated)
  }

  @Test func predictionWindowUsesTheHorizonBin() throws {
    var table = PunctualityTable.empty
    table.predictionBins = [
      PredictionBin(horizon: 120, n: 500, q05: -40, q50: 0, q95: 50),
      PredictionBin(horizon: 300, n: 400, q05: -90, q50: 5, q95: 100),
      PredictionBin(horizon: 1800, n: 50, q05: -300, q50: 0, q95: 300),
    ]
    // Predicted 1 minute ahead: the bus has come between 50 s earlier and 40 s later than predicted.
    let near = try #require(table.window(predictedIn: 60))
    #expect(near.earliest == -50 && near.latest == 40)
    let mid = try #require(table.window(predictedIn: 200))
    #expect(mid.earliest == -100 && mid.latest == 90)
    // The 30-minute bin has only 50 observations: not shown.
    #expect(table.window(predictedIn: 1_000) == nil)
    #expect(PunctualityTable.empty.window(predictedIn: 60) == nil)
  }

  @Test func oldFilesWithoutPredictionBinsStillDecode() throws {
    let json = #"{"generated":"2026-10-04T00:00:00Z","firstDay":"2026-10-03","lastDay":"2026-10-03","days":1,"observations":0,"routeCells":{},"stopCells":{}}"#
    let table = try PunctualityTable.decode(Data(json.utf8))
    #expect(table.predictionBins.isEmpty)
  }
}
