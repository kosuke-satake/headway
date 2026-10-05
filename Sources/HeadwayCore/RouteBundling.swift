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
/// same streets) and, where routes share a street, a lane for each, side by side on one shared centre line.
///
/// 1. Each route's shapes are merged: the longest is kept whole, and of the others only the parts more than `merge`
///    metres away from what is kept (a one-way street used in one direction only, a branch). Spikes out to a stop and
///    back are removed first.
/// 2. The lines are laid onto a shared skeleton, route by route: where a line runs within `snap` metres of skeleton that
///    is already there, and roughly parallel to it, it follows that skeleton exactly; elsewhere its own points become new
///    skeleton. Every route on a street therefore follows the very same centre line, so that their lanes are parallel
///    (each feed draws the same street a few metres differently, which made lanes wobble).
/// 3. Each piece of skeleton knows the routes that use it. Each gets a lane by its order in the route list, centred on
///    the street, on the side measured against the skeleton's own direction, so that a route running the other way
///    keeps its side.
/// 4. Lanes are smoothed along each route (no lane kept for less than `minRun` pieces) and a change of lane is spread
///    over `ramp` pieces.
public enum RouteBundler {
  public static func overview(
    _ shapes: [BundleInput], step: Double = 10, merge: Double = 30, snap: Double = 18, minRun: Int = 12, ramp: Int = 6
  ) -> [BundledLine] {
    let all = shapes.flatMap(\.points)
    guard !all.isEmpty else { return [] }
    let frame = Frame(latitude: all.map(\.latitude).reduce(0, +) / Double(all.count))
    let orderOfRoute = Dictionary(shapes.map { ($0.route, $0.order) }, uniquingKeysWith: min)
    func ordered(_ a: String, _ b: String) -> Bool { (orderOfRoute[a] ?? .max, a) < (orderOfRoute[b] ?? .max, b) }

    // 1. One merged set of lines per route.
    var lines: [(route: String, points: [Point])] = []
    let byRoute = Dictionary(grouping: shapes, by: \.route)
    for route in byRoute.keys.sorted(by: ordered) {
      let candidates = byRoute[route]!
        .map { despike($0.points.map(frame.point)) }
        .map { densify($0, step: step) }
        .filter { $0.count > 1 }
        .sorted { length($0) > length($1) }
      var kept = SegmentIndex(cell: merge * 2)
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

    // 2. The shared skeleton, and each line as a walk along it.
    var skeleton: [[Point]] = []
    var index = SegmentIndex(cell: max(snap * 2, 40))
    var walks: [(route: String, positions: [Position])] = []
    for line in lines {
      let points = line.points
      var snapped: [Position?] = points.indices.map { i in
        let way = tangent(points, i)
        var best: (position: Position, distance: Double)?
        for hit in index.near(points[i], within: snap) {
          let a = skeleton[hit.line][hit.segment], b = skeleton[hit.line][hit.segment + 1]
          guard abs(dot(way, unit(a, b))) >= parallel else { continue }
          let (t, d) = project(points[i], a, b)
          if best == nil || d < best!.distance { best = (Position(line: hit.line, segment: hit.segment, t: t), d) }
        }
        return best?.position
      }
      // A point or two that does not snap between points that do is noise (a stop a little off the street), and a point
      // or two that snaps between points that do not is a crossing: neither changes what the line does.
      snapped = cleaned(snapped, points: points, skeleton: skeleton, index: index, snap: snap)

      var positions: [Position] = []
      var i = 0
      while i < points.count {
        if let position = snapped[i] {
          positions.append(position)
          i += 1
          continue
        }
        var end = i
        while end < points.count, snapped[end] == nil { end += 1 }
        // A stretch on its own becomes skeleton, joined to the skeleton points before and after it.
        var piece: [Point] = []
        if let before = positions.last { piece.append(location(before, skeleton)) }
        piece += points[i..<end]
        if end < points.count, let after = snapped[end] { piece.append(location(after, skeleton)) }
        let id = skeleton.count
        skeleton.append(piece)
        index.insert(piece, line: id)
        let first = positions.isEmpty ? 0 : 1
        for vertex in first..<(first + (end - i)) {
          positions.append(Position(line: id, segment: min(vertex, piece.count - 2), t: vertex == piece.count - 1 ? 1 : 0))
        }
        i = end
      }
      walks.append((line.route, positions))
    }

    // 3. Who uses each piece of skeleton, and in which direction; then each route's pieces in order.
    struct Piece {
      var from: Point
      var to: Point
      var key: Int?  // skeleton line << 32 | segment; nil for a short link between two skeleton lines
      var sign: Double
    }
    var users: [Int: [String: Double]] = [:]  // route -> the direction of its first pass (1 along the skeleton, -1 against)
    var routePieces: [(route: String, pieces: [Piece])] = []
    for walk in walks {
      var pieces: [Piece] = []
      for (p, q) in zip(walk.positions, walk.positions.dropFirst()) {
        guard p.line == q.line else {
          pieces.append(Piece(from: location(p, skeleton), to: location(q, skeleton), key: nil, sign: 1))
          continue
        }
        let line = skeleton[p.line]
        let forward = (q.segment, q.t) >= (p.segment, p.t)
        var stops: [(point: Point, segment: Int)] = [(location(p, skeleton), p.segment)]
        if forward {
          if q.segment > p.segment { for vertex in (p.segment + 1)...q.segment { stops.append((line[vertex], vertex)) } }
        } else if p.segment > q.segment {
          for vertex in stride(from: p.segment, through: q.segment + 1, by: -1) { stops.append((line[vertex], vertex - 1)) }
        }
        stops.append((location(q, skeleton), q.segment))
        for (a, b) in zip(stops, stops.dropFirst()) where distance(a.point, b.point) > 0.01 {
          let segment = forward ? a.segment : b.segment
          let key = p.line << 32 | segment
          if users[key, default: [:]][walk.route] == nil { users[key, default: [:]][walk.route] = forward ? 1 : -1 }
          pieces.append(Piece(from: a.point, to: b.point, key: key, sign: forward ? 1 : -1))
        }
      }
      routePieces.append((walk.route, pieces))
    }

    // 4. Lanes, smoothed, eased from one to the next, and cut into runs.
    var result: [BundledLine] = []
    for (route, pieces) in routePieces where !pieces.isEmpty {
      var values: [Double] = []
      for piece in pieces {
        guard let key = piece.key, let routes = users[key] else {
          values.append(values.last ?? 0)
          continue
        }
        let sorted = routes.keys.sorted(by: ordered)
        let lane = Double(sorted.firstIndex(of: route)!) - Double(sorted.count - 1) / 2
        // Sides are counted along the way the bundle's first route goes, so that the order of the routes is the same
        // whichever way the skeleton line happens to run.
        values.append(lane * piece.sign * routes[sorted[0]]!)
      }
      let target = stable(values, minRun: minRun)

      // Pieces with their offsets; a change of lane is spread over `ramp` pieces, each cut in `split` small steps, so
      // that the line slides across instead of jumping.
      // Near a turn the change is made at once instead: sliding sideways while turning draws hooks, and the corner hides
      // the step.
      let split = 4
      let headings = pieces.map { unit($0.from, $0.to) }
      func turnsNear(_ index: Int, _ count: Int) -> Bool {
        let low = max(1, index - 3), high = min(pieces.count - 1, index + count + 1)
        guard low <= high else { return false }
        for k in low...high where dot(headings[k], headings[k - 1]) < cos(35.0 * .pi / 180) { return true }
        return false
      }
      var drawn: [(from: Point, to: Point, lane: Double)] = []
      var i = 0
      while i < pieces.count {
        if i > 0, target[i] != target[i - 1], !turnsNear(i, ramp) {
          let a = target[i - 1], b = target[i]
          var n = 0
          while n < ramp, i + n < pieces.count, target[i + n] == b { n += 1 }
          let steps = Double(n * split)
          var step = 0.0
          for k in i..<(i + n) {
            for part in 0..<split {
              step += 1
              let from = lerp(pieces[k].from, pieces[k].to, Double(part) / Double(split))
              let to = lerp(pieces[k].from, pieces[k].to, Double(part + 1) / Double(split))
              drawn.append((from, to, a + (b - a) * step / steps))
            }
          }
          i += n
          continue
        }
        drawn.append((pieces[i].from, pieces[i].to, target[i]))
        i += 1
      }

      var start = 0
      for position in 1...drawn.count {
        if position == drawn.count || drawn[position].lane != drawn[start].lane {
          var points = [drawn[start].from]
          for piece in drawn[start..<position] { points.append(piece.to) }
          result.append(BundledLine(route: route, lane: drawn[start].lane, coordinates: dedupe(points).map(frame.coordinate)))
          start = position
        }
      }
    }
    return result.filter { $0.coordinates.count > 1 }
  }

  private static func lerp(_ a: Point, _ b: Point, _ t: Double) -> Point { Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

  /// A place on the skeleton: on `segment` of skeleton line `line`, `t` of the way along it.
  struct Position {
    var line: Int
    var segment: Int
    var t: Double
  }

  private static func location(_ position: Position, _ skeleton: [[Point]]) -> Point {
    let a = skeleton[position.line][position.segment], b = skeleton[position.line][position.segment + 1]
    return Point(x: a.x + (b.x - a.x) * position.t, y: a.y + (b.y - a.y) * position.t)
  }

  /// Where `p` falls on the segment from `a` to `b` (0...1), and how far it is from it.
  private static func project(_ p: Point, _ a: Point, _ b: Point) -> (t: Double, distance: Double) {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return (0, distance(p, a)) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return (t, distance(p, Point(x: a.x + t * dx, y: a.y + t * dy)))
  }

  /// The direction of a line at point `i`, from its neighbours.
  private static func tangent(_ points: [Point], _ i: Int) -> Point {
    unit(points[max(0, i - 1)], points[min(points.count - 1, i + 1)])
  }

  /// Short gaps in snapping are filled, and short snapped blips are dropped.
  ///
  /// A gap of up to 8 points (about 80 m) between two points on the same skeleton line is a bus bay or a loop into a
  /// stop: the line simply follows the skeleton there. Other gaps of up to 3 points are filled from a little farther
  /// away. A snapped blip of up to 3 points between unsnapped ones is a crossing street, not a shared one.
  private static func cleaned(_ snapped: [Position?], points: [Point], skeleton: [[Point]], index: SegmentIndex, snap: Double) -> [Position?] {
    var result = snapped
    var i = 0
    while i < result.count {
      let isSnapped = result[i] != nil
      var end = i
      while end < result.count, (result[end] != nil) == isSnapped { end += 1 }
      let inside = i > 0 && end < result.count
      if inside, isSnapped, end - i <= 3 {
        for k in i..<end { result[k] = nil }
      } else if inside, !isSnapped, let before = result[i - 1], let after = result[end], before.line == after.line, end - i <= 8 {
        let line = skeleton[before.line]
        let low = min(before.segment, after.segment), high = max(before.segment, after.segment)
        for k in i..<end {
          var best: (position: Position, distance: Double)?
          for segment in low...high {
            let (t, d) = project(points[k], line[segment], line[segment + 1])
            if best == nil || d < best!.distance { best = (Position(line: before.line, segment: segment, t: t), d) }
          }
          if let best, best.distance <= 50 { result[k] = best.position }
        }
      } else if inside, !isSnapped, end - i <= 3 {
        for k in i..<end {
          let way = tangent(points, k)
          var best: (position: Position, distance: Double)?
          for hit in index.near(points[k], within: snap * 1.7) {
            let a = skeleton[hit.line][hit.segment], b = skeleton[hit.line][hit.segment + 1]
            guard abs(dot(way, unit(a, b))) >= parallel else { continue }
            let (t, d) = project(points[k], a, b)
            if d <= snap * 1.7, best == nil || d < best!.distance { best = (Position(line: hit.line, segment: hit.segment, t: t), d) }
          }
          if let best { result[k] = best.position }
        }
      }
      i = end
    }
    return result
  }

  private static func dedupe(_ points: [Point]) -> [Point] {
    var result: [Point] = []
    for point in points where result.last.map({ distance($0, point) > 0.01 }) ?? true { result.append(point) }
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
