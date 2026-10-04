import Foundation
import HeadwayCore

/// How "live" is the vehicle feed, really? Looks at three delays between a bus and the screen:
/// the bus's own report interval, the server's refresh interval, and how old a position already is when we fetch it.
struct Freshness {
  let recordings: Recordings

  func markdown() throws -> String {
    var feedStamps: [Date] = []          // distinct feed header timestamps, in order
    var ageAtFetch: [Double] = []        // fetch time - feed header timestamp
    var positionAge: [Double] = []       // feed header timestamp - vehicle position timestamp
    var lastStamp: [String: Date] = [:]  // vehicle -> last distinct position timestamp
    var reportIntervals: [Double] = []
    var stale = 0, moving = 0
    var previousPosition: [String: (Double, Double)] = [:]
    var fetches = 0

    for file in recordings.files(of: .vehicles) {
      let snapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
      guard let header = snapshot.feedTimestamp else { continue }
      fetches += 1
      if feedStamps.last != header { feedStamps.append(header) }
      ageAtFetch.append(file.recordedAt.timeIntervalSince(header))
      for vehicle in snapshot.vehicles {
        guard let stamp = vehicle.timestamp else { continue }
        positionAge.append(header.timeIntervalSince(stamp))
        if let last = lastStamp[vehicle.id], stamp > last { reportIntervals.append(stamp.timeIntervalSince(last)) }
        if lastStamp[vehicle.id] == nil || stamp > lastStamp[vehicle.id]! { lastStamp[vehicle.id] = stamp }
        // A bus that is moving but whose coordinates did not change since the last fetch is a stale position.
        if let speed = vehicle.speed, speed > 2 {
          moving += 1
          if let previous = previousPosition[vehicle.id], previous == (vehicle.latitude, vehicle.longitude) { stale += 1 }
        }
        previousPosition[vehicle.id] = (vehicle.latitude, vehicle.longitude)
      }
    }
    func pct(_ values: [Double], _ p: Double) -> String {
      guard !values.isEmpty else { return "-" }
      let sorted = values.sorted()
      return String(format: "%.0f", sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))])
    }
    let feedIntervals = zip(feedStamps.dropFirst(), feedStamps).map { $0.timeIntervalSince($1) }
    var out = "# How live is the vehicle feed?\n\n\(fetches) fetches.\n\n"
    out += "| measure | median s | p90 s | max s |\n|---|---:|---:|---:|\n"
    out += "| server refresh interval (feed timestamp changes every) | \(pct(feedIntervals, 0.5)) | \(pct(feedIntervals, 0.9)) | \(pct(feedIntervals, 1)) |\n"
    out += "| age of the feed when fetched (fetch time - feed timestamp) | \(pct(ageAtFetch, 0.5)) | \(pct(ageAtFetch, 0.9)) | \(pct(ageAtFetch, 1)) |\n"
    out += "| age of a bus position inside the feed (feed timestamp - position timestamp) | \(pct(positionAge, 0.5)) | \(pct(positionAge, 0.9)) | \(pct(positionAge, 1)) |\n"
    out += "| time between two new reports from the same bus | \(pct(reportIntervals, 0.5)) | \(pct(reportIntervals, 0.9)) | \(pct(reportIntervals, 1)) |\n\n"
    let total = zip(ageAtFetch, positionAge.isEmpty ? [] : positionAge).map { $0 + $1 }
    _ = total
    out += "Moving buses (speed over 2 m/s) whose coordinates were identical to the previous fetch: \(stale) of \(moving).\n"
    return out
  }
}
