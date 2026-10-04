import Foundation

/// One route shape to be laid out next to the others that share its streets.
public struct BundleInput: Sendable {
  public let route: String
  /// Position of the route in the route list; lower comes first (and sits on the left of the bundle).
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

/// A stretch of a route's line that keeps one lane. Drawn with a sideways offset of `lane` times a spacing, so that routes
/// sharing a street run next to each other, like the bands of a transit diagram, instead of lying on top of each other.
public struct BundledLine: Sendable, Equatable {
  public let route: String
  public let direction: Int
  /// 0 for a route alone on its street; otherwise steps of 1 to the right (positive) or left (negative) of the line's
  /// direction of travel. Routes that share a street get different lanes, centred on the street.
  public let lane: Double
  public let coordinates: [Coordinate]
}

public enum RouteBundler {
  private struct Cell: Hashable {
    let lat: Int
    let lon: Int
  }

  /// Routes that run along the same line through a cell. A route crossing the street at an intersection is not part of
  /// the bundle, so it forms a group of its own and stays on the street.
  private struct Group {
    var routes: Set<String> = []
    /// The direction of travel of the first pass, which decides whether another pass is "along the same line".
    var reference: (x: Double, y: Double)
    var lanes: [String: Double] = [:]
  }

  /// Two passes are along the same line when their directions are within about 30 degrees of parallel (either way).
  private static let parallel = cos(30.0 * Double.pi / 180)

  /// Lanes are counted to the right of this direction (bearing 156 degrees, so that a street heading 66 or 246 degrees is
  /// where the side flips). A route going the other way along the same street gets the opposite sign, which puts it in
  /// the same lane on the same side whichever way each of them goes, and whichever cell they were first seen in. The
  /// flip direction is chosen away from the streets of Madison's grid and isthmus (0, 45, 90 and 135 degrees).
  private static let side: (x: Double, y: Double) = (sin(156.0 * Double.pi / 180), cos(156.0 * Double.pi / 180))
  /// - Parameters:
  ///   - step: shapes are subdivided to about this many metres, so that routes whose points sit in different places on
  ///     the same street still meet. It must be smaller than `cell`, in metres, so that no cell a line crosses is skipped.
  ///   - cell: two routes count as sharing a street when their lines pass through the same cell of this many degrees
  ///     (about 33 m by 24 m at Madison's latitude).
  public static func bundle(_ shapes: [BundleInput], step: Double = 20, cell: Double = 3e-4) -> [BundledLine] {
    let ordered = shapes.sorted { ($0.order, $0.direction, $0.shapeID) < ($1.order, $1.direction, $1.shapeID) }
    var orderOfRoute: [String: Int] = [:]
    for shape in ordered where orderOfRoute[shape.route] == nil { orderOfRoute[shape.route] = shape.order }

    func cellOf(_ point: Coordinate) -> Cell {
      Cell(lat: Int((point.latitude / cell).rounded(.down)), lon: Int((point.longitude / cell).rounded(.down)))
    }
    /// Direction of travel from `a` to `b`, in a flat local frame (east, north).
    func direction(_ a: Coordinate, _ b: Coordinate) -> (x: Double, y: Double) {
      let x = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180), y = b.latitude - a.latitude
      let length = (x * x + y * y).squareRoot()
      return length > 0 ? (x / length, y / length) : (0, 0)
    }

    // Subdivide every shape.
    var dense: [(shape: BundleInput, points: [Coordinate])] = []
    for shape in ordered where shape.points.count > 1 {
      var points = [shape.points[0]]
      for index in 1..<shape.points.count {
        let a = shape.points[index - 1], b = shape.points[index]
        let pieces = max(1, Int((Geometry.distance(from: a, to: b) / step).rounded(.up)))
        for piece in 1...pieces {
          let t = Double(piece) / Double(pieces)
          points.append(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t))
        }
      }
      dense.append((shape, points))
    }

    /// The group of `cell` that a pass in direction `way` belongs to, if there is one.
    func groupIndex(_ groups: [Group], _ way: (x: Double, y: Double)) -> Int? {
      groups.firstIndex { abs($0.reference.x * way.x + $0.reference.y * way.y) >= parallel }
    }

    // Which routes pass through each cell along each line, and which way the first of them went.
    var cells: [Cell: [Group]] = [:]
    for item in dense {
      for index in 0..<(item.points.count - 1) {
        let point = item.points[index]
        let way = direction(point, item.points[index + 1])
        guard way.x != 0 || way.y != 0 else { continue }
        let key = cellOf(point)
        var groups = cells[key] ?? []
        if let found = groupIndex(groups, way) {
          groups[found].routes.insert(item.shape.route)
        } else {
          groups.append(Group(routes: [item.shape.route], reference: way))
        }
        cells[key] = groups
      }
    }
    for (key, groups) in cells {
      var groups = groups
      for index in groups.indices {
        let sorted = groups[index].routes.sorted { (orderOfRoute[$0] ?? .max, $0) < (orderOfRoute[$1] ?? .max, $1) }
        for (position, route) in sorted.enumerated() { groups[index].lanes[route] = Double(position) - Double(sorted.count - 1) / 2 }
      }
      cells[key] = groups
    }

    // Cut every shape into runs that keep one lane.
    var result: [BundledLine] = []
    for item in dense {
      var run: [Coordinate] = [item.points[0]]
      var current: Double?
      for index in 1..<item.points.count {
        let from = item.points[index - 1]
        var value = current ?? 0
        let way = direction(from, item.points[index])
        if let groups = cells[cellOf(from)], let found = groupIndex(groups, way), let base = groups[found].lanes[item.shape.route] {
          value = base * (way.x * side.x + way.y * side.y >= 0 ? 1 : -1)
        }
        if let existing = current, existing != value {
          // The lane changes here: end the run at this point and start the next one from it.
          result.append(BundledLine(route: item.shape.route, direction: item.shape.direction, lane: existing, coordinates: dedupe(run)))
          run = [from]
        }
        current = value
        run.append(item.points[index])
      }
      result.append(BundledLine(route: item.shape.route, direction: item.shape.direction, lane: current ?? 0, coordinates: dedupe(run)))
    }
    return result.filter { $0.coordinates.count > 1 }
  }

  /// Drops points repeated one after the other.
  private static func dedupe(_ points: [Coordinate]) -> [Coordinate] {
    var result: [Coordinate] = []
    for point in points where result.last != point { result.append(point) }
    return result
  }
}
