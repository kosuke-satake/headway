import Foundation

/// A route line with cumulative distances, so a point can be turned into "how far along the route".
public struct ShapeIndex: Sendable {
  public let points: [Coordinate]
  /// Metres from the start of the line to each point.
  public let cumulative: [Double]

  public init(_ points: [Coordinate]) {
    self.points = points
    var total = 0.0
    var cumulative = [0.0]
    for (previous, next) in zip(points, points.dropFirst()) {
      total += Geometry.distance(from: previous, to: next)
      cumulative.append(total)
    }
    self.cumulative = points.isEmpty ? [] : cumulative
  }

  public var length: Double { cumulative.last ?? 0 }

  public struct Projection: Sendable {
    /// Metres from the start of the line.
    public let along: Double
    /// Metres between the point and the line.
    public let offset: Double
    /// Index of the segment's first vertex.
    public let segment: Int
  }

  /// The nearest place on the line to `point`, looking only at segments `first ... last`.
  public func project(_ point: Coordinate, first: Int = 0, last: Int? = nil) -> Projection? {
    guard points.count > 1 else { return nil }
    let lower = max(0, min(first, points.count - 2))
    let upper = max(lower, min(last ?? (points.count - 2), points.count - 2))
    let cosine = cos(point.latitude * .pi / 180)
    let metersPerDegree = 111_320.0
    func xy(_ c: Coordinate) -> (Double, Double) {
      ((c.longitude - point.longitude) * metersPerDegree * cosine, (c.latitude - point.latitude) * metersPerDegree)
    }
    var best: Projection?
    var previous = xy(points[lower])
    for index in lower...upper {
      let next = xy(points[index + 1])
      let dx = next.0 - previous.0, dy = next.1 - previous.1
      let lengthSquared = dx * dx + dy * dy
      let t = lengthSquared == 0 ? 0 : min(1, max(0, -(previous.0 * dx + previous.1 * dy) / lengthSquared))
      let px = previous.0 + t * dx, py = previous.1 + t * dy
      let offset = (px * px + py * py).squareRoot()
      if best == nil || offset < best!.offset {
        let segmentLength = cumulative[index + 1] - cumulative[index]
        best = Projection(along: cumulative[index] + t * segmentLength, offset: offset, segment: index)
      }
      previous = next
    }
    return best
  }
}
