import Foundation
import Testing

@testable import HeadwayCore

@Suite struct RouteBundlingTests {
  /// A straight east-west street at latitude 43, from `from` to `to` (longitudes, in steps of about 25 m).
  private func street(_ from: Double, _ to: Double) -> [Coordinate] {
    let step = (to >= from ? 1.0 : -1.0) * 0.0003
    return stride(from: from, through: to, by: step).map { Coordinate(latitude: 43.0, longitude: $0) }
  }

  private func input(_ route: String, order: Int, direction: Int = 0, _ points: [Coordinate]) -> BundleInput {
    BundleInput(route: route, order: order, direction: direction, shapeID: "\(route)-\(direction)", points: points)
  }

  private func lanes(_ lines: [BundledLine], route: String, direction: Int? = nil) -> [Double] {
    lines.filter { $0.route == route && (direction == nil || $0.direction == direction) }.map(\.lane)
  }

  @Test func aRouteAloneStaysOnTheStreet() {
    let lines = RouteBundler.bundle([input("A", order: 1, street(-89.40, -89.39))])
    #expect(lines.count == 1)
    #expect(lines[0].lane == 0)
    #expect(lines[0].coordinates.count > 10)
  }

  @Test func routesSharingAStreetGetNeighbouringLanesAndGoBackWhenTheyPartCompany() {
    let lines = RouteBundler.bundle([
      input("A", order: 1, street(-89.400, -89.394)),
      input("B", order: 2, street(-89.397, -89.391)),
    ])
    // A is alone, then shares with B, and B is alone at the end (the change of lane may be a cell early or late).
    #expect(lanes(lines, route: "A").first == 0)
    #expect(lanes(lines, route: "A").last == -0.5)
    #expect(lanes(lines, route: "B").first == 0.5)
    #expect(lanes(lines, route: "B").last == 0)
    #expect(Set(lanes(lines, route: "A") + lanes(lines, route: "B")).isSubset(of: [0, -0.5, 0.5]))
  }

  @Test func theOtherWayRoundKeepsTheSamePhysicalLane() {
    let lines = RouteBundler.bundle([
      input("A", order: 1, street(-89.400, -89.394)),
      input("B", order: 2, direction: 1, street(-89.394, -89.400)),
    ])
    // B runs against A on the same street. In its own frame the same side is the other one, so it is -0.5 as well:
    // it is never +0.5, which would put it on the other side of the street.
    #expect(lanes(lines, route: "A").contains(-0.5))
    #expect(lanes(lines, route: "B").contains(-0.5))
    #expect(!lanes(lines, route: "B").contains(0.5))
    #expect(!lanes(lines, route: "A").contains(0.5))
  }

  @Test func bothDirectionsOfOneRouteShareOneLane() {
    let lines = RouteBundler.bundle([
      input("A", order: 1, direction: 0, street(-89.400, -89.394)),
      input("A", order: 1, direction: 1, street(-89.394, -89.400)),
    ])
    #expect(lines.allSatisfy { $0.lane == 0 })
  }

  @Test func threeRoutesAreCentredOnTheStreet() {
    let lines = RouteBundler.bundle([
      input("A", order: 1, street(-89.400, -89.394)),
      input("B", order: 2, street(-89.400, -89.394)),
      input("C", order: 3, street(-89.400, -89.394)),
    ])
    #expect(lanes(lines, route: "A") == [-1])
    #expect(lanes(lines, route: "B") == [0])
    #expect(lanes(lines, route: "C") == [1])
  }

  @Test func aRouteCrossingTheStreetStaysOnItsOwnLine() {
    // B crosses A's street at a right angle: it must not be pushed sideways where they meet.
    let across = stride(from: 43.0 - 0.002, through: 43.0 + 0.002, by: 0.0002).map { Coordinate(latitude: $0, longitude: -89.397) }
    let lines = RouteBundler.bundle([input("A", order: 1, street(-89.400, -89.394)), input("B", order: 2, across)])
    #expect(lines.allSatisfy { $0.lane == 0 })
  }

  @Test func streetsFarApartDoNotInteract() {
    var far = street(-89.400, -89.394)
    far = far.map { Coordinate(latitude: $0.latitude + 0.01, longitude: $0.longitude) }
    let lines = RouteBundler.bundle([input("A", order: 1, street(-89.400, -89.394)), input("B", order: 2, far)])
    #expect(lines.allSatisfy { $0.lane == 0 })
  }

  @Test func theRunsJoinUpWithoutGapsAndKeepEveryPoint() {
    let shape = street(-89.400, -89.394)
    let lines = RouteBundler.bundle([input("A", order: 1, shape), input("B", order: 2, street(-89.397, -89.391))])
    let a = lines.filter { $0.route == "A" }
    #expect(a.count == 2)
    #expect(a[0].coordinates.last == a[1].coordinates.first)
    #expect(a[0].coordinates.first == shape.first)
    #expect(a[1].coordinates.last == shape.last)
  }

  @Test func theRealFeedHasBundlesButNotEverywhere() throws {
    guard let url = RealFeedTests.zip else { return }
    let schedule = try Schedule.load(zipAt: url)
    var routeOfShape: [String: Trip] = [:]
    for trip in schedule.trips.values where routeOfShape[trip.shapeID] == nil { routeOfShape[trip.shapeID] = trip }
    let inputs = schedule.shapes.compactMap { id, points -> BundleInput? in
      guard let trip = routeOfShape[id], let route = schedule.routes[trip.routeID] else { return nil }
      return BundleInput(route: route.id, order: route.sortOrder, direction: trip.directionID, shapeID: id, points: points)
    }
    let lines = RouteBundler.bundle(inputs)
    let total = lines.reduce(0) { $0 + $1.coordinates.count }
    let bundled = lines.filter { $0.lane != 0 }.reduce(0) { $0 + $1.coordinates.count }
    let share = Double(bundled) / Double(total)
    // More than half of all route lines run along a street that another route also uses (measured on the feed).
    #expect(share > 0.3 && share < 0.8, "share of points in a bundle: \(share)")
    #expect(lines.allSatisfy { abs($0.lane) <= 6 })
  }
}
