import SwiftUI

/// Favorites and recent places; clicking one hands the coordinate to the current mode.
struct PlacesPopover: View {
    @Environment(PlaceStore.self) private var places
    @Environment(Simulator.self) private var simulator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if places.favorites.isEmpty && places.recents.isEmpty {
                Text(String(localized: "Star a place to keep it here. Searches show up under Recent."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
            if !places.favorites.isEmpty {
                SectionTitle(String(localized: "Favorites"))
                ForEach(places.favorites) { place in
                    row(place, symbol: "star.fill", tint: .yellow) { places.removeFavorite(place) }
                }
            }
            if !places.recents.isEmpty {
                HStack {
                    SectionTitle(String(localized: "Recent"))
                    Spacer()
                    Button(String(localized: "Clear")) { places.clearRecents() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(places.recents.prefix(12)) { place in
                    row(place, symbol: "clock", tint: .secondary, remove: nil)
                }
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func row(_ place: Place, symbol: String, tint: Color, remove: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Button {
                simulator.handleTap(place.coordinate)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).font(.callout).lineLimit(1)
                    Text(Geo.format(place.coordinate)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
    }
}
