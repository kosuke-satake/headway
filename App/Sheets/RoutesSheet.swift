import HeadwayCore
import SwiftUI

/// All routes: look at one on its own, hide the ones you never use, and keep favourites at the top.
struct RoutesSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        let favorites = model.orderedRoutes.filter { model.settings.isFavorite(route: $0.id) }
        if !favorites.isEmpty {
          Section("Favorites") { ForEach(favorites) { row($0) } }
        }
        Section {
          ForEach(model.orderedRoutes) { row($0) }
        } header: {
          Text("All routes")
        } footer: {
          Text("Tap a route to see only that route and its stops. Use the switch to hide a route from the map.")
        }
      }
      .navigationTitle("Routes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("Show all routes") { model.settings.values.hiddenRoutes = [] }
            Button("Hide all routes") { model.settings.values.hiddenRoutes = Set(model.orderedRoutes.map(\.id)) }
          } label: { Label("More", systemImage: "ellipsis.circle") }
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
      }
    }
  }

  private func row(_ route: Route) -> some View {
    let hidden = model.settings.values.hiddenRoutes.contains(route.id)
    return HStack(spacing: 12) {
      Button {
        model.toggleFocus(route: route.id)
        model.settings.setRoute(route.id, hidden: false)
        dismiss()
      } label: {
        HStack(spacing: 12) {
          RouteBadge(routeID: route.id)
          VStack(alignment: .leading, spacing: 2) {
            Text((model.headsignsByRoute[route.id] ?? []).map(\.prettyHeadsign).joined(separator: " · "))
              .font(.subheadline).lineLimit(2)
            if let match = model.reliability(route: route.id, stop: nil) {
              Text("Usually \(Int((match.cell.onTimeShare * 100).rounded()))% on time right now").font(.caption).foregroundStyle(.secondary)
            }
            if model.focusedRouteID == route.id { Text("Showing only this route").font(.caption).foregroundStyle(.blue) }
          }
          Spacer(minLength: 0)
        }
        .opacity(hidden ? 0.4 : 1)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Toggle("Show \(route.shortName) on the map", isOn: Binding(
        get: { !hidden }, set: { model.settings.setRoute(route.id, hidden: !$0) }))
        .labelsHidden()
    }
    .swipeActions(edge: .leading) {
      Button {
        model.settings.toggleFavorite(route: route.id)
      } label: {
        model.settings.isFavorite(route: route.id) ? Label("Unfavorite", systemImage: "star.slash") : Label("Favorite", systemImage: "star")
      }
      .tint(.orange)
    }
  }
}
