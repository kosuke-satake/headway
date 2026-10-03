import HeadwayCore
import SwiftUI

/// Find a stop by name or by the number printed on its sign.
struct SearchSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
          let favorites = model.settings.values.favoriteStops.compactMap { model.schedule?.stops[$0] }
          if !favorites.isEmpty { Section("Favorites") { ForEach(favorites) { row($0) } } }
          let recents = model.settings.values.recentStops.compactMap { model.schedule?.stops[$0] }
            .filter { !model.settings.isFavorite(stop: $0.id) }
          if !recents.isEmpty { Section("Recent") { ForEach(recents) { row($0) } } }
          let nearby = nearbyStops()
          if !nearby.isEmpty { Section("Nearby") { ForEach(nearby) { row($0) } } }
          if favorites.isEmpty, recents.isEmpty, nearby.isEmpty {
            Text("Search by stop name or stop number.").foregroundStyle(.secondary)
          }
        } else {
          let results = search(query)
          if results.isEmpty {
            ContentUnavailableView.search(text: query)
          } else {
            ForEach(results) { row($0) }
          }
        }
      }
      .navigationTitle("Find a stop")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stop name or number")
      .textInputAutocapitalization(.never)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
  }

  private func row(_ stop: Stop) -> some View {
    Button {
      model.selectStop(stop.id)
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(stop.name).font(.body).foregroundStyle(.primary)
          HStack(spacing: 4) {
            ForEach((model.routesByStop[stop.id] ?? []).prefix(8), id: \.self) { RouteBadge(routeID: $0, compact: true) }
          }
        }
        Spacer(minLength: 8)
        if !stop.code.isEmpty { Text(stop.code).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func search(_ query: String) -> [Stop] {
    guard let schedule = model.schedule else { return [] }
    let needle = query.trimmingCharacters(in: .whitespaces)
    let matches = schedule.stops.values.filter {
      $0.name.localizedStandardContains(needle) || $0.code.localizedCaseInsensitiveCompare(needle) == .orderedSame
        || $0.code.hasPrefix(needle)
    }
    return Array(matches.sorted { ($0.name, $0.code) < ($1.name, $1.code) }.prefix(60))
  }

  private func nearbyStops() -> [Stop] {
    guard let schedule = model.schedule, let here = model.location.location else { return [] }
    return schedule.stops.values
      .map { ($0, here.distance(from: .init(latitude: $0.latitude, longitude: $0.longitude))) }
      .filter { $0.1 < 800 }.sorted { $0.1 < $1.1 }.prefix(6).map(\.0)
  }
}
