import Foundation
import Testing

@testable import HeadwayCore

@Suite struct GeometryTests {
  @Test func haversineMatchesKnownDistance() {
    // One degree of latitude is about 111.2 km.
    let d = Geometry.distance(from: Coordinate(latitude: 43, longitude: -89), to: Coordinate(latitude: 44, longitude: -89))
    #expect(abs(d - 111_195) < 300)
  }

  @Test func distanceToLineUsesTheNearestPoint() {
    // A line running east along latitude 43.0.
    let line = [Coordinate(latitude: 43, longitude: -89.40), Coordinate(latitude: 43, longitude: -89.38)]
    // 100 m north of the middle of the line.
    let north = Coordinate(latitude: 43 + 100 / 111_320, longitude: -89.39)
    #expect(abs(Geometry.distance(from: north, toLine: line) - 100) < 1)
    // On the line.
    #expect(Geometry.distance(from: Coordinate(latitude: 43, longitude: -89.39), toLine: line) < 0.5)
    // Beyond the end: distance to the endpoint, not the infinite line.
    let beyond = Coordinate(latitude: 43, longitude: -89.37)
    #expect(abs(Geometry.distance(from: beyond, toLine: line) - Geometry.distance(from: beyond, to: line[1])) < 5)
  }

  @Test func nearestReportsTheSegment() {
    let line = [
      Coordinate(latitude: 43.00, longitude: -89.40), Coordinate(latitude: 43.00, longitude: -89.39),
      Coordinate(latitude: 43.01, longitude: -89.39),
    ]
    let nearSecondSegment = Coordinate(latitude: 43.005, longitude: -89.3899)
    #expect(Geometry.nearest(on: line, to: nearSecondSegment).index == 1)
  }

  @Test func degenerateLines() {
    #expect(Geometry.distance(from: Coordinate(latitude: 43, longitude: -89), toLine: []) == .greatestFiniteMagnitude)
    let single = [Coordinate(latitude: 43, longitude: -89)]
    #expect(Geometry.distance(from: Coordinate(latitude: 43, longitude: -89), toLine: single) < 0.001)
  }
}
