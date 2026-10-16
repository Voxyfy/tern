import CoreLocation
import Foundation
import Observation

/// What the user is doing with the map right now. Drives both the sidebar and tap handling.
enum Mode: String, CaseIterable, Identifiable {
    case teleport, route, joystick, gpx
    var id: String { rawValue }

    var label: String {
        switch self {
        case .teleport: String(localized: "Teleport")
        case .route: String(localized: "Route")
        case .joystick: String(localized: "Joystick")
        case .gpx: String(localized: "GPX")
        }
    }

    var symbol: String {
        switch self {
        case .teleport: "scope"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .joystick: "dpad"
        case .gpx: "doc.text"
        }
    }
}

enum Playback { case idle, running, paused }

enum SpeedPreset: CaseIterable, Identifiable {
    case walk, bike, car
    var id: Self { self }

    /// Metres per second. The slider spans walk…car and beyond.
    var speed: Double {
        switch self {
        case .walk: 1.4
        case .bike: 5.5
        case .car: 25
        }
    }

    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .bike: "bicycle"
        case .car: "car.fill"
        }
    }

    var label: String {
        switch self {
        case .walk: String(localized: "Walk")
        case .bike: String(localized: "Bike")
        case .car: String(localized: "Car")
        }
    }
}

/// Holds the intent (where the user wants the phone to be) and moves it along over time.
/// All device traffic goes through `DeviceStore`; this class never touches the helper directly.
@MainActor
@Observable
final class Simulator {
    private let devices: DeviceStore

    var mode: Mode = .teleport {
        didSet { if mode != oldValue { stop() } }
    }

    /// Last coordinate Tern asked the phone to use. Also the start of the next route.
    private(set) var position: CLLocationCoordinate2D?
    /// Pending teleport target chosen on the map or in search, not yet sent.
    var target: CLLocationCoordinate2D?
    var waypoints: [CLLocationCoordinate2D] = []
    private(set) var track: Track?
    private(set) var isBuildingRoute = false
    var routeOptions = RouteBuilder.Options()
    var speed: Double = SpeedPreset.walk.speed       // m/s
    /// Use Apple's travel-time estimate (traffic included for driving) instead of the slider.
    var followsTravelTime = false
    private(set) var expectedSeconds: Double?
    var realistic = false
    var roundTrip = false
    var loops = 1
    var gpxName: String?

    private(set) var playback: Playback = .idle
    private(set) var progress: Double = 0              // metres along the current track
    private(set) var heading: Double = 0               // degrees, for the map arrow
    private var loopsDone = 0
    private var reverse = false
    private var timer: Task<Void, Never>?
    private var lastTick: Date?

    /// Joystick vector: x east, y north, each in -1…1. Zero means standing still.
    var joystick: (x: Double, y: Double) = (0, 0)

