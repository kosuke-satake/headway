import Foundation
import HeadwayCore

/// How far do buses stray from the route line the timetable says they follow?
///
/// A bus on a detour is far from its shape for as long as the detour lasts, so a consistently large distance on a
/// route that has an alert tells us whether a detour path could be recovered from live positions.
struct Deviation {
  let schedule: Schedule
  let recordings: Recordings

  func markdown() throws -> String {
    var perRoute: [String: [Double]] = [:]
    var lastTaken = Date.distantPast
    for file in recordings.files(of: .vehicles) where file.recordedAt.timeIntervalSince(lastTaken) >= 60 {
      lastTaken = file.recordedAt
      let snapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
      for vehicle in snapshot.vehicles {
        guard let trip = schedule.trips[vehicle.tripID], let shape = schedule.shapes[trip.shapeID], shape.count > 1 else { continue }
        // A bus waiting at a terminal is not on a detour: ignore standing buses.
        if let speed = vehicle.speed, speed < 0.5 { continue }
        perRoute[vehicle.routeID, default: []].append(
          Geometry.distance(from: Coordinate(latitude: vehicle.latitude, longitude: vehicle.longitude), toLine: shape))
      }
    }
    var out = "# Distance of moving buses from their route line\n\n| route | samples | median m | share over 100 m | share over 250 m |\n|---|---:|---:|---:|---:|\n"
    func share(_ values: [Double], _ limit: Double) -> String {
      String(format: "%.1f%%", 100 * Double(values.filter { $0 > limit }.count) / Double(max(1, values.count)))
    }
    for (route, values) in perRoute.sorted(by: { $0.value.filter { $0 > 100 }.count * 1000 / max(1, $0.value.count) > $1.value.filter { $0 > 100 }.count * 1000 / max(1, $1.value.count) }) {
      let sorted = values.sorted()
      out += "| \(route) | \(values.count) | \(String(format: "%.0f", sorted[sorted.count / 2])) | \(share(values, 100)) | \(share(values, 250)) |\n"
    }
    return out
  }
}
