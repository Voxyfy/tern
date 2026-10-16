import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// The floating left card: device, search, the current mode's controls, speed, go.
struct SidePanel: View {
    @Environment(Simulator.self) private var simulator
    @Environment(DeviceStore.self) private var devices
    @Environment(PlaceStore.self) private var places

    var body: some View {
        // No outer scroll view: it re-measures a frame late and makes the panel hop when the
        // mode changes. The one list that can grow (route stops) scrolls on its own instead.
        // Fixed inner width: otherwise the glass grows and shrinks with whichever mode's
        // widest row is showing, and the panel appears to hop when the mode changes.
        content
            .frame(width: SidePanel.width - 32, alignment: .leading)
            .padding(16)
            .glassPanel()
            .frame(maxHeight: .infinity, alignment: .top)
    }

    static let width: CGFloat = 340

    private var content: some View {
        @Bindable var simulator = simulator
        return VStack(alignment: .leading, spacing: 14) {
            DeviceCard()

            if simulator.mode != .joystick && simulator.mode != .gpx {
                SearchField { coordinate, name in
                    simulator.handleTap(coordinate)
                    places.noteVisit(coordinate, name: name)
                }
            }

            switch simulator.mode {
            case .teleport: TeleportSection()
            case .route: RouteSection()
            case .joystick: JoystickSection()
            case .gpx: GPXSection()
            }

            if simulator.mode != .teleport {
                SpeedControl(speed: $simulator.speed, realistic: $simulator.realistic,
                             locked: simulator.mode == .route && simulator.followsTravelTime && simulator.travelTimeSpeed != nil)
            }

            GoButton()
        }
    }
}

