import Foundation

/// A place to stop at on the way, and for how long.
public struct ViaStop: Sendable, Hashable {
  public let point: PlanPoint
  /// How long to stay before going on.
  public let dwell: TimeInterval

  public init(point: PlanPoint, dwell: TimeInterval) {
    self.point = point
    self.dwell = dwell
  }
}

extension TripPlanner {
  /// Journeys that go from `origin` through each of `stops` in order, staying as long as asked at each, to `destination`.
  ///
  /// Each part is planned on its own, starting when the previous one ends plus the stay, taking the part that arrives
  /// first (waiting for an earlier arrival never makes the rest later). Several first parts give several journeys.
  public func plan(
    from origin: PlanPoint, via stops: [ViaStop], to destination: PlanPoint, departAt start: Date,
    options: PlanOptions = PlanOptions(), predictions: [TripPrediction] = [], vehicles: [VehicleSample] = []
  ) -> [Journey] {
    let points = [origin] + stops.map(\.point) + [destination]
    let heads = plan(from: points[0], to: points[1], departAt: start, options: options, predictions: predictions, vehicles: vehicles)
    var results: [Journey] = []
    for head in heads.prefix(4) where !head.rides.isEmpty || stops.isEmpty {
      var parts = [head]
      var failed = false
      for index in 1..<(points.count - 1) {
        let leave = parts[parts.count - 1].arrival.addingTimeInterval(stops[index - 1].dwell)
        let next = plan(from: points[index], to: points[index + 1], departAt: leave, options: options, predictions: predictions, vehicles: vehicles)
        guard let best = next.min(by: { ($0.arrival, $0.transfers) < ($1.arrival, $1.transfers) }) else {
          failed = true
          break
        }
        parts.append(best)
      }
      if !failed { results.append(Self.join(parts, via: stops.map(\.point))) }
    }
    return Self.unique(results).sorted { ($0.arrival, $0.departure) < ($1.arrival, $1.departure) }
  }

  /// The same, working backwards from the time the rider has to be at `destination`: the last part leaves as late as
  /// it can, and each earlier part ends in time to stay for the asked time.
  public func plan(
    from origin: PlanPoint, via stops: [ViaStop], to destination: PlanPoint, arriveBy deadline: Date,
    options: PlanOptions = PlanOptions(), predictions: [TripPrediction] = [], vehicles: [VehicleSample] = [],
    earliestStart: Date = Date()
  ) -> [Journey] {
    let points = [origin] + stops.map(\.point) + [destination]
    let tails = plan(
      from: points[points.count - 2], to: points[points.count - 1], arriveBy: deadline, options: options, predictions: predictions,
      vehicles: vehicles, earliestStart: earliestStart)
    var results: [Journey] = []
    for tail in tails.prefix(4) where !tail.rides.isEmpty || stops.isEmpty {
      var parts = [tail]
      var failed = false
      for index in stride(from: points.count - 2, to: 0, by: -1) {
        let by = parts[0].departure.addingTimeInterval(-stops[index - 1].dwell)
        let before = plan(
          from: points[index - 1], to: points[index], arriveBy: by, options: options, predictions: predictions, vehicles: vehicles,
          earliestStart: earliestStart)
        guard let best = before.max(by: { ($0.departure, -Double($0.transfers)) < ($1.departure, -Double($1.transfers)) }) else {
          failed = true
          break
        }
        parts.insert(best, at: 0)
      }
      if !failed { results.append(Self.join(parts, via: stops.map(\.point))) }
    }
    return Self.unique(results).sorted { ($0.departure, $0.arrival) < ($1.departure, $1.arrival) }
  }

  /// Puts the parts end to end, with a stopover at each place where one part ends and the next begins.
  static func join(_ parts: [Journey], via places: [PlanPoint]) -> Journey {
    var legs: [JourneyLeg] = []
    var stopovers: [Stopover] = []
    for (index, part) in parts.enumerated() {
      legs += part.legs
      if index < parts.count - 1 {
        stopovers.append(Stopover(place: places[index], arrive: part.arrival, leave: parts[index + 1].departure, afterLeg: legs.count - 1))
      }
    }
    return Journey(legs: legs, stopovers: stopovers)
  }

  private static func unique(_ journeys: [Journey]) -> [Journey] {
    var seen: Set<String> = []
    return journeys.filter { seen.insert($0.id).inserted }
  }
}
