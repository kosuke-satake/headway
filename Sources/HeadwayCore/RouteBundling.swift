import Foundation

/// One route shape to be laid out next to the others that share its streets.
public struct BundleInput: Sendable {
  public let route: String
  /// Position of the route in the route list; lower comes first in a bundle.
  public let order: Int
  public let direction: Int
  public let shapeID: String
  public let points: [Coordinate]

  public init(route: String, order: Int, direction: Int, shapeID: String, points: [Coordinate]) {
    self.route = route
    self.order = order
    self.direction = direction
    self.shapeID = shapeID
    self.points = points
  }
}

/// A stretch of a route's overview line that keeps one lane. Drawn with a sideways offset of `lane` times a spacing, so
/// that routes sharing a street run next to each other, like the bands of a transit diagram.
public struct BundledLine: Sendable, Equatable {
  public let route: String
  /// 0 for a route alone on its street; otherwise steps to the right (positive) or left (negative) of the line's own
  /// direction. Fractional values are the short ramps between two lanes.
  public let lane: Double
  public let coordinates: [Coordinate]
}

/// Lays out an overview of all routes: one line per route (its directions and variants merged where they run along the
/// same streets) and, where routes share a street, a lane for each, side by side.
///
/// 1. Each route's shapes are merged: the longest is kept whole, and of the others only the parts more than `merge`
///    metres away from what is kept (a one-way street used in one direction only, a branch). Spikes out to a stop and
///    back are removed first.
/// 2. At every point of every line, the routes whose lines run within `corridor` metres and roughly parallel (within 30
///    degrees) form the bundle there. Each gets a lane by its order in the route list, centred on the street. The side
///    is measured against the bundle's first route, so that two routes running against each other still end up on
///    their own sides.
/// 3. Lanes are smoothed along each line (a majority over about 100 m, and no lane kept for less than `minRun` points),
///    and a change of lane is spread over `ramp` steps, so that the lines do not jump.
public enum RouteBundler {
  public static func overview(
    _ shapes: [BundleInput], step: Double = 20, merge: Double = 30, corridor: Double = 22, minRun: Int = 8, ramp: Int = 3
  ) -> [BundledLine] {
    let all = shapes.flatMap(\.points)
    guard !all.isEmpty else { return [] }
    let frame = Frame(latitude: all.map(\.latitude).reduce(0, +) / Double(all.count))
    let orderOfRoute = Dictionary(shapes.map { ($0.route, $0.order) }, uniquingKeysWith: min)

    // 1. One merged set of lines per route.
    var lines: [(route: String, points: [Point])] = []
    let byRoute = Dictionary(grouping: shapes, by: \.route)
    for route in byRoute.keys.sorted(by: { (orderOfRoute[$0] ?? .max, $0) < (orderOfRoute[$1] ?? .max, $1) }) {
      let candidates = byRoute[route]!
        .map { despike($0.points.map(frame.point)) }
        .map { densify($0, step: step) }
        .filter { $0.count > 1 }
        .sorted { length($0) > length($1) }
      var kept = SegmentIndex(cell: max(merge, corridor) * 2)
      for points in candidates {
        if kept.isEmpty {
          kept.insert(points, line: lines.count)
          lines.append((route, points))
          continue
        }
        let covered = points.map { kept.nearest($0, within: merge) != nil }
        var index = 0
        while index < points.count {
          guard !covered[index] else {
            index += 1
            continue
          }
          var end = index
          while end < points.count, !covered[end] { end += 1 }
          // The uncovered stretch, joined to the kept line at both ends.
          let run = Array(points[max(0, index - 1)..<min(points.count, end + 1)])
          if run.count > 1, length(run) >= 60 {
            kept.insert(run, line: lines.count)
            lines.append((route, run))
          }
          index = end
        }
      }
    }

    // 2. The bundle at every point.
    var everything = SegmentIndex(cell: max(merge, corridor) * 2)
    for (index, line) in lines.enumerated() { everything.insert(line.points, line: index) }
    var values: [[Double]] = []
    for (index, line) in lines.enumerated() {
      let points = line.points
      var lanes: [Double] = []
      for segment in 0..<(points.count - 1) {
        let here = midpoint(points[segment], points[segment + 1])
        let way = unit(points[segment], points[segment + 1])
        // Other routes along the same line nearby, with the direction of their line there.
        var members: [String: Point] = [line.route: way]
        for hit in everything.near(here, within: corridor) {
          let other = lines[hit.line]
          guard hit.line != index, other.route != line.route, members[other.route] == nil else { continue }
          let theirs = unit(other.points[hit.segment], other.points[hit.segment + 1])
          if abs(dot(way, theirs)) >= parallel { members[other.route] = theirs }
        }
        let sorted = members.keys.sorted { (orderOfRoute[$0] ?? .max, $0) < (orderOfRoute[$1] ?? .max, $1) }
        let rank = Double(sorted.firstIndex(of: line.route)!)
        let base = rank - Double(sorted.count - 1) / 2
        let reference = members[sorted[0]]!
        lanes.append(base * (dot(way, reference) >= 0 ? 1 : -1))
      }
      values.append(lanes)
    }

    // 3. Smooth, ramp and cut into runs.
    var result: [BundledLine] = []
    for (index, line) in lines.enumerated() {
      let smoothed = ramped(stable(majority(values[index], radius: 2), minRun: minRun), steps: ramp)
      var start = 0
      for segment in 1...smoothed.count {
        if segment == smoothed.count || smoothed[segment] != smoothed[start] {
          let points = line.points[start...segment].map(frame.coordinate)
          result.append(BundledLine(route: line.route, lane: smoothed[start], coordinates: points))
          start = segment
        }
      }
    }
    return result
  }

