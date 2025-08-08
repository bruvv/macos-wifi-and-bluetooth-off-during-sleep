import SwiftUI

struct ContentView: View {
    @AppStorage("disableWiFiOnSleep") private var disableWiFiOnSleep = true
    @AppStorage("disableBTOnSleep") private var disableBTOnSleep = true
    @AppStorage("restoreOnWake") private var restoreOnWake = true
    @EnvironmentObject private var sleepManager: SleepManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Wi‑Fi uitschakelen tijdens slaap", isOn: $disableWiFiOnSleep)
            Toggle("Bluetooth uitschakelen tijdens slaap", isOn: $disableBTOnSleep)
            Toggle("Oude status herstellen bij wakker worden", isOn: $restoreOnWake)

            Divider()

            HStack {
                if let iface = sleepManager.cachedWiFiInterface {
                    Label("Wi‑Fi interface: \(iface)", systemImage: "wifi")
                } else {
                    Label("Wi‑Fi interface zoeken…", systemImage: "wifi.exclamationmark")
                }
            }
            .font(.footnote)
        }
        .padding(12)
        .frame(width: 320)
    }
}
