import Foundation

/// A place a journey starts or ends: a bus stop, or any point such as the user's location.
public struct PlanPoint: Sendable, Hashable {
  public let name: String
  public let coordinate: Coordinate
  /// Set when the point is a bus stop; the planner then starts or ends exactly there.
  public let stopID: String?

  public init(name: String, coordinate: Coordinate, stopID: String? = nil) {
    self.name = name
    self.coordinate = coordinate
    self.stopID = stopID
  }
}

public struct WalkLeg: Sendable, Hashable {
  public let from: PlanPoint
  public let to: PlanPoint
  public let start: Date
  public let end: Date
  /// Straight-line distance; real streets are longer, which the time estimate allows for.
  public let meters: Double

  public init(from: PlanPoint, to: PlanPoint, start: Date, end: Date, meters: Double) {
    self.from = from
    self.to = to
    self.start = start
    self.end = end
    self.meters = meters
  }
}

public struct RideLeg: Sendable, Hashable {
  public let tripID: String
  public let routeID: String
  public let headsign: String
  public let fromStop: PlanPoint
  public let toStop: PlanPoint
  public let depart: Date
  public let arrive: Date
  /// Number of stops after boarding, up to and including the one where the rider gets off.
  public let stopCount: Int
  /// Seconds late (positive) or early at boarding, when live data was used for this trip.
  public let delay: Int?
  public let isLive: Bool

  public init(
    tripID: String, routeID: String, headsign: String, fromStop: PlanPoint, toStop: PlanPoint, depart: Date, arrive: Date,
    stopCount: Int, delay: Int?, isLive: Bool
  ) {
    self.tripID = tripID
    self.routeID = routeID
    self.headsign = headsign
    self.fromStop = fromStop
    self.toStop = toStop
    self.depart = depart
    self.arrive = arrive
    self.stopCount = stopCount
    self.delay = delay
    self.isLive = isLive
  }
}

public enum JourneyLeg: Sendable, Hashable {
  case walk(WalkLeg)
  case ride(RideLeg)

  public var start: Date {
    switch self {
    case .walk(let leg): leg.start
    case .ride(let leg): leg.depart
    }
  }

  public var end: Date {
    switch self {
    case .walk(let leg): leg.end
    case .ride(let leg): leg.arrive
    }
  }
}

/// A place the rider stops at on the way, for a while, before going on (a trip with several destinations).
public struct Stopover: Sendable, Hashable {
  public let place: PlanPoint
  public let arrive: Date
  public let leave: Date
  /// The stopover comes after the leg at this index.
  public let afterLeg: Int

  public init(place: PlanPoint, arrive: Date, leave: Date, afterLeg: Int) {
    self.place = place
    self.arrive = arrive
    self.leave = leave
    self.afterLeg = afterLeg
  }

  public var duration: TimeInterval { leave.timeIntervalSince(arrive) }
}

public struct Journey: Sendable, Identifiable, Hashable {
  public var id: String {
    legs.compactMap { if case .ride(let ride) = $0 { return "\(ride.tripID)@\(ride.fromStop.stopID ?? "")" } else { return nil } }
      .joined(separator: ">") + "|\(Int(departure.timeIntervalSince1970))"
  }

  public let legs: [JourneyLeg]
  /// Places stopped at between the legs; empty for an ordinary journey.
  public let stopovers: [Stopover]

  public init(legs: [JourneyLeg], stopovers: [Stopover] = []) {
    self.legs = legs
    self.stopovers = stopovers
  }

  public var departure: Date { legs.first?.start ?? .distantPast }
  public var arrival: Date { legs.last?.end ?? .distantPast }
  public var duration: TimeInterval { arrival.timeIntervalSince(departure) }

  public var rides: [RideLeg] {
    legs.compactMap { if case .ride(let ride) = $0 { return ride } else { return nil } }
  }

  public var transfers: Int { max(0, rides.count - 1) }

  public var walkingMeters: Double {
    legs.reduce(0) { total, leg in
      if case .walk(let walk) = leg { return total + walk.meters } else { return total }
    }
  }

  /// True when at least one ride was timed with live predictions.
  public var usesLiveData: Bool { rides.contains { $0.isLive } }

  /// Time between getting off one bus and the next one leaving, for each transfer. The shortest one tells how risky
  /// the journey is.
  public var transferBuffers: [TimeInterval] {
    var buffers: [TimeInterval] = []
    var lastArrival: Date?
    for (index, leg) in legs.enumerated() {
      // A stopover is a stay, not a connection: it does not count as a transfer buffer.
      defer { if stopovers.contains(where: { $0.afterLeg == index }) { lastArrival = nil } }
      switch leg {
      case .ride(let ride):
        if let lastArrival { buffers.append(ride.depart.timeIntervalSince(lastArrival)) }
        lastArrival = ride.arrive
      case .walk(let walk):
        if lastArrival != nil { lastArrival = walk.end }
      }
    }
    return buffers
  }
}

/// A line to draw for one leg of a journey.
public struct JourneyPolyline: Sendable {
  public let coordinates: [Coordinate]
  /// The route a ride belongs to; `nil` for walking.
  public let routeID: String?
}

extension Journey {
  /// The lines to draw on a map: the route's own shape between boarding and alighting for rides, straight lines for
  /// walking.
  public func polylines(schedule: Schedule) -> [JourneyPolyline] {
    legs.map { leg in
      switch leg {
      case .walk(let walk):
        return JourneyPolyline(coordinates: [walk.from.coordinate, walk.to.coordinate], routeID: nil)
      case .ride(let ride):
        let line = schedule.shapeSegment(tripID: ride.tripID, from: ride.fromStop, to: ride.toStop)
        return JourneyPolyline(coordinates: line, routeID: ride.routeID)
      }
    }
  }
}

extension Schedule {
  /// The part of a trip's route line between two of its stops. Falls back to a straight line when the trip has no
  /// shape.
  public func shapeSegment(tripID: String, from: PlanPoint, to: PlanPoint) -> [Coordinate] {
    guard let trip = trips[tripID], let shape = shapes[trip.shapeID], shape.count > 1 else {
      return [from.coordinate, to.coordinate]
    }
    let start = Geometry.nearest(on: shape, to: from.coordinate).index
    // Search for the end only after the start, so that a route that loops past a stop twice is cut correctly.
    let tail = Array(shape[start...])
    let end = start + Geometry.nearest(on: tail, to: to.coordinate).index
    guard end > start else { return [from.coordinate, to.coordinate] }
    return [from.coordinate] + Array(shape[(start + 1)...end]) + [to.coordinate]
  }
}