    init(devices: DeviceStore) {
        self.devices = devices
        if let saved = UserDefaults.standard.dictionary(forKey: "lastPosition"),
           let lat = saved["lat"] as? Double, let lon = saved["lon"] as? Double {
            position = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    // MARK: - Derived

    var canStart: Bool {
        guard devices.isReady else { return false }
        switch mode {
        case .teleport: return target != nil
        case .route: return waypoints.count >= 2 && !isBuildingRoute
        case .joystick: return position != nil
        case .gpx: return (track?.points.count ?? 0) >= 2
        }
    }

    var remainingMeters: Double {
        guard let track else { return 0 }
        let perPass = track.length
        let passes = roundTrip ? 2 : 1
        let total = perPass * Double(passes) * Double(max(loops, 1))
        let done = Double(loopsDone) * perPass * Double(passes) + (reverse ? perPass : 0) + progress
        return max(0, total - done)
    }

    var remainingSeconds: Double { effectiveSpeed > 0 ? remainingMeters / effectiveSpeed : .infinity }

    /// Metres per second actually used for playback.
    var effectiveSpeed: Double {
        if followsTravelTime, let eta = expectedSeconds, eta > 0, let track, track.length > 0 {
            return track.length / eta
        }
        return speed
    }

    /// The pace Apple's estimate implies, or nil when the route has no estimate.
    var travelTimeSpeed: Double? {
        guard let eta = expectedSeconds, eta > 0, let track, track.length > 0 else { return nil }
        return track.length / eta
    }

    // MARK: - Map interaction

    func handleTap(_ coordinate: CLLocationCoordinate2D) {
        switch mode {
        case .teleport:
            target = coordinate
        case .route:
            guard playback == .idle else { return }
            waypoints.append(coordinate)
            rebuildRoute()
        case .joystick:
            if playback == .idle { teleport(to: coordinate) }
        case .gpx:
            break
        }
    }

    func removeWaypoint(at index: Int) {
        guard waypoints.indices.contains(index), playback == .idle else { return }
        waypoints.remove(at: index)
        rebuildRoute()
    }

    func clearWaypoints() {
        stop()
        waypoints.removeAll()
        track = nil
        expectedSeconds = nil
        target = nil
        gpxName = nil
    }

    func loadGPX(_ data: Data, name: String) {
        stop()
        let points = RouteBuilder.gpxPoints(from: data)
        track = points.count >= 2 ? Track(points: points) : nil
        expectedSeconds = nil
        gpxName = track == nil ? nil : name
        mode = .gpx
    }

    func rebuildRoute() {
        guard mode == .route else { return }
        if waypoints.count < 2 { track = nil; expectedSeconds = nil; return }
        isBuildingRoute = true
        let points = waypoints
        let options = routeOptions
        Task {
            let built = await RouteBuilder.track(through: points, options: options)
            // The user may have tapped again while directions were loading.
            guard points == self.waypoints else { return }
            self.track = built.track
            self.expectedSeconds = built.expectedSeconds
            self.isBuildingRoute = false
        }
    }

    // MARK: - Device commands

    func teleport(to coordinate: CLLocationCoordinate2D) {
        stop()
        apply(coordinate)
        target = nil
    }

    func resetDevice() {
        stop()
        devices.resetLocation()
    }

    // MARK: - Playback

    func start() {
        guard canStart else { return }
        switch mode {
        case .teleport:
            if let target { teleport(to: target) }
        case .route, .gpx:
            guard let track else { return }
            // Start from the first point of the track, not from wherever the dot was.
            apply(track.points[0])
            progress = 0
            loopsDone = 0
            reverse = false
            playback = .running
            startTimer()
        case .joystick:
            playback = .running
            startTimer()
        }
    }

    func togglePause() {
        switch playback {
        case .running: playback = .paused
        case .paused: playback = .running; lastTick = nil
        case .idle: break
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        playback = .idle
        progress = 0
        loopsDone = 0
        reverse = false
        joystick = (0, 0)
    }

    private func startTimer() {
        timer?.cancel()
        lastTick = nil
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard playback == .running else { lastTick = nil; return }
        let now = Date()
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 1
        lastTick = now
        // Realistic mode wobbles the pace so the trace does not look machine-made.
        let factor = realistic ? Double.random(in: 0.82...1.14) : 1
        let step = effectiveSpeed * factor * dt

        switch mode {
        case .joystick:
            let (x, y) = joystick
            let magnitude = min(1, sqrt(x * x + y * y))
            guard magnitude > 0.05, let from = position else { return }
            let bearing = (atan2(x, y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            heading = bearing
            apply(Geo.destination(from: from, bearingDegrees: bearing, meters: step * magnitude))
        case .route, .gpx:
            guard let base = track else { stop(); return }
            let current = reverse ? base.reversed() : base
            progress += step
            if progress >= current.length {
                apply(current.points[current.points.count - 1])
                advanceLeg()
                return
            }
            if let p = current.point(at: progress) {
                if let prev = position { heading = Geo.bearing(prev, p) }
                apply(p)
            }
        case .teleport:
            stop()
        }
    }

    /// Reached the end of a pass: turn around, loop again, or finish.
    private func advanceLeg() {
        progress = 0
        if roundTrip && !reverse {
            reverse = true
            return
        }
        reverse = false
        loopsDone += 1
        if loopsDone >= max(loops, 1) {
            playback = .idle
            timer?.cancel()
            timer = nil
        }
    }

    private func apply(_ coordinate: CLLocationCoordinate2D) {
        position = coordinate
        devices.setLocation(lat: coordinate.latitude, lon: coordinate.longitude)
        UserDefaults.standard.set(["lat": coordinate.latitude, "lon": coordinate.longitude], forKey: "lastPosition")
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
