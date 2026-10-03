import Foundation

public struct PlanOptions: Sendable {
  /// How far the rider will walk to or from a stop, in metres (straight line).
  public var maxWalkMeters = 800.0
  /// How far the rider will walk between two stops to transfer.
  public var transferWalkMeters = 250.0
  /// Metres per second.
  public var walkSpeed = 1.25
  /// Straight lines understate street distance; this stretches them.
  public var walkDetourFactor = 1.3
  /// Time needed to get off one bus and onto another at the same stop.
  public var minTransferSeconds = 60.0
  /// Largest number of buses in one journey.
  public var maxRides = 4
  /// How far ahead of the departure time to look for buses.
  public var searchWindow: TimeInterval = 4 * 3600
  /// How many journeys to return at most.
  public var maxJourneys = 6

  public init() {}
}

/// Finds journeys by bus and on foot, using the timetable and, where a bus is reporting, its live delay.
///
/// The search is a round-based connection scan: round `k` finds the earliest arrival at every stop using at most
/// `k` buses. Each round that beats the one before it is a journey with one more bus, so the result trades arrival
/// time against number of transfers. A second scan that starts just after the first journey's first bus leaves finds
/// the buses after it.
public struct TripPlanner: Sendable {
  public let schedule: Schedule

  public init(schedule: Schedule) {
    self.schedule = schedule
  }

  // MARK: Internal types

  private struct Connection {
    var departure: Double  // seconds after the search start
    var arrival: Double
    var from: Int
    var to: Int
    var trip: Int  // index into `trips`
    var sequence: Int  // stop_sequence at `from`
    var delay: Double  // live delay at departure, seconds (0 when none)
  }

  private struct TripInstance {
    let tripID: String
    let routeID: String
    let headsign: String
    let isLive: Bool  // a bus is reporting for this trip and the feed predicts its times
  }

  private enum Via {
    case none
    case origin(walkSeconds: Double, point: PlanPoint)
    /// `round` is the round in which the label was created, so that reconstruction steps back to the right round
    /// even when a later round merely inherited the label.
    case ride(trip: Int, board: Int, alight: Int, round: Int)
    case walk(from: Int, round: Int)
  }

  private struct Label {
    var arrival = Double.infinity
    var arrivedByBus = false
    var via = Via.none
  }

  private struct Footpath {
    let to: Int
    let seconds: Double
    let meters: Double
  }

  // MARK: Planning

  public func plan(
    from origin: PlanPoint,
    to destination: PlanPoint,
    departAt start: Date,
    options: PlanOptions = PlanOptions(),
    predictions: [TripPrediction] = [],
    vehicles: [VehicleSample] = []
  ) -> [Journey] {
    let stops = Array(schedule.stops.values)
    let stopIndex = Dictionary(uniqueKeysWithValues: stops.enumerated().map { ($1.id, $0) })
    let footpaths = Self.footpaths(stops: stops, options: options)

    let originAccess = access(to: origin, stops: stops, stopIndex: stopIndex, options: options)
    let destinationAccess = access(to: destination, stops: stops, stopIndex: stopIndex, options: options)

    var journeys: [Journey] = []
    var searchStart = start
    // Two scans: from the requested time, and from just after the first bus of the first journey has left.
    for _ in 0..<2 {
      let result = scan(
        start: searchStart, origin: origin, destination: destination, stops: stops, stopIndex: stopIndex,
        footpaths: footpaths, originAccess: originAccess, destinationAccess: destinationAccess, options: options,
        predictions: predictions, vehicles: vehicles)
      journeys.append(contentsOf: result)
      guard let first = result.first(where: { !$0.rides.isEmpty }), let firstRide = first.rides.first else { break }
      // Leave late enough to just miss that bus: arrive at its stop 30 seconds after it has gone.
      searchStart = max(searchStart, firstRide.depart.addingTimeInterval(-leadWalk(of: first) + 30))
    }
    return Self.select(journeys, limit: options.maxJourneys)
  }

  /// Seconds the rider walks before the first bus.
  private func leadWalk(of journey: Journey) -> TimeInterval {
    guard case .walk(let walk)? = journey.legs.first else { return 0 }
    return walk.end.timeIntervalSince(walk.start)
  }

