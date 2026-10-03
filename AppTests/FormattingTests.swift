import HeadwayCore
import Testing
import UIKit

@testable import Headway

@Suite struct FormattingTests {
  @Test func headsignsAreTidied() {
    #expect("UW HOSPITAL VIA REGENT".prettyHeadsign == "UW Hospital via Regent")
    #expect("E TOWNE MALL".prettyHeadsign == "E Towne Mall")
    #expect("FITCHBURG/CADDIS".prettyHeadsign == "Fitchburg/Caddis")
  }

  /// The wording is localised, so these tests check structure (which cases read the same, which differ, and that the
  /// minutes appear) rather than English text.
  @Test func delayWording() throws {
    #expect(TimeText.delay(nil) == nil)
    let onTime = try #require(TimeText.delay(0))
    #expect(TimeText.delay(20) == onTime)
    #expect(TimeText.delay(-25) == onTime)
    let late = try #require(TimeText.delay(125))
    let early = try #require(TimeText.delay(-190))
    #expect(late != onTime && early != onTime && late != early)
    #expect(late.contains("2"))
    #expect(early.contains("3"))
  }

  @Test func durations() {
    #expect(TimeText.duration(30).contains("1"))  // never "0 min"
    #expect(TimeText.duration(29 * 60 + 20).contains("29"))
    let long = TimeText.duration(65 * 60)
    #expect(long.contains("1") && long.contains("5"))
  }

  @Test func clockFormats() {
    let zone = TimeZone(identifier: "America/Chicago")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 20, minute: 5))!
    #expect(TimeText(timeZone: zone, clockFormat: .twentyFourHour, arrivalStyle: .clock).clock(evening) == "20:05")
    #expect(TimeText(timeZone: zone, clockFormat: .twelveHour, arrivalStyle: .clock).clock(evening) == "8:05 PM")
    let text = TimeText(timeZone: zone, clockFormat: .twelveHour, arrivalStyle: .clock)
    #expect(text.hourLabel(evening) == "8 PM")
    #expect(text.minuteLabel(evening) == "05")
  }
}

@Suite struct ColorTests {
  private func luminance(_ color: UIColor) -> Double {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: nil)
    return Double(0.2126 * r + 0.7152 * g + 0.0722 * b)
  }

  @Test func hexColours() {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    UIColor(hex: "FF8000").getRed(&r, green: &g, blue: &b, alpha: nil)
    #expect(abs(r - 1) < 0.01 && abs(g - 0.5) < 0.01 && b < 0.01)
  }

  @Test func darkMapLightensDarkColoursOnly() {
    let navy = UIColor(hex: "1B1B6B")
    #expect(luminance(RouteColors.forDarkMap(navy)) > luminance(navy) + 0.1)
    let sky = UIColor(hex: "56B4E9")
    #expect(luminance(RouteColors.forDarkMap(sky)) == luminance(sky))
  }

  @Test func textColourFollowsTheFill() {
    #expect(RouteColors.text(on: UIColor(hex: "FFFF00")) != .white)
    #expect(RouteColors.text(on: UIColor(hex: "101060")) == .white)
  }

  @Test func quietPaletteIsGreyForEveryRoute() {
    let route = Route(id: "A", shortName: "A", longName: "", colorHex: "FF0000", textColorHex: "FFFFFF", sortOrder: 1)
    #expect(RouteColors.fillHex(for: route, palette: .quiet, among: [route]) == "8E8E93")
    #expect(RouteColors.fillHex(for: route, palette: .agency, among: [route]) == "FF0000")
  }
}
