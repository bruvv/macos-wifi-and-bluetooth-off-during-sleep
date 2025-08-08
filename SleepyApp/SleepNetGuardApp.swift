import SwiftUI
import ServiceManagement
import AppKit

@main
struct SleepNetGuardApp: App {
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("showAdvanced") private var showAdvanced = false
    @StateObject private var sleepManager = SleepManager()

    init() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.register(defaults: [
            "disableWiFiOnSleep": true,
            "disableBTOnSleep": true,
            "restoreOnWake": true
        ])
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra("SleepNetGuard", systemImage: "moon.zzz.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ContentView()
                    .environmentObject(sleepManager)

                HStack {
                    Spacer()
                    if showAdvanced {
                        Button("Verberg geavanceerde opties") { showAdvanced = false }
                    } else {
                        Button("Toon geavanceerde opties") { showAdvanced = true }
                    }
                    Spacer()
                }

                if showAdvanced {
                    Divider()
                    Button("Diagnose: test Wi‑Fi/BT nu") { sleepManager.diagnoseNow() }
                    Divider()
                    Toggle("Start bij inloggen", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            launchAtLogin = newValue
                            if newValue { try? SMAppService.mainApp.register() }
                            else { try? SMAppService.mainApp.unregister() }
                        }
                    ))
                    Divider()
                    HStack(spacing: 12) {
                        Button("Test: voer slaap‑acties nu uit") { sleepManager.performWillSleepActions(simulated: true) }
                        Button("Test: herstel acties nu") { sleepManager.performDidWakeActions(simulated: true) }
                    }
                }

                Divider()
                HStack {
                    Spacer()
                    Button("Stop") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                    Spacer()
                }
            }
            .padding(12)
            .frame(minWidth: 340)
        }
        .menuBarExtraStyle(.window)
    }
}
