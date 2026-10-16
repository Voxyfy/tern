import CoreLocation
import Testing
@testable import Tern

struct GeoTests {
    let sakarya = CLLocationCoordinate2D(latitude: 40.7753, longitude: 30.4020)
    let ankara = CLLocationCoordinate2D(latitude: 39.9209, longitude: 32.8540)

    @Test func distanceSakaryaAnkara() {
        let d = Geo.distance(sakarya, ankara)
        // Great-circle distance is about 229 km.
        #expect(d > 225_000 && d < 233_000)
    }

    @Test func destinationRoundTrip() {
        let b = Geo.bearing(sakarya, ankara)
        let d = Geo.distance(sakarya, ankara)
        let there = Geo.destination(from: sakarya, bearingDegrees: b, meters: d)
        #expect(Geo.distance(there, ankara) < 50)
    }

    @Test func parseCoordinates() {
        #expect(Geo.parseCoordinate("41.0082, 28.9784") != nil)
        #expect(Geo.parseCoordinate("41.0082 28.9784") != nil)
        #expect(Geo.parseCoordinate("Kızılay") == nil)
        #expect(Geo.parseCoordinate("91, 0") == nil)
    }

    @Test func trackInterpolation() {
        let track = Track(points: [sakarya, ankara])
        #expect(track.length > 225_000)
        // Segments are interpolated linearly in lat/lon; on a 229 km leg that drifts from the
        // great circle by a few hundred metres, which real road tracks (short legs) never see.
        let mid = track.point(at: track.length / 2)!
        #expect(abs(Geo.distance(sakarya, mid) - track.length / 2) < track.length * 0.005)
        let short = Track(points: [sakarya, Geo.destination(from: sakarya, bearingDegrees: 90, meters: 200)])
        let quarter = short.point(at: 50)!
        #expect(abs(Geo.distance(sakarya, quarter) - 50) < 0.5)
        #expect(track.point(at: -5) == sakarya)
        #expect(track.point(at: track.length + 5) == ankara)
    }

    @Test func trackDropsDuplicates() {
        let track = Track(points: [sakarya, sakarya, ankara])
        #expect(track.points.count == 2)
    }

    @Test func gpxParsing() {
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1"><trk><trkseg>
        <trkpt lat="40.7753" lon="30.4020"><ele>30</ele></trkpt>
        <trkpt lat="40.7760" lon="30.4100"></trkpt>
        </trkseg></trk></gpx>
        """
        let points = RouteBuilder.gpxPoints(from: Data(gpx.utf8))
        #expect(points.count == 2)
        #expect(points[1].longitude == 30.41)
    }
}
