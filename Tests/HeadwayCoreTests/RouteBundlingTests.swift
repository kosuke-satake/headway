import Foundation
import Testing

@testable import HeadwayCore

@Suite struct RouteBundlingTests {
  /// A straight east-west street at `latitude`, from longitude `from` to `to`, a point every 0.0003 degrees (about 25 m).
  private func street(_ from: Double, _ to: Double, latitude: Double = 43.0) -> [Coordinate] {
    let step = (to >= from ? 1.0 : -1.0) * 0.0003
    return stride(from: from, through: to, by: step).map { Coordinate(latitude: latitude, longitude: $0) }
  }

  private func input(_ route: String, order: Int, direction: Int = 0, id: String? = nil, _ points: [Coordinate]) -> BundleInput {
    BundleInput(route: route, order: order, direction: direction, shapeID: id ?? "\(route)-\(direction)", points: points)
  }

  private func lines(_ result: [BundledLine], _ route: String) -> [BundledLine] { result.filter { $0.route == route } }

  /// The lane a route has around `longitude` (on the street at latitude 43).
  private func lane(_ result: [BundledLine], _ route: String, at longitude: Double) -> Double? {
    lines(result, route).first { line in
      let longitudes = line.coordinates.map(\.longitude)
      return (longitudes.min()! - 0.00001)...(longitudes.max()! + 0.00001) ~= longitude
    }?.lane
  }

  @Test func aRouteAloneIsOneLineInTheMiddleOfTheStreet() {
    let result = RouteBundler.overview([input("A", order: 1, street(-89.40, -89.38))])
    #expect(lines(result, "A").count == 1)
    #expect(result.allSatisfy { $0.lane == 0 })
  }

  @Test func bothDirectionsOfARouteOnTheSameStreetBecomeOneLine() {
    // The two directions are drawn about 10 m apart, on each side of the street, as feeds often do.
    let result = RouteBundler.overview([
      input("A", order: 1, direction: 0, street(-89.40, -89.38, latitude: 43.0)),
      input("A", order: 1, direction: 1, street(-89.38, -89.40, latitude: 43.00009)),
    ])
    #expect(lines(result, "A").count == 1)
    #expect(result.allSatisfy { $0.lane == 0 })
  }

  @Test func aOneWayStretchStaysAsItsOwnLine() {
    // Direction 1 leaves the street for a parallel one 200 m north for part of the way.
    let detour = street(-89.38, -89.385) + street(-89.385, -89.395, latitude: 43.0018) + street(-89.395, -89.40)
    let result = RouteBundler.overview([
      input("A", order: 1, direction: 0, street(-89.40, -89.38)),
      input("A", order: 1, direction: 1, detour),
    ])
    #expect(lines(result, "A").count == 2)
    #expect(lines(result, "A").contains { $0.coordinates.contains { $0.latitude > 43.001 } })
  }

  @Test func routesSharingAStreetLieSideBySideAndComeBackWhenAlone() {
    let result = RouteBundler.overview([
      input("A", order: 1, street(-89.400, -89.380)),
      input("B", order: 2, street(-89.392, -89.372)),
    ])
    #expect(lane(result, "A", at: -89.398) == 0)
    #expect(lane(result, "A", at: -89.386) == -0.5)
    #expect(lane(result, "B", at: -89.386) == 0.5)
    #expect(lane(result, "B", at: -89.374) == 0)
  }

  @Test func aRouteRunningTheOtherWayKeepsItsSide() {
    // B runs west on A's street: in B's own direction its side is the other one, so its lane has the opposite sign.
    let result = RouteBundler.overview([
      input("A", order: 1, street(-89.400, -89.380)),
      input("B", order: 2, street(-89.380, -89.400)),
    ])
    #expect(lane(result, "A", at: -89.39) == -0.5)
    #expect(lane(result, "B", at: -89.39) == -0.5)
  }

  @Test func aCrossingRouteIsNotPushedAside() {
    let across = stride(from: 43.0 - 0.003, through: 43.0 + 0.003, by: 0.0002).map { Coordinate(latitude: $0, longitude: -89.39) }
    let result = RouteBundler.overview([input("A", order: 1, street(-89.40, -89.38)), input("B", order: 2, across)])
    #expect(result.allSatisfy { $0.lane == 0 })
  }

  @Test func aBriefBrushDoesNotMakeALane() {
    // B only touches A's street for about 40 m before turning away: too short to be worth a lane.
    let brush = [Coordinate(latitude: 43.003, longitude: -89.3905), Coordinate(latitude: 43.0, longitude: -89.3905),
                 Coordinate(latitude: 43.0, longitude: -89.3900), Coordinate(latitude: 43.003, longitude: -89.3900)]
    let result = RouteBundler.overview([input("A", order: 1, street(-89.40, -89.38)), input("B", order: 2, brush)])
    #expect(lines(result, "A").allSatisfy { $0.lane == 0 })
  }

  @Test func changesOfLaneAreRampedNotJumped() {
    let result = RouteBundler.overview([
      input("A", order: 1, street(-89.400, -89.380)),
      input("B", order: 2, street(-89.392, -89.372)),
    ])
    let a = lines(result, "A").map(\.lane)
    #expect(a.first == 0)
    #expect(a.last == -0.5)
    #expect(a.contains { $0 != 0 && $0 != -0.5 }, "there is a step between the two lanes")
    // Consecutive pieces join up.
    let pieces = lines(result, "A")
    for (left, right) in zip(pieces, pieces.dropFirst()) { #expect(left.coordinates.last == right.coordinates.first) }
  }

  @Test func spikesOutToAStopAreRemoved() {
    var points = street(-89.40, -89.38)
    // A step 40 m north to a stop and straight back.
    points.insert(Coordinate(latitude: 43.00036, longitude: points[30].longitude), at: 31)
    points.insert(points[30], at: 32)
    let result = RouteBundler.overview([input("A", order: 1, points)])
    #expect(result.flatMap(\.coordinates).allSatisfy { $0.latitude < 43.0001 })
  }

  @Test func theRealFeedGivesFewLongLanes() throws {
    guard let url = RealFeedTests.zip else { return }
    let schedule = try Schedule.load(zipAt: url)
    var tripOf: [String: Trip] = [:]
    for trip in schedule.trips.values where tripOf[trip.shapeID] == nil { tripOf[trip.shapeID] = trip }
    let inputs = schedule.shapes.compactMap { id, points -> BundleInput? in
      guard let trip = tripOf[id], let route = schedule.routes[trip.routeID] else { return nil }
      return BundleInput(route: route.id, order: route.sortOrder, direction: trip.directionID, shapeID: id, points: points)
    }
    let result = RouteBundler.overview(inputs)
    func meters(_ line: BundledLine) -> Double {
      zip(line.coordinates, line.coordinates.dropFirst()).reduce(0) { $0 + Geometry.distance(from: $1.0, to: $1.1) }
    }
    let total = result.reduce(0) { $0 + meters($1) }
    let whole = result.filter { $0.lane == $0.lane.rounded() || $0.lane * 2 == ($0.lane * 2).rounded() }
    let pieces = Double(whole.count)
    print("bundling: \(result.count) pieces, \(Int(total / 1000)) km, \(Int(total / pieces)) m per piece")
    #expect(total / pieces > 300, "lanes should last hundreds of metres, not a few steps")
    #expect(result.allSatisfy { abs($0.lane) <= 6 })
  }
}