  /// Removes duplicates and journeys that are both later and need more transfers than another, and orders the rest.
  private static func select(_ journeys: [Journey], limit: Int) -> [Journey] {
    var unique: [String: Journey] = [:]
    for journey in journeys {
      let key = journey.rides.map { "\($0.tripID)@\($0.fromStop.stopID ?? "")" }.joined(separator: ">")
      if let existing = unique[key], existing.arrival <= journey.arrival { continue }
      unique[key] = journey
    }
    let all = Array(unique.values)
    let kept = all.filter { candidate in
      !all.contains { other in
        other != candidate && other.arrival <= candidate.arrival && other.departure >= candidate.departure
          && other.transfers <= candidate.transfers
          && (other.arrival < candidate.arrival || other.departure > candidate.departure || other.transfers < candidate.transfers)
      }
    }
    let ordered = kept.sorted { ($0.departure, $0.arrival) < ($1.departure, $1.arrival) }
    return Array(ordered.prefix(limit))
  }

  // MARK: Access and footpaths

  /// Stops the rider can start from or end at, with the walking time and distance to each.
  private func access(
    to point: PlanPoint, stops: [Stop], stopIndex: [String: Int], options: PlanOptions
  ) -> [(stop: Int, seconds: Double, meters: Double)] {
    if let id = point.stopID, let index = stopIndex[id] { return [(index, 0, 0)] }
    var near: [(stop: Int, seconds: Double, meters: Double)] = []
    for (index, stop) in stops.enumerated() {
      let meters = Geometry.distance(from: point.coordinate, to: Coordinate(latitude: stop.latitude, longitude: stop.longitude))
      if meters <= options.maxWalkMeters {
        near.append((index, meters * options.walkDetourFactor / options.walkSpeed, meters))
      }
    }
    return Array(near.sorted { $0.seconds < $1.seconds }.prefix(30))
  }

  /// Walking links between nearby stops, for transfers.
  private static func footpaths(stops: [Stop], options: PlanOptions) -> [[Footpath]] {
    var result = [[Footpath]](repeating: [], count: stops.count)
    // Grid of about 0.003 degrees (roughly 300 m) so that only neighbouring cells are compared.
    let cell = 0.003
    var grid: [Int64: [Int]] = [:]
    func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
    for (index, stop) in stops.enumerated() {
      grid[key(Int(floor(stop.longitude / cell)), Int(floor(stop.latitude / cell))), default: []].append(index)
    }
    for (index, stop) in stops.enumerated() {
      let cx = Int(floor(stop.longitude / cell)), cy = Int(floor(stop.latitude / cell))
      for dx in -1...1 {
        for dy in -1...1 {
          for other in grid[key(cx + dx, cy + dy)] ?? [] where other != index {
            let meters = Geometry.distance(
              from: Coordinate(latitude: stop.latitude, longitude: stop.longitude),
              to: Coordinate(latitude: stops[other].latitude, longitude: stops[other].longitude))
            if meters <= options.transferWalkMeters {
              result[index].append(
                Footpath(to: other, seconds: meters * options.walkDetourFactor / options.walkSpeed, meters: meters))
            }
          }
        }
      }
    }
    return result
  }

  // MARK: Connections