  // MARK: Smoothing

  /// The most common value within `radius` places on either side (ties keep the value itself).
  static func majority(_ values: [Double], radius: Int) -> [Double] {
    values.indices.map { index in
      var counts: [Double: Int] = [:]
      for other in max(0, index - radius)...min(values.count - 1, index + radius) { counts[values[other], default: 0] += 1 }
      let best = counts.values.max() ?? 0
      return counts[values[index]] == best ? values[index] : counts.first { $0.value == best }!.key
    }
  }

  /// Joins runs shorter than `minRun` to the longer of their neighbours, so that a lane never lasts only a few metres.
  /// Runs in the middle of a line go first; a short run at an end is only joined when nothing else is left to do.
  static func stable(_ values: [Double], minRun: Int) -> [Double] {
    var values = values
    for _ in 0..<values.count {
      var runs: [(value: Double, start: Int, count: Int)] = []
      for (index, value) in values.enumerated() {
        if let last = runs.last, last.value == value { runs[runs.count - 1].count += 1 } else { runs.append((value, index, 1)) }
      }
      guard runs.count > 1 else { break }
      let short = runs.indices.filter { runs[$0].count < minRun }
      let inside = short.filter { $0 > 0 && $0 < runs.count - 1 }
      guard let pick = (inside.isEmpty ? short : inside).min(by: { runs[$0].count < runs[$1].count }) else { break }
      let before = pick > 0 ? runs[pick - 1] : nil
      let after = pick < runs.count - 1 ? runs[pick + 1] : nil
      let fill = (before?.count ?? -1) >= (after?.count ?? -1) ? before!.value : after!.value
      for index in runs[pick].start..<(runs[pick].start + runs[pick].count) { values[index] = fill }
    }
    return values
  }

  /// Spreads every change of lane over the next `steps` places, in equal parts.
  static func ramped(_ values: [Double], steps: Int) -> [Double] {
    guard steps > 0, values.count > 1 else { return values }
    var result = values
    for index in 1..<values.count where values[index] != values[index - 1] {
      let from = values[index - 1], to = values[index]
      for step in 0..<steps where index + step < values.count && values[index + step] == to {
        result[index + step] = from + (to - from) * Double(step + 1) / Double(steps + 1)
      }
    }
    return result
  }

  // MARK: Geometry in metres

