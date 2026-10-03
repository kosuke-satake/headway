import Foundation
import HeadwayCore

// Usage:
//   feedanalysis schedule <mmt_gtfs.zip>
//   feedanalysis sample   <recording-dir>
//   feedanalysis report   <recording-dir>

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  fail("usage: feedanalysis schedule <zip> | sample <dir> | report <dir>")
}
let directory = URL(fileURLWithPath: arguments[2])

switch arguments[1] {
case "schedule":
  let clock = ContinuousClock()
  var schedule: Schedule!
  let elapsed = try clock.measure { schedule = try Schedule.load(zipAt: directory) }
  let stopTimeCount = schedule.stopTimes.values.reduce(0) { $0 + $1.count }
  print("loaded in \(elapsed)")
  print("feed \(schedule.feedVersion), \(schedule.feedStart?.value ?? 0)...\(schedule.feedEnd?.value ?? 0), zone \(schedule.timeZone.identifier)")
  print("routes \(schedule.routes.count), stops \(schedule.stops.count), trips \(schedule.trips.count)")
  print("stop times \(stopTimeCount), shapes \(schedule.shapes.count), services \(schedule.calendars.count)")
  let now = Date()
  let running = schedule.scheduledTrips(at: now)
  print("scheduled trips running now: \(running.count)")

case "sample":
  let recordings = try Recordings(directory: directory)
  for feed in RealtimeFeed.allCases {
    guard let last = recordings.files(of: feed).last else { continue }
    let snapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: last.url)))
    print("== \(feed.rawValue)  \(last.url.lastPathComponent)")
    print("feed timestamp \(snapshot.feedTimestamp.map { "\($0)" } ?? "none"), vehicles \(snapshot.vehicles.count), predictions \(snapshot.predictions.count), alerts \(snapshot.alerts.count)")
    for v in snapshot.vehicles.prefix(3) { print(v) }
    for p in snapshot.predictions.prefix(2) { print(p) }
    for a in snapshot.alerts.prefix(2) { print(a) }
  }

case "shape":
  // How completely are the optional fields filled in? Uses the latest snapshot of each feed.
  let recordings = try Recordings(directory: directory)
  if let file = recordings.files(of: .vehicles).last {
    let s = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
    let v = s.vehicles
    print("vehicles: \(v.count)  tripID set \(v.filter { !$0.tripID.isEmpty }.count)  routeID set \(v.filter { !$0.routeID.isEmpty }.count)  vehicleID set \(v.filter { !$0.vehicleID.isEmpty }.count)  stopID set \(v.filter { !$0.stopID.isEmpty }.count)  currentStopSequence set \(v.filter { $0.currentStopSequence != nil }.count)")
    let ages = v.compactMap { x in x.timestamp.map { (s.feedTimestamp ?? $0).timeIntervalSince($0) } }
    print("  position age vs feed timestamp (s): min \(ages.min() ?? 0) max \(ages.max() ?? 0)")
  }
  if let file = recordings.files(of: .trips).last {
    let s = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
    let p = s.predictions
    print("predictions: \(p.count)  tripID set \(p.filter { !$0.tripID.isEmpty }.count)  vehicleID set \(p.filter { !$0.vehicleID.isEmpty }.count)  delay set \(p.filter { $0.delay != nil }.count)  startTime set \(p.filter { !$0.startTime.isEmpty }.count)  startDate set \(p.filter { !$0.startDate.isEmpty }.count)  directionID set \(p.filter { $0.directionID != nil }.count)")
    let relationships = Dictionary(grouping: p, by: \.scheduleRelationship).mapValues(\.count)
    print("  schedule relationship: \(relationships)")
    let stopUpdates = p.flatMap(\.stops)
    print("  stop updates: \(stopUpdates.count)  with arrival delay \(stopUpdates.filter { $0.arrivalDelay != nil }.count)  with departure delay \(stopUpdates.filter { $0.departureDelay != nil }.count)  skipped \(stopUpdates.filter(\.skipped).count)")
    let now = s.feedTimestamp ?? Date()
    let started = p.filter { ($0.stops.compactMap { $0.arrival ?? $0.departure }.min() ?? now) < now }
    print("  predictions whose earliest stop time is already past: \(started.count)")
    for q in started.prefix(2) { print("   ", q.routeID, q.stops.prefix(3).map { "\($0.stopID) seq \($0.sequence ?? -1) arr \($0.arrival.map { "\($0)" } ?? "-") dly \($0.arrivalDelay.map(String.init) ?? "-")" }) }
  }

case "report":
  // `feedanalysis report <recording-dir>`; the schedule is read from <recording-dir>/mmt_gtfs.zip.
  let zip = directory.appendingPathComponent("mmt_gtfs.zip")
  let schedule = try Schedule.load(zipAt: zip)
  let report = Report(schedule: schedule, recordings: try Recordings(directory: directory))
  print(report.markdown(try report.run()))

default:
  fail("unknown command \(arguments[1])")
}
