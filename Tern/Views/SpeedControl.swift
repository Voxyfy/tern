import SwiftUI

/// Walk / bike / car presets plus a slider. Stored in m/s, shown in km/h.
struct SpeedControl: View {
    @Binding var speed: Double
    @Binding var realistic: Bool
    /// True while the route follows Apple's travel time; the slider then only shows the value.
    var locked = false

    private let range: ClosedRange<Double> = 0.5...60   // 1.8 … 216 km/h

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(String(localized: "Speed"))
                Spacer()
                if locked {
                    Label(String(localized: "Traffic"), systemImage: "car.rear.road.lane")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "\(Int((speed * 3.6).rounded())) km/h"))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
            HStack(spacing: 6) {
                ForEach(SpeedPreset.allCases) { preset in
                    Button {
                        withAnimation(.snappy) { speed = preset.speed }
                    } label: {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(speed - preset.speed) < 0.01 ? Color.accentColor : nil)
                    .help(preset.label)
                    .disabled(locked)
                }
            }
            Slider(value: $speed, in: range)
                .disabled(locked)
            Toggle(isOn: $realistic) {
                Text(String(localized: "Realistic pace"))
                Text(String(localized: "Varies the speed a little so the trace looks human."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
        }
    }
}

/// Drag the knob to move; distance from the centre is throttle. Arrow keys nudge it as well.
struct JoystickView: View {
    @Environment(Simulator.self) private var simulator
    @State private var offset: CGSize = .zero
    private let radius: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.5))
                .frame(width: radius * 2 + 24, height: radius * 2 + 24)
            ForEach(["arrowtriangle.up.fill", "arrowtriangle.right.fill", "arrowtriangle.down.fill", "arrowtriangle.left.fill"], id: \.self) { s in
                Image(systemName: s)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .offset(arrowOffset(s))
            }
            Circle()
                .fill(simulator.playback == .running ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                .shadow(radius: 4, y: 2)
                .offset(offset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let dx = value.translation.width, dy = value.translation.height
                            let len = sqrt(dx * dx + dy * dy)
                            let clamped = len > radius ? radius / len : 1
                            offset = CGSize(width: dx * clamped, height: dy * clamped)
                            simulator.joystick = (Double(offset.width / radius), Double(-offset.height / radius))
                        }
                        .onEnded { _ in
                            withAnimation(.snappy) { offset = .zero }
                            simulator.joystick = (0, 0)
                        }
                )
        }
        .focusable()
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .upArrow: simulator.joystick = (0, 1)
            case .downArrow: simulator.joystick = (0, -1)
            case .leftArrow: simulator.joystick = (-1, 0)
            case .rightArrow: simulator.joystick = (1, 0)
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(phases: .up) { press in
            if [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(press.key) {
                simulator.joystick = (0, 0)
                return .handled
            }
            return .ignored
        }
    }

    private func arrowOffset(_ symbol: String) -> CGSize {
        let r = radius + 4
        switch symbol {
        case "arrowtriangle.up.fill": return CGSize(width: 0, height: -r)
        case "arrowtriangle.down.fill": return CGSize(width: 0, height: r)
        case "arrowtriangle.left.fill": return CGSize(width: -r, height: 0)
        default: return CGSize(width: r, height: 0)
        }
    }
}
