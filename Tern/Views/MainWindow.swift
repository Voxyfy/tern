import SwiftUI

/// CarPlay-style layout: the map fills the window, everything else floats on glass.
struct MainWindow: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(Simulator.self) private var simulator
    @State private var showLog = false
    @State private var showPlaces = false

    var body: some View {
        // The map is a background so its ignoresSafeArea does not drag the overlays under the
        // title bar (a ZStack would grow with its safe-area-ignoring child).
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ModeRail()
                SidePanel()
                    .frame(width: SidePanel.width)
                Spacer()
            }
            .padding(16)
            Spacer(minLength: 0)
            if simulator.playback != .idle {
                PlaybackBar()
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: simulator.playback)
        .background { MapPane().ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    Button { showPlaces.toggle() } label: { Label(String(localized: "Places"), systemImage: "star") }
                        .popover(isPresented: $showPlaces, arrowEdge: .bottom) { PlacesPopover() }
                    Button { showLog.toggle() } label: { Label(String(localized: "Log"), systemImage: "text.alignleft") }
                        .popover(isPresented: $showLog, arrowEdge: .bottom) { LogPopover() }
                }
            }
        }
        .onDisappear { devices.shutdown() }
    }
}

/// The CarPlay-like rail: one big icon per mode.
struct ModeRail: View {
    @Environment(Simulator.self) private var simulator

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Mode.allCases) { mode in
                Button {
                    simulator.mode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 20, weight: .semibold))
                        Text(mode.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(width: 64, height: 60)
                    .foregroundStyle(simulator.mode == mode ? Color.white : Color.primary.opacity(0.75))
                    .background(simulator.mode == mode ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .help(mode.label)
            }
        }
        .padding(6)
        .glassPanel()
    }
}

/// Floating "now moving" bar at the bottom.
struct PlaybackBar: View {
    @Environment(Simulator.self) private var simulator

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: simulator.mode == .joystick ? "dpad.fill" : "location.north.line.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(simulator.mode == .joystick ? 0 : simulator.heading))
                .animation(.easeInOut(duration: 0.5), value: simulator.heading)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(Geo.format(simulator.position ?? .init()))
                        .monospacedDigit()
                    if simulator.mode != .joystick {
                        Text("·")
                        Text(Geo.formatDistance(simulator.remainingMeters))
                        Text("·")
                        Text(Geo.formatDuration(simulator.remainingSeconds))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if simulator.mode != .joystick, let track = simulator.track, track.length > 0 {
                ProgressView(value: min(1, simulator.progress / track.length))
                    .frame(width: 120)
            }

            Button { simulator.togglePause() } label: {
                Image(systemName: simulator.playback == .paused ? "play.fill" : "pause.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            Button { simulator.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassPanel()
    }

    private var statusTitle: String {
        switch (simulator.playback, simulator.mode) {
        case (.paused, _): String(localized: "Paused")
        case (_, .joystick): String(localized: "Joystick")
        case (_, .gpx): simulator.gpxName ?? String(localized: "GPX track")
        default: String(localized: "On the way")
        }
    }
}

struct LogPopover: View {
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Helper log")).font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(devices.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo(devices.log.count - 1) }
                .onChange(of: devices.log.count) { proxy.scrollTo(devices.log.count - 1) }
            }
        }
        .padding()
        .frame(width: 520, height: 320)
    }
}

extension View {
    /// Rounded dark-glass card, the CarPlay look everything floats in.
    func glassPanel() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}
