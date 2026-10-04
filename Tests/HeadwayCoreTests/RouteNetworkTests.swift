import Foundation
import Testing

@testable import HeadwayCore

/// Route X runs east (direction 1) from A to B on one street and west (direction 0) from B to A on another street via
/// C, with two destinations westbound ("To Alpha" most trips, "To Airport" fewer).
private func makeNetworkSchedule() throws -> Schedule {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headway-net-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let files: [String: String] = [
    "agency.txt": "agency_id,agency_name,agency_timezone\n1,Test,America/Chicago\n",
    "routes.txt": "route_id,route_short_name,route_long_name,route_color,route_text_color,route_sort_order\nX,X,Ex,FF0000,FFFFFF,2\nY,Y,Why,00FF00,000000,1\n",
    "stops.txt": "stop_id,stop_code,stop_name,stop_lat,stop_lon\nA,1,Alpha,43.0,-89.4\nB,2,Bravo,43.0,-89.39\nC,3,Charlie,43.01,-89.395\n",
    "trips.txt": """
      trip_id,route_id,service_id,trip_headsign,trip_direction_name,direction_id,shape_id,block_id
      e1,X,wk,To Bravo,Eastbound,1,s,b1
      w1,X,wk,To Alpha,Westbound,0,s,b2
      w2,X,wk,To Alpha,Westbound,0,s,b3
      w3,X,wk,To Airport,Westbound,0,s,b4
      y1,Y,wk,To Charlie,Northbound,0,s,b5

      """,
    "stop_times.txt": """
      trip_id,arrival_time,departure_time,stop_id,stop_sequence
      e1,08:00:00,08:00:00,A,1
      e1,08:05:00,08:05:00,B,2
      w1,08:10:00,08:10:00,B,1
      w1,08:15:00,08:15:00,C,2
      w1,08:20:00,08:20:00,A,3
      w2,09:10:00,09:10:00,B,1
      w2,09:20:00,09:20:00,A,2
      w3,10:10:00,10:10:00,B,1
      w3,10:20:00,10:20:00,A,2
      y1,08:00:00,08:00:00,A,1
      y1,08:10:00,08:10:00,C,2

      """,
    "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\ns,43.0,-89.4,1\ns,43.0,-89.39,2\n",
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nwk,1,1,1,1,1,0,0,20261001,20261231\n",
  ]
  for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
  return try Schedule.load(directory: dir)
}

@Suite struct RouteNetworkTests {
  let network: RouteNetwork

  init() throws { network = RouteNetwork(schedule: try makeNetworkSchedule()) }

  @Test func routesAtAStopAreOrderedLikeTheRouteList() {
    // Y has sort order 1 and X has 2.
    #expect(network.routesByStop["A"] == ["Y", "X"])
    #expect(network.routesByStop["C"] == ["Y", "X"])
    #expect(network.routesByStop["B"] == ["X"])
  }

  @Test func eachDirectionHasItsOwnDestinationsAndName() throws {
    let west = try #require(network.variants.first { $0.route == "X" && $0.direction == 0 })
    #expect(west.directionName == "Westbound")
    #expect(west.headsigns == ["To Alpha", "To Airport"])  // 2 trips, then 1
    #expect(west.trips == 3)
    let east = try #require(network.variants.first { $0.route == "X" && $0.direction == 1 })
    #expect(east.directionName == "Eastbound")
    #expect(east.headsigns == ["To Bravo"])
  }

  @Test func variantsAreOrderedByRouteThenDirection() {
    #expect(network.variants.map { "\($0.route)\($0.direction)" } == ["Y0", "X0", "X1"])
    #expect(network.variants(of: "X").count == 2)
  }

  @Test func stopsDifferByDirection() {
    #expect(network.stops(route: "X", direction: 0) == ["A", "B", "C"])
    #expect(network.stops(route: "X", direction: 1) == ["A", "B"])
    #expect(network.stops(route: "X", direction: nil) == ["A", "B", "C"])
    #expect(network.stops(route: "Z", direction: 0).isEmpty)
  }

  @Test func survivesEncodingAndDecoding() throws {
    let data = try JSONEncoder().encode(network)
    #expect(try JSONDecoder().decode(RouteNetwork.self, from: data) == network)
  }
}
