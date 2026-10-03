import HeadwayCore
import UIKit

/// Colours for the map layers that sit on top of the basemap.
struct MapTheme {
  let isDark: Bool
  let routeCasing: UIColor
  let stopFill: UIColor
  let stopStroke: UIColor
  let labelText: UIColor
  let labelHalo: UIColor
  let busRing: UIColor

  static func make(dark: Bool) -> MapTheme {
    dark
      ? MapTheme(
        isDark: true, routeCasing: UIColor(white: 0.08, alpha: 1), stopFill: UIColor(white: 0.12, alpha: 1),
        stopStroke: UIColor(white: 0.92, alpha: 1), labelText: UIColor(white: 0.93, alpha: 1),
        labelHalo: UIColor(white: 0.1, alpha: 1), busRing: UIColor(white: 0.08, alpha: 1))
      : MapTheme(
        isDark: false, routeCasing: .white, stopFill: .white, stopStroke: UIColor(white: 0.25, alpha: 1),
        labelText: UIColor(white: 0.15, alpha: 1), labelHalo: .white, busRing: .white)
  }
}

/// Route colours for each palette, with a readable text colour for every fill.
enum RouteColors {
  /// Okabe-Ito based colours plus a few extra hues, all distinguishable under common colour-vision deficiencies
  /// when paired with the route letter on the bus marker.
  private static let distinct: [String] = [
    "0072B2", "E69F00", "009E73", "D55E00", "CC79A7", "56B4E9", "6A3D9A", "B15928",
    "1B7837", "F0E442", "762A83", "E31A1C", "2D2D2D", "FB9A99",
  ]
  private static let quiet = "8E8E93"

  static func fillHex(for route: Route, palette: RoutePalette, among routes: [Route]) -> String {
    switch palette {
    case .agency:
      return route.colorHex
    case .quiet:
      return quiet
    case .distinct:
      let ordered = routes.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
      let index = ordered.firstIndex { $0.id == route.id } ?? 0
      return distinct[index % distinct.count]
    }
  }

  static func fill(for route: Route, palette: RoutePalette, among routes: [Route]) -> UIColor {
    UIColor(hex: fillHex(for: route, palette: palette, among: routes))
  }

  /// Dark colours disappear on the dark basemap, so they are mixed towards white until they stand out.
  static func forDarkMap(_ color: UIColor) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: nil)
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    guard luminance < 0.4 else { return color }
    let mix = min(0.65, (0.4 - luminance) * 2.2)
    return UIColor(red: r + (1 - r) * mix, green: g + (1 - g) * mix, blue: b + (1 - b) * mix, alpha: 1)
  }

  /// Black or white, whichever reads better on `fill`.
  static func text(on fill: UIColor) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    fill.getRed(&r, green: &g, blue: &b, alpha: nil)
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    return luminance > 0.4 ? UIColor(white: 0.1, alpha: 1) : .white
  }
}

extension UIColor {
  /// `RRGGBB` without a leading `#`.
  convenience init(hex: String) {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    self.init(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1)
  }
}
