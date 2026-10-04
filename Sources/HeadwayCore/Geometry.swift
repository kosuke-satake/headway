import Foundation

/// Distances on the Earth's surface, accurate enough at city scale.
public enum Geometry {
  private static let metersPerDegree = 111_320.0

  /// Great-circle distance in metres (haversine).
  public static func distance(from a: Coordinate, to b: Coordinate) -> Double {
    let radius = 6_371_000.0
    let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
    let dLat = lat2 - lat1
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * radius * asin(min(1, h.squareRoot()))
  }

  /// Distance in metres from `point` to the nearest part of the polyline `line`, and the index of the segment's
  /// starting vertex where that happens.
  public static func nearest(on line: [Coordinate], to point: Coordinate) -> (distance: Double, index: Int) {
    guard line.count > 1 else {
      return (line.first.map { distance(from: point, to: $0) } ?? .greatestFiniteMagnitude, 0)
    }
    let cosine = cos(point.latitude * .pi / 180)
    func xy(_ c: Coordinate) -> (Double, Double) {
      ((c.longitude - point.longitude) * metersPerDegree * cosine, (c.latitude - point.latitude) * metersPerDegree)
    }
    var best = (distance: Double.greatestFiniteMagnitude, index: 0)
    var previous = xy(line[0])
    for index in 1..<line.count {
      let next = xy(line[index])
      let dx = next.0 - previous.0, dy = next.1 - previous.1
      let lengthSquared = dx * dx + dy * dy
      var t = lengthSquared == 0 ? 0 : -(previous.0 * dx + previous.1 * dy) / lengthSquared
      t = min(1, max(0, t))
      let px = previous.0 + t * dx, py = previous.1 + t * dy
      let d = (px * px + py * py).squareRoot()
      if d < best.distance { best = (d, index - 1) }
      previous = next
    }
    return best
  }

  public static func distance(from point: Coordinate, toLine line: [Coordinate]) -> Double {
    nearest(on: line, to: point).distance
  }
}

extension Geometry {
  /// The polyline from the point on `line` nearest to `point`, forward along the line for `meters`.
  /// Returns at least two coordinates, or `nil` when `line` has fewer than two points or `meters` is not positive.
  public static func pathAhead(on line: [Coordinate], from point: Coordinate, meters: Double) -> [Coordinate]? {
    guard line.count > 1, meters > 0 else { return nil }
    let near = nearest(on: line, to: point)
    let a = line[near.index], b = line[near.index + 1]
    // Project the point onto the segment (equirectangular, fine at city scale).
    let cosine = cos(point.latitude * .pi / 180)
    let ax = (a.longitude - point.longitude) * metersPerDegree * cosine, ay = (a.latitude - point.latitude) * metersPerDegree
    let bx = (b.longitude - point.longitude) * metersPerDegree * cosine, by = (b.latitude - point.latitude) * metersPerDegree
    let dx = bx - ax, dy = by - ay
    let lengthSquared = dx * dx + dy * dy
    let t = lengthSquared == 0 ? 0 : min(1, max(0, -(ax * dx + ay * dy) / lengthSquared))
    let start = Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)

    var path = [start]
    var remaining = meters
    var current = start
    var index = near.index + 1
    while remaining > 0, index < line.count {
      let next = line[index]
      let segment = distance(from: current, to: next)
      if segment >= remaining {
        let f = segment == 0 ? 0 : remaining / segment
        path.append(Coordinate(
          latitude: current.latitude + (next.latitude - current.latitude) * f,
          longitude: current.longitude + (next.longitude - current.longitude) * f))
        return path
      }
      remaining -= segment
      path.append(next)
      current = next
      index += 1
    }
    return path.count > 1 ? path : [start, start]
  }

  /// The point `meters` along `path` from its start (clamped to the ends).
  public static func point(on path: [Coordinate], at meters: Double) -> Coordinate {
    guard var current = path.first else { return Coordinate(latitude: 0, longitude: 0) }
    var remaining = max(0, meters)
    for next in path.dropFirst() {
      let segment = distance(from: current, to: next)
      if segment >= remaining {
        let f = segment == 0 ? 0 : remaining / segment
        return Coordinate(
          latitude: current.latitude + (next.latitude - current.latitude) * f,
          longitude: current.longitude + (next.longitude - current.longitude) * f)
      }
      remaining -= segment
      current = next
    }
    return current
  }
}

extension Schedule {
  /// Where the bus probably is `seconds` after its report, if it keeps going along its route at the reported speed.
  /// Returns the path ahead of the report; `nil` for buses that are standing still, off their route, or have no speed.
  public func pathAhead(of vehicle: VehicleSample, seconds: Double) -> [Coordinate]? {
    guard let speed = vehicle.speed, speed > 0.5, let trip = trips[vehicle.tripID], let shape = shapes[trip.shapeID], shape.count > 1
    else { return nil }
    let point = Coordinate(latitude: vehicle.latitude, longitude: vehicle.longitude)
    // Only extrapolate buses that are on their line: a bus on a detour could be anywhere.
    guard Geometry.distance(from: point, toLine: shape) < 60 else { return nil }
    return Geometry.pathAhead(on: shape, from: point, meters: speed * seconds)
  }
}

extension Schedule {
  /// How far a bus is from the line its trip is supposed to follow, in metres. `nil` when the trip or its shape is
  /// unknown. A bus on a detour stays far from the line for as long as the detour lasts.
  public func distanceFromRoute(of vehicle: VehicleSample) -> Double? {
    guard let trip = trips[vehicle.tripID], let shape = shapes[trip.shapeID], shape.count > 1 else { return nil }
    return Geometry.distance(from: Coordinate(latitude: vehicle.latitude, longitude: vehicle.longitude), toLine: shape)
  }
}
