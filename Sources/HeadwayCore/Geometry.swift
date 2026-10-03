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

extension Schedule {
  /// How far a bus is from the line its trip is supposed to follow, in metres. `nil` when the trip or its shape is
  /// unknown. A bus on a detour stays far from the line for as long as the detour lasts.
  public func distanceFromRoute(of vehicle: VehicleSample) -> Double? {
    guard let trip = trips[vehicle.tripID], let shape = shapes[trip.shapeID], shape.count > 1 else { return nil }
    return Geometry.distance(from: Coordinate(latitude: vehicle.latitude, longitude: vehicle.longitude), toLine: shape)
  }
}
