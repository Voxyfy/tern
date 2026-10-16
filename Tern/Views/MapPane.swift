import MapKit
import SwiftUI

struct MapPane: View {
    @Environment(Simulator.self) private var simulator
    @Environment(DeviceStore.self) private var devices
    @AppStorage("mapStyle") private var mapStyleRaw = "standard"
    @State private var camera: MapCameraPosition = .automatic
    @State private var followsPosition = true
    /// Heading-up, slightly tilted camera while a trip plays, like a car's navigation screen.
    @AppStorage("navigationCamera") private var navigationCamera = true
    /// Set while Tern itself animates the camera, so that move is not mistaken for a user pan.
    @State private var programmaticMoves = 0

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: .all) {
                if let track = simulator.track, track.points.count >= 2 {
                    MapPolyline(coordinates: track.points)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(simulator.waypoints.enumerated()), id: \.offset) { index, point in
                    Annotation("", coordinate: point, anchor: .center) {
                        WaypointBadge(index: index, total: simulator.waypoints.count)
                    }
                }
                if let target = simulator.target, simulator.mode == .teleport {
                    Annotation("", coordinate: target, anchor: .bottom) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.red, Color.white)
                            .shadow(radius: 3)
                    }
                }
                if let position = simulator.position {
                    Annotation("", coordinate: position, anchor: .center) {
                        LocationDot(live: devices.isReady, heading: simulator.heading,
                                    moving: simulator.playback == .running)
                    }
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
                MapZoomStepper()
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    simulator.handleTap(coordinate)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { _ in
                // A manual pan stops the camera from chasing the dot until the user asks again;
                // our own animations also end here, so they are counted and skipped.
                if programmaticMoves > 0 { programmaticMoves -= 1; return }
                if simulator.playback == .running { followsPosition = false }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 8) {
                MapStyleButton(styleRaw: $mapStyleRaw)
                Button {
                    navigationCamera.toggle()
                    if followsPosition { follow(simulator.position, animated: true) }
                } label: {
                    Image(systemName: navigationCamera ? "arrow.triangle.turn.up.right.diamond.fill" : "arrow.triangle.turn.up.right.diamond")
                        .frame(width: 20, height: 20)
                }
                .help(String(localized: "Turn the map with the direction of travel"))
                Button {
                    followsPosition = true
                    follow(simulator.position, animated: true)
                } label: {
                    Image(systemName: followsPosition ? "location.fill" : "location")
                        .frame(width: 20, height: 20)
                }
                .help(String(localized: "Follow the phone"))
            }
            .buttonStyle(.bordered)
            .padding(16)
            .padding(.bottom, 64)
        }
        .onChange(of: simulator.position) { _, new in
            guard followsPosition else { return }
            follow(new, animated: true)
        }
        .onChange(of: simulator.playback) { _, playback in
            // A new trip always starts with the camera on the dot.
            if playback == .running { followsPosition = true; follow(simulator.position, animated: true) }
        }
        .onChange(of: simulator.track) { _, track in
            guard let track, track.points.count >= 2, simulator.playback == .idle else { return }
            programmaticMoves += 1
            camera = .region(region(fitting: track.points))
        }
        .onChange(of: simulator.target) { _, target in
            guard let target else { return }
            programmaticMoves += 1
            withAnimation { camera = .camera(MapCamera(centerCoordinate: target, distance: currentDistance ?? 1500)) }
        }
        .onAppear {
            if let p = simulator.position {
                camera = .camera(MapCamera(centerCoordinate: p, distance: 1500))
            } else {
                // Istanbul as an opening view; the first search or tap replaces it.
                camera = .region(MKCoordinateRegion(center: .init(latitude: 41.015, longitude: 28.979),
                                                    latitudinalMeters: 20_000, longitudinalMeters: 20_000))
            }
        }
    }

    private var mapStyle: MapStyle {
        switch mapStyleRaw {
        case "hybrid": .hybrid(elevation: .realistic)
        case "imagery": .imagery(elevation: .realistic)
        default: .standard(elevation: .realistic, pointsOfInterest: .all)
        }
    }

    private var currentDistance: Double? {
        camera.camera?.distance
    }

    /// Moves the camera onto the dot. While a route or GPX plays with the navigation camera on,
    /// the map turns heading-up and tilts; otherwise it stays north-up and flat.
    private func follow(_ position: CLLocationCoordinate2D?, animated: Bool) {
        guard let position else { return }
        let moving = simulator.playback == .running && (simulator.mode == .route || simulator.mode == .gpx)
        let navigating = moving && navigationCamera
        let distance = navigating ? min(currentDistance ?? 1200, 2500) : (currentDistance ?? 1500)
        let target = MapCamera(centerCoordinate: position, distance: distance,
                               heading: navigating ? simulator.heading : 0, pitch: navigating ? 55 : 0)
        programmaticMoves += 1
        if animated {
            // One second, linear: matches the once-a-second position updates so the motion reads continuous.
            withAnimation(moving ? .linear(duration: 1.0) : .easeInOut(duration: 0.6)) { camera = .camera(target) }
        } else {
            camera = .camera(target)
        }
    }

    private func region(fitting points: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.4),
                                    longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }
}

struct MapStyleButton: View {
    @Binding var styleRaw: String

    var body: some View {
        Menu {
            Picker(String(localized: "Map style"), selection: $styleRaw) {
                Text(String(localized: "Standard")).tag("standard")
                Text(String(localized: "Hybrid")).tag("hybrid")
                Text(String(localized: "Satellite")).tag("imagery")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "map")
                .frame(width: 20, height: 20)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Map style"))
    }
}

/// The blue dot. Pulses while the phone is connected, shows a heading cone while moving.
struct LocationDot: View {
    var live: Bool
    var heading: Double
    var moving: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: pulse ? 56 : 28, height: pulse ? 56 : 28)
                .opacity(pulse ? 0 : 0.8)
                .animation(live ? .easeOut(duration: 1.6).repeatForever(autoreverses: false) : .default, value: pulse)
            if moving {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.degrees(heading))
                    .offset(y: -1)
                    .shadow(radius: 2)
            }
            Circle()
                .fill(live ? Color.accentColor : Color.gray)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(radius: 3)
        }
        .onAppear { pulse = live }
        .onChange(of: live) { _, new in pulse = new }
    }
}

struct WaypointBadge: View {
    var index: Int
    var total: Int

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 3)
    }

    private var label: String {
        if index == 0 { return "A" }
        if index == total - 1 { return "B" }
        return "\(index)"
    }

    private var color: Color {
        if index == 0 { return .green }
        if index == total - 1 { return .red }
        return .orange
    }
}
