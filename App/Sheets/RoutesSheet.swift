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
          Text("Tap a route, or one of its directions, to see only that and its stops. Use the switch to hide a route from the map.")
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

  /// One route: a header that shows both directions, and one line per direction (they often use different streets).
  private func row(_ route: Route) -> some View {
    let hidden = model.settings.values.hiddenRoutes.contains(route.id)
    let variants = model.variants(of: route.id)
    return HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          model.settings.setRoute(route.id, hidden: false)
          model.focusRoute(route.id)
          dismiss()
        } label: {
          HStack(spacing: 12) {
            RouteBadge(routeID: route.id)
            VStack(alignment: .leading, spacing: 2) {
              Text(route.longName.isEmpty ? String(localized: "Both directions") : route.longName).font(.subheadline).lineLimit(2)
              if let match = model.reliability(route: route.id, stop: nil) {
                Text("Usually \(Int((match.cell.onTimeShare * 100).rounded()))% on time right now").font(.caption).foregroundStyle(.secondary)
              }
              if model.focus.routes == [route.id] {
                Text(model.focus.direction == nil ? "Showing both directions" : "Showing one direction").font(.caption).foregroundStyle(.blue)
              }
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(variants, id: \.direction) { variant in
          Button {
            model.settings.setRoute(route.id, hidden: false)
            model.focusRoute(route.id, direction: variant.direction)
            dismiss()
          } label: {
            Label(model.directionTitle(route: route.id, direction: variant.direction), systemImage: model.directionSymbol(route: route.id, direction: variant.direction))
              .font(.footnote)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
              .foregroundStyle(model.focus.routes == [route.id] && model.focus.direction == variant.direction ? Color.blue : Color.primary)
              .padding(.leading, 46)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .opacity(hidden ? 0.4 : 1)
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
