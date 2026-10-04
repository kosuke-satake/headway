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

  @Test func pathAheadFollowsTheLine() throws {
    // A line east along latitude 43, then north.
    let line = [
      Coordinate(latitude: 43.000, longitude: -89.400), Coordinate(latitude: 43.000, longitude: -89.390),
      Coordinate(latitude: 43.010, longitude: -89.390),
    ]
    let start = Coordinate(latitude: 43.0, longitude: -89.399)
    // 1,000 m ahead covers the rest of the first segment (about 0.9 km) and turns the corner.
    let path = try #require(Geometry.pathAhead(on: line, from: start, meters: 1_000))
    #expect(path.first!.longitude > -89.3995 && path.first!.longitude < -89.3985)
    #expect(path.contains(line[1]))
    let end = path.last!
    #expect(end.latitude > 43.0 && abs(end.longitude + 89.390) < 1e-6)
    var length = 0.0
    for (next, previous) in zip(path.dropFirst(), path) { length += Geometry.distance(from: previous, to: next) }
    #expect(abs(length - 1_000) < 5)
    // The point 500 m along is still on the first segment.
    let half = Geometry.point(on: path, at: 500)
    #expect(abs(half.latitude - 43.0) < 1e-6)
  }

  @Test func pathAheadClampsAtTheEndOfTheLine() throws {
    let line = [Coordinate(latitude: 43, longitude: -89.40), Coordinate(latitude: 43, longitude: -89.39)]
    let path = try #require(Geometry.pathAhead(on: line, from: line[0], meters: 50_000))
    #expect(path.last == line[1])
    #expect(Geometry.point(on: path, at: 1e9) == line[1])
  }

  @Test func pathAheadNeedsADirectionAndALine() {
    let line = [Coordinate(latitude: 43, longitude: -89.40), Coordinate(latitude: 43, longitude: -89.39)]
    #expect(Geometry.pathAhead(on: line, from: line[0], meters: 0) == nil)
    #expect(Geometry.pathAhead(on: [line[0]], from: line[0], meters: 100) == nil)
  }
}
