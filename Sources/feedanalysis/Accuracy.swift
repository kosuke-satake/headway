import Foundation
import HeadwayCore

/// Are the live predictions better than the timetable? Compares each predicted arrival with the arrival observed
/// afterwards, grouped by how far ahead the prediction was made.
struct Accuracy {
  let schedule: Schedule
  let recordings: Recordings
  let store: ObservationStore

  struct Actual { let actual: Double; let scheduled: Double }

  static let horizons: [(name: String, range: Range<Double>)] = [
    ("0-2 min ahead", 0..<120), ("2-5 min", 120..<300), ("5-10 min", 300..<600), ("10-20 min", 600..<1200), ("20-30 min", 1200..<1800),
  ]

  /// Errors (predicted - observed) of live predictions and of the timetable, per horizon bin.
  func errors() throws -> (prediction: [[Double]], schedule: [[Double]], snapshots: Int) {
    // Observed arrivals: (trip, service day, sequence) -> actual and scheduled instants.
    var actuals: [String: Actual] = [:]
    try store.rows("SELECT day, trip, seq, sched, delay FROM obs") { statement in
      let scheduled = Double(ObservationStore.int(statement, 3))
      actuals["\(ObservationStore.text(statement, 1))|\(ObservationStore.int(statement, 0))|\(ObservationStore.int(statement, 2))"] =
        Actual(actual: scheduled + Double(ObservationStore.int(statement, 4)), scheduled: scheduled)
    }

    let bins = Self.horizons
    var predictionErrors = [[Double]](repeating: [], count: bins.count)
    var scheduleErrors = [[Double]](repeating: [], count: bins.count)
    var snapshots = 0

    for file in recordings.files(of: .trips) {
      let snapshot = try RealtimeDecoder.decode(try gunzip(Data(contentsOf: file.url)))
      snapshots += 1
      let now = file.recordedAt.timeIntervalSince1970
      for prediction in snapshot.predictions where !prediction.tripID.isEmpty && !prediction.vehicleID.isEmpty {
        guard let date = schedule.serviceDate(of: prediction.tripID, near: file.recordedAt) else { continue }
        for stop in prediction.stops where !stop.skipped {
          guard let sequence = stop.sequence, let predicted = (stop.arrival ?? stop.departure)?.timeIntervalSince1970,
            let observed = actuals["\(prediction.tripID)|\(date.value)|\(sequence)"]
          else { continue }
          let horizon = observed.actual - now
          guard let bin = bins.firstIndex(where: { $0.range.contains(horizon) }) else { continue }
          predictionErrors[bin].append(predicted - observed.actual)
          scheduleErrors[bin].append(observed.scheduled - observed.actual)
        }
      }
    }

    return (predictionErrors, scheduleErrors, snapshots)
  }

  /// The summary the app embeds.
  func bins() throws -> [PredictionBin] {
    let (prediction, _, _) = try errors()
    return prediction.enumerated().compactMap { index, list -> PredictionBin? in
      guard list.count >= 30 else { return nil }
      let sorted = list.sorted()
      func q(_ p: Double) -> Int { Int(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))].rounded()) }
      return PredictionBin(horizon: Int(Self.horizons[index].range.upperBound), n: list.count, q05: q(0.05), q50: q(0.5), q95: q(0.95))
    }
  }

  func markdown() throws -> String {
    let bins = Self.horizons
    let (predictionErrors, scheduleErrors, snapshots) = try errors()
    func stats(_ errors: [Double]) -> (median: Double, medianAbs: Double, p90Abs: Double) {
      guard !errors.isEmpty else { return (0, 0, 0) }
      let sorted = errors.sorted()
      let absolute = errors.map(abs).sorted()
      return (sorted[sorted.count / 2], absolute[absolute.count / 2], absolute[min(absolute.count - 1, Int(0.9 * Double(absolute.count)))])
    }
    var out = "# Are the live predictions better than the timetable?\n\n"
    out += "\(snapshots) trip-update snapshots compared with arrivals observed from bus positions. Error = predicted (or scheduled) time minus observed time, in seconds; positive means the prediction was later than reality.\n\n"
    out += "| horizon | n | live: bias | live: median abs | live: p90 abs | timetable: bias | timetable: median abs | timetable: p90 abs |\n|---|---:|---:|---:|---:|---:|---:|---:|\n"
    for (index, bin) in bins.enumerated() {
      let p = stats(predictionErrors[index]), s = stats(scheduleErrors[index])
      out += "| \(bin.name) | \(predictionErrors[index].count) | \(Int(p.median)) | \(Int(p.medianAbs)) | \(Int(p.p90Abs)) | \(Int(s.median)) | \(Int(s.medianAbs)) | \(Int(s.p90Abs)) |\n"
    }
    return out
  }
}
