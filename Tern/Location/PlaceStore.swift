import CoreLocation
import Foundation
import Observation

struct Place: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var visited = Date()

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Favorites and recent places, kept as JSON in UserDefaults. Small enough that a database
/// would be ceremony.
@MainActor
@Observable
final class PlaceStore {
    private(set) var favorites: [Place] = []
    private(set) var recents: [Place] = []

    private let defaults = UserDefaults.standard

    init() {
        favorites = load("favorites")
        recents = load("recents")
    }

    func addFavorite(_ coordinate: CLLocationCoordinate2D, name: String) {
        favorites.insert(Place(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude), at: 0)
        save(favorites, "favorites")
    }

    func removeFavorite(_ place: Place) {
        favorites.removeAll { $0.id == place.id }
        save(favorites, "favorites")
    }

    func isFavorite(_ coordinate: CLLocationCoordinate2D) -> Bool {
        favorites.contains { Geo.distance($0.coordinate, coordinate) < 5 }
    }

    func noteVisit(_ coordinate: CLLocationCoordinate2D, name: String) {
        recents.removeAll { Geo.distance($0.coordinate, coordinate) < 5 }
        recents.insert(Place(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude), at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        save(recents, "recents")
    }

    func clearRecents() {
        recents.removeAll()
        save(recents, "recents")
    }

    private func load(_ key: String) -> [Place] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Place].self, from: data)) ?? []
    }

    private func save(_ places: [Place], _ key: String) {
        defaults.set(try? JSONEncoder().encode(places), forKey: key)
    }
}
