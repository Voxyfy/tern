import Sparkle
import SwiftUI

@main
struct TernApp: App {
    @State private var devices = DeviceStore()
    @State private var simulator: Simulator
    @State private var places = PlaceStore()

    /// Sparkle checks the appcast daily. It only starts when the build carries a public key,
    /// otherwise it would show an error alert on every launch of a development build.
    private let updater = SPUStandardUpdaterController(startingUpdater: TernApp.hasUpdateKey,
                                                        updaterDelegate: nil, userDriverDelegate: nil)

    static var hasUpdateKey: Bool {
        !((Bundle.main.infoDictionary?["SUPublicEDKey"] as? String) ?? "").isEmpty
    }

    init() {
        let devices = DeviceStore()
        _devices = State(initialValue: devices)
        _simulator = State(initialValue: Simulator(devices: devices))
    }

    var body: some Scene {
        Window("Tern", id: "main") {
            MainWindow()
                .environment(devices)
                .environment(simulator)
                .environment(places)
                .frame(minWidth: 960, minHeight: 700)
                .task { devices.start() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(String(localized: "Check for Updates…")) { updater.updater.checkForUpdates() }
                    .disabled(!Self.hasUpdateKey || !updater.updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu(String(localized: "Location")) {
                Button(String(localized: "Start")) { simulator.start() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!simulator.canStart)
                Button(simulator.playback == .paused ? String(localized: "Resume") : String(localized: "Pause")) {
                    simulator.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(simulator.playback == .idle)
                Button(String(localized: "Stop")) { simulator.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(simulator.playback == .idle)
                Divider()
                Button(String(localized: "Reset to Real Location")) { simulator.resetDevice() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!devices.isReady)
                Button(String(localized: "Clear Points")) { simulator.clearWaypoints() }
                    .keyboardShortcut(.delete, modifiers: [.command])
            }
        }
    }
}
