import Foundation
import HeadwayCore

/// Compares recorded GTFS-Realtime snapshots with the static schedule.
///
/// Questions answered:
/// 1. Ghost trips: scheduled and in progress, but no bus reports a position for them.
/// 2. Buses that report a position for a trip the schedule does not say is running.
/// 3. How stale are positions?
/// 4. How far do predicted arrivals drift from the timetable?
struct Report {
  let schedule: Schedule
  let recordings: Recordings

  struct Sample {
    let time: Date
    var scheduled = 0
    var matched = 0
    var ghostNoBus = 0  // no vehicle position and no bus assigned in the predictions either
    var ghostAssigned = 0  // a bus is assigned in the predictions but sends no position
    var vehicles = 0
    var vehiclesNoTrip = 0
    var vehiclesUnknownTrip = 0
    var vehiclesUpcoming = 0
    var vehiclesEnded = 0
    var vehiclesOffSchedule = 0
    var stale60 = 0
    var stale120 = 0
    var ghostRoutes: [String] = []
    var scheduledRoutes: [String] = []
    var delays: [(route: String, seconds: Double)] = []
  }

  func run(sampleEvery interval: TimeInterval = 60) throws -> [Sample] {
    let vehicleFiles = recordings.files(of: .vehicles)
    let tripFiles = recordings.files(of: .trips)
    var samples: [Sample] = []
    var vehicleCursor = 0
    var lastTaken = Date.distantPast

    for tripFile in tripFiles {
      guard tripFile.recordedAt.timeIntervalSince(lastTaken) >= interval else { continue }
      // Nearest vehicle snapshot in time.
      while vehicleCursor + 1 < vehicleFiles.count,
        abs(vehicleFiles[vehicleCursor + 1].recordedAt.timeIntervalSince(tripFile.recordedAt))
          <= abs(vehicleFiles[vehicleCursor].recordedAt.timeIntervalSince(tripFile.recordedAt))
      {
        vehicleCursor += 1
      }
      guard vehicleCursor < vehicleFiles.count,
        abs(vehicleFiles[vehicleCursor].recordedAt.timeIntervalSince(tripFile.recordedAt)) < 30
      else { continue }
      lastTaken = tripFile.recordedAt

      let vehicleSnapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: vehicleFiles[vehicleCursor].url)))
      let tripSnapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: tripFile.url)))
      samples.append(analyse(at: tripFile.recordedAt, vehicles: vehicleSnapshot, trips: tripSnapshot))
    }
    return samples
  }

  private func analyse(at time: Date, vehicles: RealtimeSnapshot, trips: RealtimeSnapshot) -> Sample {
    var sample = Sample(time: time)
    // Trips well inside their scheduled span: a two-minute margin avoids counting trips that are just starting.
    let running = schedule.scheduledTrips(at: time, inset: 120)
    let runningByID = Dictionary(running.map { ($0.trip.id, $0) }, uniquingKeysWith: { first, _ in first })
    sample.scheduled = running.count
    sample.scheduledRoutes = running.map(\.trip.routeID)

    let positionedTrips = Set(vehicles.vehicles.map(\.tripID).filter { !$0.isEmpty })
    let positionedVehicles = Set(vehicles.vehicles.map(\.vehicleID))
    var predictionByTrip: [String: TripPrediction] = [:]
    for p in trips.predictions where !p.tripID.isEmpty { predictionByTrip[p.tripID] = p }

    for (trip, _) in running {
      if positionedTrips.contains(trip.id) {
        sample.matched += 1
      } else if let p = predictionByTrip[trip.id], !p.vehicleID.isEmpty, !positionedVehicles.contains(p.vehicleID) {
        sample.ghostAssigned += 1
        sample.ghostRoutes.append(trip.routeID)
      } else {
        sample.ghostNoBus += 1
        sample.ghostRoutes.append(trip.routeID)
      }
    }

    sample.vehicles = vehicles.vehicles.count
    let reference = vehicles.feedTimestamp ?? time
    for v in vehicles.vehicles {
      if let at = v.timestamp {
        let age = reference.timeIntervalSince(at)
        if age > 60 { sample.stale60 += 1 }
        if age > 120 { sample.stale120 += 1 }
      }
      if v.tripID.isEmpty {
        sample.vehiclesNoTrip += 1
      } else if runningByID[v.tripID] == nil {
        // Not inside its span: is it just about to start, just finished, or unknown to the schedule?
        guard let times = schedule.stopTimes[v.tripID], let first = times.first, let last = times.last else {
          sample.vehiclesUnknownTrip += 1
          continue
        }
        let candidates = [ServiceDate(time, in: schedule.timeZone), ServiceDate(time, in: schedule.timeZone).adding(days: -1, in: schedule.timeZone)]
        let nearest = candidates.compactMap { date -> (before: Int, after: Int)? in
          guard schedule.activeServiceIDs(on: date).contains(schedule.trips[v.tripID]?.serviceID ?? "") else { return nil }
          let seconds = Int(time.timeIntervalSince(date.midnight(in: schedule.timeZone)))
          return (first.departure - seconds, seconds - last.arrival)
        }
        if nearest.contains(where: { $0.before > 0 && $0.before <= 900 }) {
          sample.vehiclesUpcoming += 1
        } else if nearest.contains(where: { $0.after > 0 && $0.after <= 900 }) {
          sample.vehiclesEnded += 1
        } else {
          sample.vehiclesOffSchedule += 1
        }
      }
    }

    // Predicted arrival at the first stop that still lies ahead, compared with the timetable.
    for (trip, date) in running {
      guard let p = predictionByTrip[trip.id] else { continue }
      guard let update = p.stops.first(where: { ($0.arrival ?? $0.departure).map { $0 >= time } ?? false }),
        let sequence = update.sequence, let predicted = update.arrival ?? update.departure,
        let scheduled = schedule.scheduledArrival(tripID: trip.id, sequence: sequence, on: date)
      else { continue }
      sample.delays.append((trip.routeID, predicted.timeIntervalSince(scheduled)))
    }
    return sample
  }

  // MARK: Output

  func markdown(_ samples: [Sample]) -> String {
    guard let first = samples.first, let last = samples.last else { return "No samples.\n" }
    func pct(_ part: Int, _ whole: Int) -> String { whole == 0 ? "-" : String(format: "%.1f%%", 100 * Double(part) / Double(whole)) }
    func percentile(_ values: [Double], _ p: Double) -> Double {
      guard !values.isEmpty else { return .nan }
      let sorted = values.sorted()
      return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }

    let scheduled = samples.reduce(0) { $0 + $1.scheduled }
    let matched = samples.reduce(0) { $0 + $1.matched }
    let ghostAssigned = samples.reduce(0) { $0 + $1.ghostAssigned }
    let ghostNoBus = samples.reduce(0) { $0 + $1.ghostNoBus }
    let vehicles = samples.reduce(0) { $0 + $1.vehicles }

    var out = "# Feed analysis\n\n"
    out += "Samples: \(samples.count), \(first.time) to \(last.time). Schedule \(schedule.feedVersion).\n\n"
    out += "A sample is one minute. Counts below are summed over samples (trip-minutes / bus-minutes).\n\n"

    out += "## 1. Scheduled trips without a reported position\n\n"
    out += "| | trip-minutes | share |\n|---|---:|---:|\n"
    out += "| scheduled and in progress | \(scheduled) | 100% |\n"
    out += "| with a bus position | \(matched) | \(pct(matched, scheduled)) |\n"
    out += "| no position, but a bus is assigned in the predictions | \(ghostAssigned) | \(pct(ghostAssigned, scheduled)) |\n"
    out += "| no position and no assigned bus | \(ghostNoBus) | \(pct(ghostNoBus, scheduled)) |\n\n"

    out += "### By route\n\n| route | trip-minutes | without position |\n|---|---:|---:|\n"
    var totals: [String: Int] = [:], ghosts: [String: Int] = [:]
    for s in samples {
      for r in s.scheduledRoutes { totals[r, default: 0] += 1 }
      for r in s.ghostRoutes { ghosts[r, default: 0] += 1 }
    }
    func ghostRate(_ route: String) -> Double { Double(ghosts[route] ?? 0) / Double(max(1, totals[route] ?? 1)) }
    for route in totals.keys.sorted(by: { ghostRate($0) > ghostRate($1) }) {
      out += "| \(schedule.routes[route]?.shortName ?? route) | \(totals[route] ?? 0) | \(pct(ghosts[route] ?? 0, totals[route] ?? 0)) |\n"
    }

    out += "\n## 2. Buses reporting positions\n\n| | bus-minutes | share |\n|---|---:|---:|\n"
    out += "| all buses in the position feed | \(vehicles) | 100% |\n"
    out += "| no trip id | \(samples.reduce(0) { $0 + $1.vehiclesNoTrip }) | \(pct(samples.reduce(0) { $0 + $1.vehiclesNoTrip }, vehicles)) |\n"
    out += "| trip id unknown to the schedule | \(samples.reduce(0) { $0 + $1.vehiclesUnknownTrip }) | \(pct(samples.reduce(0) { $0 + $1.vehiclesUnknownTrip }, vehicles)) |\n"
    out += "| trip starts within 15 min (waiting at the terminal) | \(samples.reduce(0) { $0 + $1.vehiclesUpcoming }) | \(pct(samples.reduce(0) { $0 + $1.vehiclesUpcoming }, vehicles)) |\n"
    out += "| trip ended within 15 min | \(samples.reduce(0) { $0 + $1.vehiclesEnded }) | \(pct(samples.reduce(0) { $0 + $1.vehiclesEnded }, vehicles)) |\n"
    out += "| trip far from its scheduled time | \(samples.reduce(0) { $0 + $1.vehiclesOffSchedule }) | \(pct(samples.reduce(0) { $0 + $1.vehiclesOffSchedule }, vehicles)) |\n\n"

    out += "## 3. Position staleness (position time vs feed time)\n\n"
    out += "- older than 60 s: \(pct(samples.reduce(0) { $0 + $1.stale60 }, vehicles))\n"
    out += "- older than 120 s: \(pct(samples.reduce(0) { $0 + $1.stale120 }, vehicles))\n\n"

    let delays = samples.flatMap { $0.delays.map(\.seconds) }
    out += "## 4. Predicted arrival at the next stop vs timetable\n\n"
    out += "Positive means later than the timetable. \(delays.count) observations.\n\n"
    out += "| percentile | seconds |\n|---|---:|\n"
    for p in [0.05, 0.25, 0.5, 0.75, 0.95] {
      out += "| p\(Int(p * 100)) | \(String(format: "%.0f", percentile(delays, p))) |\n"
    }
    out += "\n- more than 5 min late: \(pct(delays.filter { $0 > 300 }.count, delays.count))\n"
    out += "- more than 5 min early: \(pct(delays.filter { $0 < -300 }.count, delays.count))\n"
    return out
  }
}