  struct Point: Equatable {
    var x: Double
    var y: Double
  }

  /// A flat frame in metres around the area's mean latitude, good enough for a city.
  private struct Frame {
    let scaleX: Double
    let scaleY = 111_320.0
    init(latitude: Double) { scaleX = 111_320 * cos(latitude * .pi / 180) }
    func point(_ c: Coordinate) -> Point { Point(x: c.longitude * scaleX, y: c.latitude * scaleY) }
    func coordinate(_ p: Point) -> Coordinate { Coordinate(latitude: p.y / scaleY, longitude: p.x / scaleX) }
  }

  private static let parallel = cos(30.0 * Double.pi / 180)

  private static func distance(_ a: Point, _ b: Point) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
  private static func midpoint(_ a: Point, _ b: Point) -> Point { Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
  private static func dot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }
  private static func unit(_ a: Point, _ b: Point) -> Point {
    let d = distance(a, b)
    return d > 0 ? Point(x: (b.x - a.x) / d, y: (b.y - a.y) / d) : Point(x: 0, y: 0)
  }
  private static func length(_ points: [Point]) -> Double {
    zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
  }

  static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return distance(p, a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return distance(p, Point(x: a.x + t * dx, y: a.y + t * dy))
  }

  /// Removes short excursions that go out and come back, such as a shape that steps aside to a stop.
  static func despike(_ points: [Point]) -> [Point] {
    var points = points.reduce(into: [Point]()) { if $0.last != $1 { $0.append($1) } }
    var changed = true
    while changed, points.count > 2 {
      changed = false
      var index = 1
      while index < points.count - 1 {
        let a = points[index - 1], b = points[index], c = points[index + 1]
        let out = distance(a, b) + distance(b, c)
        if out < 150, distance(a, c) < 0.25 * out {
          points.remove(at: index)
          changed = true
        } else {
          index += 1
        }
      }
    }
    return points
  }

  static func densify(_ points: [Point], step: Double) -> [Point] {
    guard let first = points.first else { return [] }
    var result = [first]
    for (a, b) in zip(points, points.dropFirst()) {
      let pieces = max(1, Int((distance(a, b) / step).rounded(.up)))
      for piece in 1...pieces {
        let t = Double(piece) / Double(pieces)
        result.append(Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
      }
    }
    return result
  }

  /// Segments of lines in a grid, to find the ones near a point quickly.
  struct SegmentIndex {
    let cell: Double
    private var cells: [Int64: [(line: Int, segment: Int, a: Point, b: Point)]] = [:]

    init(cell: Double) { self.cell = cell }

    var isEmpty: Bool { cells.isEmpty }

    private func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }

    mutating func insert(_ points: [Point], line: Int) {
      for segment in 0..<(points.count - 1) {
        let a = points[segment], b = points[segment + 1]
        let x0 = Int((min(a.x, b.x) / cell).rounded(.down)), x1 = Int((max(a.x, b.x) / cell).rounded(.down))
        let y0 = Int((min(a.y, b.y) / cell).rounded(.down)), y1 = Int((max(a.y, b.y) / cell).rounded(.down))
        for x in x0...x1 { for y in y0...y1 { cells[key(x, y), default: []].append((line, segment, a, b)) } }
      }
    }

    /// Segments within `radius` of `p` (`radius` must not exceed the cell size).
    func near(_ p: Point, within radius: Double) -> [(line: Int, segment: Int)] {
      let cx = Int((p.x / cell).rounded(.down)), cy = Int((p.y / cell).rounded(.down))
      var found: [(line: Int, segment: Int)] = []
      for x in (cx - 1)...(cx + 1) {
        for y in (cy - 1)...(cy + 1) {
          for item in cells[key(x, y)] ?? [] where RouteBundler.distance(from: p, toSegment: item.a, item.b) <= radius {
            found.append((item.line, item.segment))
          }
        }
      }
      return found
    }

    func nearest(_ p: Point, within radius: Double) -> (line: Int, segment: Int)? { near(p, within: radius).first }
  }
}