  private func buildConnections(
    start: Date, options: PlanOptions, stopIndex: [String: Int], predictions: [TripPrediction], vehicles: [VehicleSample]
  ) -> (connections: [Connection], trips: [TripInstance]) {
    var predictionByTrip: [String: TripPrediction] = [:]
    for prediction in predictions where !prediction.tripID.isEmpty { predictionByTrip[prediction.tripID] = prediction }
    let reporting = Set(vehicles.map(\.tripID))

    var connections: [Connection] = []
    var trips: [TripInstance] = []
    let end = start.addingTimeInterval(options.searchWindow)
    let firstDate = ServiceDate(start, in: schedule.timeZone).adding(days: -1, in: schedule.timeZone)
    let lastDate = ServiceDate(end, in: schedule.timeZone)
    var date = firstDate
    while date <= lastDate {
      let midnight = date.midnight(in: schedule.timeZone)
      let base = midnight.timeIntervalSince(start)
      let active = schedule.activeServiceIDs(on: date)
      for trip in schedule.trips.values where active.contains(trip.serviceID) {
        guard let times = schedule.stopTimes[trip.id], times.count > 1 else { continue }
        if base + Double(times[times.count - 1].arrival) < 0 || base + Double(times[0].departure) > options.searchWindow {
          continue
        }
        // Live delay per stop sequence, carried forward to the stops after the last predicted one.
        var delayAt: [Int: Double] = [:]
        var isLive = false
        if let prediction = predictionByTrip[trip.id] {
          var last: Double?
          let predicted = Dictionary(
            prediction.stops.compactMap { stop -> (Int, Date)? in
              guard let sequence = stop.sequence, let time = stop.arrival ?? stop.departure else { return nil }
              return (sequence, time)
            }, uniquingKeysWith: { first, _ in first })
          for time in times {
            if let predictedTime = predicted[time.sequence] {
              let scheduled = midnight.addingTimeInterval(Double(time.arrival))
              let delay = predictedTime.timeIntervalSince(scheduled)
              // A prediction for another day's run of the same trip would be hours off; ignore it.
              if abs(delay) < 3 * 3600 { last = delay }
            }
            if let last { delayAt[time.sequence] = last }
          }
          if !delayAt.isEmpty, reporting.contains(trip.id) { isLive = true }
        }
        let index = trips.count
        var used = false
        for i in 0..<(times.count - 1) {
          guard let from = stopIndex[times[i].stopID], let to = stopIndex[times[i + 1].stopID] else { continue }
          let departureDelay = delayAt[times[i].sequence] ?? 0
          let arrivalDelay = delayAt[times[i + 1].sequence] ?? 0
          let departure = base + Double(times[i].departure) + departureDelay
          let arrival = max(departure, base + Double(times[i + 1].arrival) + arrivalDelay)
          if departure < 0 || departure > options.searchWindow { continue }
          connections.append(
            Connection(
              departure: departure, arrival: arrival, from: from, to: to, trip: index, sequence: times[i].sequence,
              delay: isLive ? departureDelay : 0))
          used = true
        }
        if used {
          trips.append(
            TripInstance(tripID: trip.id, routeID: trip.routeID, headsign: trip.headsign, isLive: isLive))
        }
      }
      date = date.adding(days: 1, in: schedule.timeZone)
    }
    connections.sort { $0.departure < $1.departure }
    return (connections, trips)
  }

  // MARK: Scan

  private func scan(
    start: Date, origin: PlanPoint, destination: PlanPoint, stops: [Stop], stopIndex: [String: Int],
    footpaths: [[Footpath]], originAccess: [(stop: Int, seconds: Double, meters: Double)],
    destinationAccess: [(stop: Int, seconds: Double, meters: Double)], options: PlanOptions,
    predictions: [TripPrediction], vehicles: [VehicleSample]
  ) -> [Journey] {
    guard !originAccess.isEmpty, !destinationAccess.isEmpty else { return [] }
    let (connections, trips) = buildConnections(
      start: start, options: options, stopIndex: stopIndex, predictions: predictions, vehicles: vehicles)

    // Round 0: on foot from the origin to the stops around it.
    var rounds: [[Label]] = []
    var initial = [Label](repeating: Label(), count: stops.count)
    for entry in originAccess {
      initial[entry.stop] = Label(arrival: entry.seconds, arrivedByBus: false, via: .origin(walkSeconds: entry.seconds, point: origin))
    }
    rounds.append(initial)

    var journeys: [Journey] = []
    var bestTotal = Double.infinity
    // Walking all the way is a journey too, when the points are close.
    if let walkOnly = walkOnlyJourney(from: origin, to: destination, start: start, options: options) {
      journeys.append(walkOnly)
      bestTotal = walkOnly.arrival.timeIntervalSince(start)
    }

    for round in 1...options.maxRides {
      let previous = rounds[round - 1]
      var current = previous
      var boarded: [Int: Int] = [:]  // trip -> connection index where it was boarded
      var improved = Set<Int>()
      for (ci, c) in connections.enumerated() {
        if c.departure > bestTotal { break }
        var board = boarded[c.trip]
        if board == nil {
          let label = previous[c.from]
          let slack = label.arrivedByBus ? options.minTransferSeconds : 0
          if label.arrival + slack <= c.departure {
            board = ci
            boarded[c.trip] = ci
          }
        }
        if let board, c.arrival < current[c.to].arrival {
          current[c.to] = Label(
            arrival: c.arrival, arrivedByBus: true, via: .ride(trip: c.trip, board: board, alight: ci, round: round))
          improved.insert(c.to)
        }
      }
      // Walk from stops reached by bus in this round to the stops nearby.
      for stop in improved {
        for path in footpaths[stop] {
          let arrival = current[stop].arrival + path.seconds
          if arrival < current[path.to].arrival {
            current[path.to] = Label(arrival: arrival, arrivedByBus: false, via: .walk(from: stop, round: round))
          }
        }
      }
      rounds.append(current)

      // Best way to the destination with at most `round` buses.
      var best: (total: Double, stop: Int, access: (stop: Int, seconds: Double, meters: Double))?
      for entry in destinationAccess {
        let total = current[entry.stop].arrival + entry.seconds
        if total < (best?.total ?? .infinity) { best = (total, entry.stop, entry) }
      }
      if let best, best.total < bestTotal - 1 {
        bestTotal = best.total
        if let journey = reconstruct(
          rounds: rounds, round: round, finalStop: best.stop, access: best.access, destination: destination, start: start,
          stops: stops, connections: connections, trips: trips, options: options)
        {
          journeys.append(journey)
        }
      }
    }
    return journeys
  }

