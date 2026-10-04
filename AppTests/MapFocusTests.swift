import Foundation
import HeadwayCore
import Testing
import UIKit

@testable import Headway

@Suite struct MapFocusTests {
  private static func overlay() -> MapOverlay {
    let routes = [
      MapOverlayData.RouteInfo(id: "A", shortName: "A", longName: "Route A", colorHex: "FF0000", textColorHex: "FFFFFF", sortOrder: 1),
      MapOverlayData.RouteInfo(id: "B", shortName: "B", longName: "Route B", colorHex: "00AA00", textColorHex: "FFFFFF", sortOrder: 2),
    ]
    let lines = [
      MapOverlayData.Line(route: "A", direction: 0, latitudes: [43.0, 43.1, 43.2], longitudes: [-89.5, -89.4, -89.3]),
      MapOverlayData.Line(route: "A", direction: 1, lane: 0.5, latitudes: [43.2, 43.0], longitudes: [-89.3, -89.5]),
      MapOverlayData.Line(route: "B", direction: 0, latitudes: [44.0, 44.1], longitudes: [-90.0, -90.1]),
    ]
    let stops = [MapOverlayData.StopInfo(id: "s1", name: "First", code: "1001", latitude: 43.0, longitude: -89.5)]
    let network = RouteNetwork(
      routesByStop: ["s1": ["A"]],
      variants: [
        RouteVariant(route: "A", direction: 0, directionName: "Eastbound", headsigns: ["EAST"], trips: 10),
        RouteVariant(route: "A", direction: 1, directionName: "Westbound", headsigns: ["WEST"], trips: 10),
      ],
      stopsByDirection: ["A|0": ["s1"], "A|1": []])
    return MapOverlay(MapOverlayData(feedVersion: "v1", routes: routes, lines: lines, stops: stops, network: network))
  }

  private func look(_ id: String, focus: MapFocus, style: FocusStyle, hidden: Set<String> = []) -> RouteLook {
    var state = MapState()
    state.overlay = Self.overlay()
    state.focus = focus
    state.prefs.focusStyle = style
    state.prefs.hiddenRoutes = hidden
    return RouteLook.make(route: state.overlay!.routes[id]!, state: state)
  }

  @Test func withoutFocusEveryRouteShows() {
    #expect(look("A", focus: MapFocus(), style: .hide).visible)
    #expect(look("B", focus: MapFocus(), style: .hide).opacity == 1)
  }

  @Test func hidingRemovesTheOtherRoutes() {
    #expect(look("A", focus: .route("A"), style: .hide).visible)
    #expect(!look("B", focus: .route("A"), style: .hide).visible)
  }

  @Test func fadingKeepsTheOtherRoutesFaintly() {
    let other = look("B", focus: .route("A"), style: .dim)
    #expect(other.visible)
    #expect(other.opacity < 0.3)
    #expect(look("A", focus: .route("A"), style: .dim).opacity == 1)
  }

  @Test func aFocusedRouteShowsEvenWhenHidden() {
    #expect(look("A", focus: .route("A"), style: .hide, hidden: ["A"]).visible)
    // A hidden route stays hidden when it is only part of the background.
    #expect(!look("B", focus: .route("A"), style: .dim, hidden: ["B"]).visible)
  }

  @Test func overlaySurvivesTheSavedCopy() throws {
    let data = Self.overlay().data
    let bytes = try PropertyListEncoder().encode(data)
    let back = try PropertyListDecoder().decode(MapOverlayData.self, from: bytes)
    #expect(back == data)
    #expect(MapOverlay(back).orderedRoutes.map(\.id) == ["A", "B"])
  }

  @Test func overlayCoordinatesFollowTheDirection() {
    let overlay = Self.overlay()
    let both = overlay.coordinates(route: "A", direction: nil)
    let east = overlay.coordinates(route: "A", direction: 0)
    let west = overlay.coordinates(route: "A", direction: 1)
    #expect(east.count + west.count == both.count)
    #expect(east.first?.latitude == 43.0)
    #expect(west.first?.latitude == 43.2)
    #expect(overlay.coordinates(route: "Z", direction: nil).isEmpty)
  }
}
