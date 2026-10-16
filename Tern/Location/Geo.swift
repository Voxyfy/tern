import CoreLocation
import Foundation

/// Plain spherical geometry. Accurate to well under a metre over the distances a phone walks.
enum Geo {
    static let earthRadius = 6_371_000.0

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b` in degrees, 0 = north, clockwise.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached after `meters` from `start` on `bearingDegrees`.
    static func destination(from start: CLLocationCoordinate2D, bearingDegrees: Double, meters: Double) -> CLLocationCoordinate2D {
        let δ = meters / earthRadius
        let θ = bearingDegrees * .pi / 180
        let φ1 = start.latitude * .pi / 180, λ1 = start.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2 * 180 / .pi, longitude: λ2 * 180 / .pi)
    }

    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Accepts "41.0082, 28.9784" or "41.0082 28.9784"; anything else is not a coordinate.
    static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func format(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    static func formatDistance(_ meters: Double) -> String {
        let m = Measurement(value: meters, unit: UnitLength.meters)
        let style = Measurement<UnitLength>.FormatStyle(width: .abbreviated, usage: .road,
                                                        numberFormatStyle: .number.precision(.fractionLength(0...1)))
        return m.formatted(style)
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// A polyline with cumulative distances so playback can ask "where am I after N metres".
struct Track: Equatable {
    let points: [CLLocationCoordinate2D]
    let cumulative: [Double]
    var length: Double { cumulative.last ?? 0 }

    init(points: [CLLocationCoordinate2D]) {
        var cleaned: [CLLocationCoordinate2D] = []
        for p in points where cleaned.last.map({ Geo.distance($0, p) > 0.01 }) ?? true {
            cleaned.append(p)
        }
        self.points = cleaned
        var acc = [0.0]
        for i in 1..<max(cleaned.count, 1) {
            acc.append(acc[i - 1] + Geo.distance(cleaned[i - 1], cleaned[i]))
        }
        cumulative = cleaned.isEmpty ? [] : acc
    }

    func point(at meters: Double) -> CLLocationCoordinate2D? {
        guard !points.isEmpty else { return nil }
        if meters <= 0 { return points[0] }
        if meters >= length { return points[points.count - 1] }
        // Binary search for the segment containing `meters`.
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= meters { lo = mid } else { hi = mid }
        }
        let segment = cumulative[hi] - cumulative[lo]
        let t = segment > 0 ? (meters - cumulative[lo]) / segment : 0
        return Geo.interpolate(points[lo], points[hi], t: t)
    }

    func reversed() -> Track { Track(points: points.reversed()) }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.points.count == rhs.points.count && lhs.length == rhs.length
    }
}