struct DeviceCard: View {
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        @Bindable var devices = devices
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 26))
                .foregroundStyle(devices.isReady ? Color.accentColor : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                if devices.devices.count > 1 {
                    Picker("", selection: $devices.selectedUDID) {
                        ForEach(devices.devices) { d in
                            Text(d.displayName).tag(Optional(d.udid))
                        }
                    }
                    .labelsHidden()
                    .disabled(devices.isReady || devices.isBusy)
                } else {
                    Text(devices.selectedDevice?.displayName ?? String(localized: "No iPhone"))
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            switch devices.state {
            case .idle, .failed:
                Button(String(localized: "Connect")) { devices.connect() }
                    .buttonStyle(.borderedProminent)
            case .connecting:
                ProgressView().controlSize(.small)
            case .ready:
                Button(String(localized: "Disconnect")) { devices.disconnect() }
                    .buttonStyle(.bordered)
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var subtitle: String {
        switch devices.state {
        case .helperMissing(let m): m
        case .noDevice: String(localized: "Plug in an iPhone with Developer Mode on")
        case .idle: devices.selectedDevice.map { "iOS \($0.version) · \($0.connection)" } ?? ""
        case .connecting(let s): s.isEmpty ? String(localized: "Connecting") : s
        case .ready: String(localized: "Connected · location simulation active")
        case .failed(let m): m
        }
    }

    private var subtitleColor: Color {
        switch devices.state {
        case .failed, .helperMissing: .red
        case .ready: .green
        default: .secondary
        }
    }
}

struct TeleportSection: View {
    @Environment(Simulator.self) private var simulator
    @Environment(PlaceStore.self) private var places

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(String(localized: "Teleport"))
            if let target = simulator.target {
                CoordinateRow(title: String(localized: "Target"), coordinate: target) {
                    FavoriteButton(coordinate: target)
                }
                if let from = simulator.position {
                    Text(String(localized: "\(Geo.formatDistance(Geo.distance(from, target))) from current spot"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Hint(String(localized: "Click the map or search a place, then press Go."))
            }
            if let position = simulator.position {
                CoordinateRow(title: String(localized: "Phone"), coordinate: position) {
                    FavoriteButton(coordinate: position)
                }
            }
        }
    }
}

struct RouteSection: View {
    @Environment(Simulator.self) private var simulator

    var body: some View {
        @Bindable var simulator = simulator
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(String(localized: "Route"))
                Spacer()
                if !simulator.waypoints.isEmpty {
                    Button(String(localized: "Clear")) { simulator.clearWaypoints() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                }
            }
            if simulator.waypoints.isEmpty {
                Hint(String(localized: "Click the map to add stops. Two make a trip, more make a tour."))
            } else {
                ScrollView(.vertical, showsIndicators: simulator.waypoints.count > 5) {
                    VStack(spacing: 6) {
                        ForEach(Array(simulator.waypoints.enumerated()), id: \.offset) { i, p in
                            HStack(spacing: 8) {
                                WaypointBadge(index: i, total: simulator.waypoints.count)
                                    .scaleEffect(0.8)
                                Text(Geo.format(p)).font(.caption).monospacedDigit()
                                Spacer()
                                Button { simulator.removeWaypoint(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                                    .disabled(simulator.playback != .idle)
                            }
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(simulator.waypoints.count, 5)) * 30)
            }
            // Plain short text: a Label with an icon is measured twice by the segmented control
            // and visibly overflows before it settles.
            Picker("", selection: $simulator.routeOptions.transport) {
                ForEach(RouteBuilder.Transport.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
            if simulator.routeOptions.transport == .driving {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "Avoid tolls"), isOn: $simulator.routeOptions.avoidTolls)
                    Toggle(String(localized: "Avoid highways"), isOn: $simulator.routeOptions.avoidHighways)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
            Color.clear.frame(height: 0)
                .onChange(of: simulator.routeOptions) { simulator.rebuildRoute() }

            HStack {
                Toggle(String(localized: "Return to start"), isOn: $simulator.roundTrip)
                Spacer()
                Stepper(value: $simulator.loops, in: 1...99) {
                    Text(String(localized: "\(simulator.loops)×"))
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .disabled(simulator.playback != .idle)

            // Reserved height so the panel does not change size while directions load.
            VStack(alignment: .leading, spacing: 6) { routeInfo }
                .frame(minHeight: simulator.waypoints.isEmpty ? 0 : 58, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var routeInfo: some View {
        @Bindable var simulator = simulator
        Group {
            if simulator.isBuildingRoute {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(String(localized: "Finding the way…")) }
                    .font(.caption).foregroundStyle(.secondary)
            } else if let track = simulator.track {
                Text(String(localized: "\(Geo.formatDistance(track.length)) · \(Geo.formatDuration(track.length / max(simulator.effectiveSpeed, 0.1))) at this speed"))
                    .font(.caption).foregroundStyle(.secondary)
                if let etaSpeed = simulator.travelTimeSpeed, let eta = simulator.expectedSeconds {
                    Toggle(isOn: $simulator.followsTravelTime) {
                        Text(String(localized: "Match Apple's travel time"))
                        Text(String(localized: "\(Geo.formatDuration(eta)) with current traffic · about \(Int((etaSpeed * 3.6).rounded())) km/h"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .disabled(simulator.playback != .idle)
                }
            } else if simulator.waypoints.count == 1 {
                Text(String(localized: "Add one more stop to make a route."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct JoystickSection: View {
    @Environment(Simulator.self) private var simulator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(String(localized: "Joystick"))
            if simulator.position == nil {
                Hint(String(localized: "Click the map to put the phone somewhere first."))
            } else {
                Hint(String(localized: "Press Go, then drag the knob. Arrow keys work too."))
            }
            HStack {
                Spacer()
                JoystickView()
                Spacer()
            }
        }
    }
}

struct GPXSection: View {
    @Environment(Simulator.self) private var simulator
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(String(localized: "GPX"))
            if let name = simulator.gpxName, let track = simulator.track {
                HStack {
                    Image(systemName: "doc.text.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(name).font(.callout).lineLimit(1)
                        Text(String(localized: "\(track.points.count) points · \(Geo.formatDistance(track.length))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Clear")) { simulator.clearWaypoints() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                }
            } else {
                Hint(String(localized: "Open a GPX file and Tern walks it at the speed you pick."))
            }
            Button(String(localized: "Open GPX…")) { importing = true }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml, .data]) { result in
                    guard case .success(let url) = result else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        simulator.loadGPX(data, name: url.lastPathComponent)
                    }
                }
            @Bindable var simulator = simulator
            HStack {
                Toggle(String(localized: "Return to start"), isOn: $simulator.roundTrip)
                Spacer()
                Stepper(value: $simulator.loops, in: 1...99) {
                    Text(String(localized: "\(simulator.loops)×")).monospacedDigit()
                }
            }
            .font(.callout)
            .disabled(simulator.playback != .idle)
        }
    }
}

struct GoButton: View {
    @Environment(Simulator.self) private var simulator
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        Button {
            simulator.start()
        } label: {
            HStack {
                Image(systemName: simulator.mode == .teleport ? "location.fill" : "play.fill")
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!simulator.canStart || simulator.playback == .running)
        .help(devices.isReady ? "" : String(localized: "Connect the iPhone first"))
    }

    private var title: String {
        switch simulator.mode {
        case .teleport: String(localized: "Go")
        case .route, .gpx: String(localized: "Start trip")
        case .joystick: String(localized: "Start")
        }
    }
}

// MARK: - Small pieces

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct CoordinateRow<Accessory: View>: View {
    var title: String
    var coordinate: CLLocationCoordinate2D
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(Geo.format(coordinate)).font(.callout).monospacedDigit().textSelection(.enabled)
            }
            Spacer()
            accessory
        }
    }
}

struct FavoriteButton: View {
    @Environment(PlaceStore.self) private var places
    var coordinate: CLLocationCoordinate2D
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Button {
            if places.isFavorite(coordinate) {
                if let p = places.favorites.first(where: { Geo.distance($0.coordinate, coordinate) < 5 }) { places.removeFavorite(p) }
            } else {
                name = Geo.format(coordinate)
                naming = true
            }
        } label: {
            Image(systemName: places.isFavorite(coordinate) ? "star.fill" : "star")
                .foregroundStyle(places.isFavorite(coordinate) ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Save as favorite"))
        .popover(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Name this place")).font(.headline)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { save() }
                HStack {
                    Spacer()
                    Button(String(localized: "Save")) { save() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func save() {
        places.addFavorite(coordinate, name: name.isEmpty ? Geo.format(coordinate) : name)
        naming = false
    }
}

extension UTType {
    static let gpx = UTType(filenameExtension: "gpx") ?? .xml
}
