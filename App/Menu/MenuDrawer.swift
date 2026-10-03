import SwiftUI

/// The hamburger button that opens the menu.
struct MenuButton: View {
  @Environment(AppModel.self) private var model
  var plain = false

  var body: some View {
    Button {
      withAnimation(.snappy(duration: 0.28)) { model.menuOpen = true }
    } label: {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 17, weight: .medium))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(MenuButtonBackground(plain: plain))
    .accessibilityLabel(Text("Menu"))
  }
}

private struct MenuButtonBackground: ViewModifier {
  let plain: Bool

  func body(content: Content) -> some View {
    if plain {
      content
    } else {
      content
        .background(.regularMaterial, in: Circle())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
  }
}

/// A panel that slides in from the left with the app's modes and shortcuts.
struct MenuDrawer: View {
  @Environment(AppModel.self) private var model

  private var width: CGFloat { 304 }

  var body: some View {
    ZStack(alignment: .leading) {
      if model.menuOpen {
        Color.black.opacity(0.35)
          .ignoresSafeArea()
          .onTapGesture { close() }
          .transition(.opacity)
          .accessibilityHidden(true)
        panel
          .frame(width: width)
          .frame(maxHeight: .infinity)
          .background(.regularMaterial)
          .background(Color(.systemBackground).opacity(0.6))
          .ignoresSafeArea()
          .transition(.move(edge: .leading))
          .gesture(DragGesture().onEnded { if $0.translation.width < -40 { close() } })
      }
    }
    .animation(.snappy(duration: 0.28), value: model.menuOpen)
  }

  private func close() { model.menuOpen = false }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "bus.fill")
          .font(.title3.weight(.semibold)).foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(LinearGradient(colors: [Color(red: 0.18, green: 0.5, blue: 0.93), Color(red: 0.04, green: 0.18, blue: 0.51)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text("Headway").font(.title3.weight(.bold))
          Text("Madison Metro Transit").font(.footnote).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 20).padding(.top, 70).padding(.bottom, 22)

      VStack(spacing: 4) {
        modeRow(.map, title: "Map", subtitle: "Routes, stops and live buses", symbol: "map")
        modeRow(.info, title: "Service info", subtitle: "Delays, detours and cancellations", symbol: "exclamationmark.bubble", badge: model.visibleActiveAlerts.count)
        modeRow(.plan, title: "Plan a trip", subtitle: "Routes with transfers", symbol: "arrow.triangle.turn.up.right.diamond")
      }
      .padding(.horizontal, 12)

      Divider().padding(.vertical, 14).padding(.horizontal, 20)

      VStack(spacing: 4) {
        shortcut("Routes", symbol: "line.3.horizontal.decrease") { openSheet(.routes) }
        shortcut("Find a stop", symbol: "magnifyingglass") { openSheet(.search) }
        shortcut("Settings", symbol: "gearshape") { openSheet(.settings) }
      }
      .padding(.horizontal, 12)

      Spacer()

      Text("Data provided under license granted by City of Madison, WI, Metro Transit. Map © OpenStreetMap contributors.")
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.bottom, 28)
    }
  }

  private func modeRow(_ mode: AppMode, title: LocalizedStringKey, subtitle: LocalizedStringKey, symbol: String, badge: Int = 0) -> some View {
    let selected = model.mode == mode
    return Button {
      model.mode = mode
      close()
    } label: {
      HStack(spacing: 14) {
        Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(selected ? Color.accentColor : .primary)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.body.weight(selected ? .semibold : .regular))
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if badge > 0 {
          Text("\(badge)").font(.caption.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2).background(.orange, in: Capsule())
        }
        if selected { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.accentColor) }
      }
      .padding(.horizontal, 10).padding(.vertical, 10)
      .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func shortcut(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
    Button {
      action()
      close()
    } label: {
      HStack(spacing: 14) {
        Image(systemName: symbol).font(.body).frame(width: 28).foregroundStyle(.secondary)
        Text(title).font(.body)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10).padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// The routes, search and settings sheets live over the map, so go there first.
  private func openSheet(_ sheet: ActiveSheet) {
    model.mode = .map
    model.sheet = sheet
  }
}
