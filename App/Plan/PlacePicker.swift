import HeadwayCore
import MapKit
import SwiftUI

/// Choose a place: your location, a stop, or (with a connection) a place found by name.
struct PlacePicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  let allowsMyLocation: Bool
  let title: LocalizedStringKey
  let onPick: (PlaceChoice) -> Void

  @State private var query = ""
  @State private var places: [PlanPoint] = []
  @State private var placeSearchFailed = false
  @State private var searchTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      List {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
          emptyQuery
        } else {
          searchResults
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stop, place or address")
      .textInputAutocapitalization(.never)
      .onChange(of: query) { _, value in scheduleSearch(value) }
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
    }
    .presentationDetents([.large])
  }

  // MARK: Sections

  @ViewBuilder private var emptyQuery: some View {
    if allowsMyLocation {
      Section {
        Button { pick(.myLocation) } label: {
          Label("My location", systemImage: "location.fill")
        }
        if model.location.isDenied {
          Text("Location is turned off for Headway. You can turn it on in Settings.").font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
    let favorites = model.settings.values.favoriteStops.compactMap { model.schedule?.stops[$0] }
    if !favorites.isEmpty { Section("Favorites") { ForEach(favorites) { stopRow($0) } } }
    let recents = model.settings.values.recentStops.compactMap { model.schedule?.stops[$0] }.filter { !model.settings.isFavorite(stop: $0.id) }
    if !recents.isEmpty { Section("Recent") { ForEach(recents) { stopRow($0) } } }
    if favorites.isEmpty, recents.isEmpty {
      Text("Search for a bus stop, or for a place such as a building or an address.").foregroundStyle(.secondary).font(.footnote)
    }
  }

  @ViewBuilder private var searchResults: some View {
    let stops = matchingStops()
    if !stops.isEmpty { Section("Bus stops") { ForEach(stops) { stopRow($0) } } }
    Section {
      if places.isEmpty {
        Text(placeSearchFailed ? "Place search needs a connection." : "Searching places…")
          .font(.footnote).foregroundStyle(.secondary)
      }
      ForEach(places, id: \.name) { place in
        Button { pick(.point(place)) } label: {
          Label(place.name, systemImage: "mappin.and.ellipse").foregroundStyle(.primary)
        }
      }
    } header: {
      Text("Places")
    } footer: {
      Text("Place names are looked up with Apple Maps, which needs a connection.")
    }
  }

  private func stopRow(_ stop: Stop) -> some View {
    Button {
      pick(.point(PlanPoint(name: stop.name, coordinate: Coordinate(latitude: stop.latitude, longitude: stop.longitude), stopID: stop.id)))
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "bus").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text(stop.name).foregroundStyle(.primary)
          HStack(spacing: 4) { ForEach(model.visibleRoutes(atStop: stop.id).prefix(8), id: \.self) { RouteBadge(routeID: $0, compact: true) } }
        }
        Spacer(minLength: 8)
        if !stop.code.isEmpty { Text(stop.code).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: Logic

  private func pick(_ choice: PlaceChoice) {
    onPick(choice)
    dismiss()
  }

  private func matchingStops() -> [Stop] {
    guard let schedule = model.schedule else { return [] }
    let needle = query.trimmingCharacters(in: .whitespaces)
    return Array(
      schedule.stops.values
        .filter { $0.name.localizedStandardContains(needle) || $0.code.hasPrefix(needle) }
        .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
        .prefix(15))
  }

  /// Looks places up with MapKit after the rider pauses typing.
  private func scheduleSearch(_ value: String) {
    searchTask?.cancel()
    places = []
    placeSearchFailed = false
    let text = value.trimmingCharacters(in: .whitespaces)
    guard text.count >= 3 else { return }
    searchTask = Task {
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = text
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4))
      do {
        let response = try await MKLocalSearch(request: request).start()
        guard !Task.isCancelled else { return }
        places = response.mapItems.prefix(8).compactMap { item in
          guard let name = item.name else { return nil }
          let coordinate = item.placemark.coordinate
          // Keep results inside the area the buses serve.
          guard abs(coordinate.latitude - 43.07) < 0.3, abs(coordinate.longitude + 89.4) < 0.4 else { return nil }
          return PlanPoint(name: name, coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        placeSearchFailed = places.isEmpty
      } catch {
        if !Task.isCancelled { placeSearchFailed = true }
      }
    }
  }
}
