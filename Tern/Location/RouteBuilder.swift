import CoreLocation
import Foundation
import MapKit

/// Turns waypoints into a road-following track with Apple's directions, and reads GPX files.
enum RouteBuilder {
    enum Transport: String, CaseIterable, Identifiable {
        case walking, driving, straight
        var id: String { rawValue }

        var label: String {
            switch self {
            case .walking: String(localized: "Walking")
            case .driving: String(localized: "Driving")
            case .straight: String(localized: "Straight")
            }
        }

        var symbol: String {
            switch self {
            case .walking: "figure.walk"
            case .driving: "car"
            case .straight: "line.diagonal"
            }
        }
    }

    /// Falls back to a straight segment when directions fail (no road data, offline, sea…),
    /// so a route always comes back instead of an error the user cannot act on.
    struct Result {
        var track: Track
        /// Apple's travel-time estimate for the whole route, which includes live traffic for
        /// driving at the moment the route was built. Nil when any leg fell back to a straight line.
        var expectedSeconds: Double?
    }

    struct Options: Equatable {
        var transport: Transport = .driving
        var avoidTolls = false
        var avoidHighways = false
    }

    static func track(through waypoints: [CLLocationCoordinate2D], options: Options) async -> Result {
        let transport = options.transport
        guard waypoints.count >= 2 else { return Result(track: Track(points: waypoints), expectedSeconds: nil) }
        var points: [CLLocationCoordinate2D] = []
        var seconds: Double? = 0
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            let leg: [CLLocationCoordinate2D]
            if transport != .straight, let found = await directions(from: a, to: b, options: options) {
                leg = found.points
                if let s = seconds { seconds = s + found.seconds }
            } else {
                leg = [a, b]
                seconds = nil
            }
            if points.isEmpty { points.append(contentsOf: leg) } else { points.append(contentsOf: leg.dropFirst()) }
        }
        return Result(track: Track(points: points), expectedSeconds: seconds)
    }

    private static func directions(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, options: Options) async -> (points: [CLLocationCoordinate2D], seconds: Double)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        request.transportType = options.transport == .walking ? .walking : .automobile
        request.requestsAlternateRoutes = false
        if options.transport == .driving {
            request.tollPreference = options.avoidTolls ? .avoid : .any
            request.highwayPreference = options.avoidHighways ? .avoid : .any
        }
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { return nil }
            let polyline = route.polyline
            var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
            return (coords, route.expectedTravelTime)
        } catch {
            return nil
        }
    }

    /// Reads trkpt, rtept and wpt elements in document order. Timestamps are ignored on
    /// purpose: Tern plays every track at the speed the user picks.
    static func gpxPoints(from data: Data) -> [CLLocationCoordinate2D] {
        let parser = XMLParser(data: data)
        let delegate = GPXDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    private final class GPXDelegate: NSObject, XMLParserDelegate {
        var points: [CLLocationCoordinate2D] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard ["trkpt", "rtept", "wpt"].contains(element),
                  let lat = attributes["lat"].flatMap(Double.init),
                  let lon = attributes["lon"].flatMap(Double.init) else { return }
            points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }
}
