import Foundation
import HeadwayCore

/// A route can have several variants in one direction (for example "2-VERONA" and "2-EPIC CAMPUS"). Does the variant a
/// bus is assigned to in the feed match the line it actually drives on?
struct Variants {
  let schedule: Schedule
  let recordings: Recordings

  func markdown(route: String) throws -> String {
    // Distinct shapes of this route with the headsign of the trips that use them.
    var headsignOfShape: [String: String] = [:]
    var directionOfShape: [String: Int] = [:]
    for trip in schedule.trips.values where trip.routeID == route {
      headsignOfShape[trip.shapeID] = trip.headsign
      directionOfShape[trip.shapeID] = trip.directionID
    }
    var matrix: [String: [String: Int]] = [:]  // assigned headsign -> closest headsign -> count
    var samples = 0
    var lastTaken = Date.distantPast
    for file in recordings.files(of: .vehicles) where file.recordedAt.timeIntervalSince(lastTaken) >= 20 {
      lastTaken = file.recordedAt
      let snapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
      for vehicle in snapshot.vehicles where vehicle.routeID == route {
        guard let trip = schedule.trips[vehicle.tripID], let assigned = headsignOfShape[trip.shapeID] else { continue }
        if let speed = vehicle.speed, speed < 0.5 { continue }
        let point = Coordinate(latitude: vehicle.latitude, longitude: vehicle.longitude)
        // Closest line among this route's shapes in the same direction.
        var best: (headsign: String, distance: Double)?
        for (shapeID, headsign) in headsignOfShape where directionOfShape[shapeID] == trip.directionID {
          guard let line = schedule.shapes[shapeID] else { continue }
          let d = Geometry.distance(from: point, toLine: line)
          if best == nil || d < best!.distance - 1 { best = (headsign, d) }
        }
        guard let best, best.distance < 40 else { continue }
        // Only count places where the variants really differ: the closest line is within 40 m and every line of a
        // different headsign is at least 120 m away. On the shared trunk of a route nothing can be told.
        var otherClosest = Double.infinity
        for (shapeID, headsign) in headsignOfShape where directionOfShape[shapeID] == trip.directionID && headsign != best.headsign {
          if let line = schedule.shapes[shapeID] { otherClosest = min(otherClosest, Geometry.distance(from: point, toLine: line)) }
        }
        guard otherClosest >= 120 else { continue }
        samples += 1
        matrix[assigned, default: [:]][best.headsign, default: 0] += 1
      }
    }
    var out = "# Route \(route): assigned variant vs the line the bus is on\n\n\(samples) moving-bus samples where one variant's line is within 40 m and all other variants are 120 m or more away. Rows: the headsign of the trip the feed says the bus is on. Columns: the variant whose line the bus is on.\n\n"
    let columns = Set(matrix.values.flatMap { $0.keys }).sorted()
    out += "| assigned \\ closest | " + columns.joined(separator: " | ") + " |\n|---|" + columns.map { _ in "---:" }.joined() + "|\n"
    for (assigned, row) in matrix.sorted(by: { $0.key < $1.key }) {
      out += "| \(assigned) | " + columns.map { String(row[$0] ?? 0) }.joined(separator: " | ") + " |\n"
    }
    return out
  }
}
