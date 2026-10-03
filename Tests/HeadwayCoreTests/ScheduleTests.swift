import Foundation
import Testing

@testable import HeadwayCore

/// A tiny feed written to a temporary folder, so the tests do not depend on downloaded data.
func makeFeed() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headway-feed-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let files: [String: String] = [
    "agency.txt": "agency_id,agency_name,agency_timezone\n1,Test,America/Chicago\n",
    "routes.txt": "route_id,route_short_name,route_long_name,route_color,route_text_color,route_sort_order\nA,A,Route A,FF0000,FFFFFF,1\n",
    "stops.txt": "stop_id,stop_code,stop_name,stop_lat,stop_lon\ns1,1,First,43.07,-89.40\ns2,2,Second,43.08,-89.39\n",
    "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id,shape_id,block_id\nt1,A,wk,East,0,shp1,b1\nt2,A,wk,East,0,shp1,b2\n",
    // t2 runs past midnight: 23:50 to 24:20 of the service day.
    "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nt1,08:00:00,08:00:00,s1,1\nt1,08:10:00,08:10:00,s2,2\nt2,23:50:00,23:50:00,s1,1\nt2,24:20:00,24:20:00,s2,2\n",
    "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nshp1,43.08,-89.39,2\nshp1,43.07,-89.40,1\n",
    // 2026-10-05 is a Monday.
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nwk,1,1,1,1,1,0,0,20261001,20261231\n",
    "calendar_dates.txt": "service_id,date,exception_type\nwk,20261012,2\nwk,20261010,1\n",
    "feed_info.txt": "feed_version,feed_start_date,feed_end_date\nv1,20261001,20261231\n",
  ]
  for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
  return dir
}

@Suite struct ScheduleTests {
  let schedule: Schedule

  init() throws { schedule = try Schedule.load(directory: try makeFeed()) }

  private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = schedule.timeZone
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
  }

  @Test func loadsEverything() {
    #expect(schedule.routes["A"]?.colorHex == "FF0000")
    #expect(schedule.stops.count == 2)
    #expect(schedule.trips.count == 2)
    #expect(schedule.stopTimes["t2"]?.last?.arrival == 24 * 3600 + 20 * 60)
    #expect(schedule.feedVersion == "v1")
    #expect(schedule.timeZone.identifier == "America/Chicago")
  }

  @Test func shapePointsAreOrderedBySequence() {
    #expect(schedule.shapes["shp1"]?.first == Coordinate(latitude: 43.07, longitude: -89.40))
  }

  @Test func serviceFollowsWeekdayAndExceptions() {
    #expect(schedule.activeServiceIDs(on: ServiceDate(20_261_005)) == ["wk"])  // Monday
    #expect(schedule.activeServiceIDs(on: ServiceDate(20_261_004)).isEmpty)  // Sunday
    #expect(schedule.activeServiceIDs(on: ServiceDate(20_261_010)) == ["wk"])  // Saturday, added
    #expect(schedule.activeServiceIDs(on: ServiceDate(20_261_012)).isEmpty)  // Monday, removed
  }

  @Test func findsTripsInProgress() {
    let morning = schedule.scheduledTrips(at: date(2026, 10, 5, 8, 5)).map(\.trip.id)
    #expect(morning == ["t1"])
    #expect(schedule.scheduledTrips(at: date(2026, 10, 5, 12, 0)).isEmpty)
  }

  @Test func tripPastMidnightBelongsToThePreviousServiceDate() {
    // Tuesday 00:10 is still inside Monday's 23:50-24:20 trip.
    let found = schedule.scheduledTrips(at: date(2026, 10, 6, 0, 10))
    #expect(found.map(\.trip.id) == ["t2"])
    #expect(found.first?.serviceDate == ServiceDate(20_261_005))
  }

  @Test func insetKeepsTripsThatAreJustStarting() {
    let atStart = date(2026, 10, 5, 8, 0)
    #expect(schedule.scheduledTrips(at: atStart).count == 1)
    #expect(schedule.scheduledTrips(at: atStart, inset: 120).isEmpty)
  }

  @Test func scheduledArrivalUsesServiceDateMidnight() {
    let arrival = schedule.scheduledArrival(tripID: "t1", sequence: 2, on: ServiceDate(20_261_005))
    #expect(arrival == date(2026, 10, 5, 8, 10))
  }
}

/// Runs against the real feed when `tools/record_feeds.py` has downloaded it; skipped otherwise.
@Suite struct RealFeedTests {
  static let zip: URL? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let feeds = root.appendingPathComponent("data/feeds")
    let days = (try? FileManager.default.contentsOfDirectory(at: feeds, includingPropertiesForKeys: nil)) ?? []
    return days.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("mmt_gtfs.zip") }
      .last { FileManager.default.fileExists(atPath: $0.path) }
  }()

  @Test(.enabled(if: RealFeedTests.zip != nil)) func loadsMadisonFeed() throws {
    let schedule = try Schedule.load(zipAt: try #require(Self.zip))
    #expect(schedule.routes.count > 20)
    #expect(schedule.stops.count > 1_000)
    #expect(schedule.trips.count > 10_000)
    #expect(schedule.timeZone.secondsFromGMT() != 0)
    // Every trip has stop times, and every stop time refers to a known stop.
    #expect(schedule.trips.keys.allSatisfy { schedule.stopTimes[$0] != nil })
    #expect(schedule.stopTimes.values.joined().allSatisfy { schedule.stops[$0.stopID] != nil })
  }
}