  private func walkOnlyJourney(from origin: PlanPoint, to destination: PlanPoint, start: Date, options: PlanOptions) -> Journey? {
    let meters = Geometry.distance(from: origin.coordinate, to: destination.coordinate)
    guard meters > 0, meters <= 1200 else { return nil }
    let seconds = meters * options.walkDetourFactor / options.walkSpeed
    let leg = WalkLeg(from: origin, to: destination, start: start, end: start.addingTimeInterval(seconds), meters: meters)
    return Journey(legs: [.walk(leg)])
  }

  // MARK: Reconstruction

  private func reconstruct(
    rounds: [[Label]], round: Int, finalStop: Int, access: (stop: Int, seconds: Double, meters: Double),
    destination: PlanPoint, start: Date, stops: [Stop], connections: [Connection], trips: [TripInstance],
    options: PlanOptions
  ) -> Journey? {
    func point(_ index: Int) -> PlanPoint {
      let stop = stops[index]
      return PlanPoint(name: stop.name, coordinate: Coordinate(latitude: stop.latitude, longitude: stop.longitude), stopID: stop.id)
    }
    func date(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    var legs: [JourneyLeg] = []
    var currentRound = round
    var stop = finalStop

    // Walk from the last stop to the destination, if the destination is not the stop itself.
    let endArrival = rounds[round][finalStop].arrival
    if access.meters > 0 {
      legs.append(
        .walk(WalkLeg(from: point(finalStop), to: destination, start: date(endArrival), end: date(endArrival + access.seconds), meters: access.meters)))
    }

    var guardCount = 0
    while guardCount < 50 {
      guardCount += 1
      let label = rounds[currentRound][stop]
      switch label.via {
      case .none:
        return nil
      case .origin(let seconds, let originPoint):
        if seconds > 0 {
          legs.append(
            .walk(WalkLeg(from: originPoint, to: point(stop), start: date(0), end: date(seconds),
              meters: Geometry.distance(from: originPoint.coordinate, to: point(stop).coordinate))))
        }
        return finish(legs, start: start)
      case .walk(let from, let createdIn):
        let meters = Geometry.distance(from: point(from).coordinate, to: point(stop).coordinate)
        let fromArrival = rounds[createdIn][from].arrival
        legs.append(.walk(WalkLeg(from: point(from), to: point(stop), start: date(fromArrival), end: date(label.arrival), meters: meters)))
        stop = from
        currentRound = createdIn
      case .ride(let trip, let board, let alight, let createdIn):
        let boardConnection = connections[board], alightConnection = connections[alight]
        let instance = trips[trip]
        legs.append(
          .ride(RideLeg(
            tripID: instance.tripID, routeID: instance.routeID, headsign: instance.headsign,
            fromStop: point(boardConnection.from), toStop: point(alightConnection.to),
            depart: date(boardConnection.departure), arrive: date(alightConnection.arrival),
            stopCount: countStops(from: board, to: alight, trip: trip, connections: connections),
            delay: instance.isLive ? Int(boardConnection.delay.rounded()) : nil, isLive: instance.isLive)))
        stop = boardConnection.from
        currentRound = createdIn - 1
      }
    }
    return nil
  }

  /// How many stops a rider passes between boarding and getting off (the stop they board at is not counted).
  private func countStops(from board: Int, to alight: Int, trip: Int, connections: [Connection]) -> Int {
    var count = 0
    var index = board
    while index <= alight {
      if connections[index].trip == trip { count += 1 }
      index += 1
    }
    return count
  }

  /// Orders the legs, merges nothing, and rejects journeys that end up with no ride and no walk.
  private func finish(_ reversed: [JourneyLeg], start: Date) -> Journey? {
    let legs = Array(reversed.reversed())
    guard !legs.isEmpty else { return nil }
    return Journey(legs: legs)
  }
}
