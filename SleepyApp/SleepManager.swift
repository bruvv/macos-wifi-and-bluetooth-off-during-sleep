
import Foundation
import AppKit
import IOKit.ps

final class SleepManager: ObservableObject {
    private let nc = NSWorkspace.shared.notificationCenter
    private let prefs = UserDefaults.standard

    @Published var cachedWiFiInterface: String?
    @Published var powerSourceLabel: String = "Onbekend"
    @Published var onACPower: Bool = false

    private var powerPoller: Timer?

    private var prevWiFiOn: Bool?
    private var prevBTOn: Bool?

    private let kDisableWiFi = "disableWiFiOnSleep"
    private let kDisableBT   = "disableBTOnSleep"
    private let kRestoreOnWake = "restoreOnWake"

    private let networksetup = "/usr/sbin/networksetup"

    private var blueutilPath: String? {
        if let res = run("/usr/bin/which", ["blueutil"]), res.status == 0 {
            let p = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let fallbacks = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil", "/usr/bin/blueutil"]
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Power source
    private func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let typeCF = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else {
            return false
        }
        return typeCF == kIOPSACPowerValue
    }

    /// Human-readable current power source for UI
    func currentPowerSourceLabel() -> String {
        isOnACPower() ? "Netstroom" : "Batterij"
    }

    init() {
        nc.addObserver(self, selector: #selector(onWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        cachedWiFiInterface = detectWiFiDevice()
        NSLog("[SleepNetGuard] detected Wi-Fi device: \(cachedWiFiInterface ?? "nil")")

        // Init power source state and start a lightweight poller so the UI stays live
        self.onACPower = isOnACPower()
        self.powerSourceLabel = currentPowerSourceLabel()
        powerPoller = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ac = self.isOnACPower()
            if ac != self.onACPower { self.onACPower = ac }
            let label = self.currentPowerSourceLabel()
            if label != self.powerSourceLabel { self.powerSourceLabel = label }
        }
    }

    deinit {
        powerPoller?.invalidate()
    }

    @objc private func onWillSleep(_ note: Notification) { performWillSleepActions() }
    @objc private func onDidWake(_ note: Notification)  { performDidWakeActions() }

    // MARK: Public actions
    func performWillSleepActions(simulated: Bool = false) {
        let disableWiFi = boolPref(kDisableWiFi, default: true)
        let disableBT   = boolPref(kDisableBT,   default: true)
        let onAC = isOnACPower()
        NSLog("[SleepNetGuard] will-sleep: disableWiFi=\(disableWiFi) disableBT=\(disableBT) onAC=\(onAC) dev=\(cachedWiFiInterface ?? detectWiFiDevice() ?? "en0")")

        if onAC {
            NSLog("[SleepNetGuard] on AC power; skipping Wi-Fi/BT disable")
            if simulated { print("[Simulated] overslaan: op netstroom") }
            return
        }

        if disableWiFi {
            prevWiFiOn = isWiFiPoweredOn()
            let okWifi = setWiFiPower(false)
            NSLog("[SleepNetGuard] will-sleep Wi-Fi off -> \(okWifi)")
        }
        if disableBT {
            prevBTOn = isBTPoweredOn()
            let okBt = setBTPower(false)
            NSLog("[SleepNetGuard] will-sleep BT off -> \(okBt)")
        }

        if simulated { print("[Simulated] will-sleep acties uitgevoerd") }
    }

    func performDidWakeActions(simulated: Bool = false) {
        guard boolPref(kRestoreOnWake, default: true) else { return }
        NSLog("[SleepNetGuard] prefs restoreOnWake=true")

        if let wasOn = prevWiFiOn {
            let okWifi = setWiFiPower(wasOn)
            NSLog("[SleepNetGuard] did-wake restore Wi-Fi \(wasOn) -> \(okWifi)")
            prevWiFiOn = nil
        }
        if let wasOn = prevBTOn {
            let okBt = setBTPower(wasOn)
            NSLog("[SleepNetGuard] did-wake restore BT \(wasOn) -> \(okBt)")
            prevBTOn = nil
        }

        if simulated { print("[Simulated] did-wake herstel uitgevoerd") }
    }

    // MARK: Diagnose helper
    func diagnoseNow() {
        let dev = (cachedWiFiInterface ?? detectWiFiDevice()) ?? "en0"
        let btPath = blueutilPath ?? "(not found)"

        let getBefore = run(networksetup, ["-getairportpower", dev])
        let btBefore  = blueutilPath != nil ? run(blueutilPath!, ["--power"]) : nil

        let wifiOff = run(networksetup, ["-setairportpower", dev, "off"])
        let btOff   = blueutilPath != nil ? run(blueutilPath!, ["--power", "0"]) : nil

        let getAfterOff = run(networksetup, ["-getairportpower", dev])
        let btAfterOff  = blueutilPath != nil ? run(blueutilPath!, ["--power"]) : nil

        let wifiOn = run(networksetup, ["-setairportpower", dev, "on"])
        let btOn   = blueutilPath != nil ? run(blueutilPath!, ["--power", "1"]) : nil

        let getAfterOn = run(networksetup, ["-getairportpower", dev])
        let btAfterOn  = blueutilPath != nil ? run(blueutilPath!, ["--power"]) : nil

        let report = """
        Device: \(dev)
        blueutil: \(btPath)

        Wi-Fi before: \(getBefore?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no out)") [status \(getBefore?.status ?? -1)]
        BT before: \(btBefore?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(n/a)") [status \(btBefore?.status ?? -1)]

        Wi-Fi set off -> status \(wifiOff?.status ?? -1)
        BT set 0      -> status \(btOff?.status ?? -1)

        Wi-Fi after off: \(getAfterOff?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no out)") [status \(getAfterOff?.status ?? -1)]
        BT after off: \(btAfterOff?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(n/a)") [status \(btAfterOff?.status ?? -1)]

        Wi-Fi set on -> status \(wifiOn?.status ?? -1)
        BT set 1     -> status \(btOn?.status ?? -1)

        Wi-Fi after on: \(getAfterOn?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no out)") [status \(getAfterOn?.status ?? -1)]
        BT after on: \(btAfterOn?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(n/a)") [status \(btAfterOn?.status ?? -1)]
        """

        NSLog("[SleepNetGuard] DIAG REPORT\n\(report)")

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "SleepNetGuard diagnose"
            alert.informativeText = report
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: Wi‑Fi via device
    private func detectWiFiDevice() -> String? {
        guard let out = run(networksetup, ["-listallhardwareports"])?.stdout else { return nil }
        let lines = out.split(separator: "\n").map(String.init)
        var i = 0
        while i < lines.count {
            if lines[i].contains("Hardware Port: Wi-Fi") || lines[i].contains("Hardware Port: AirPort") {
                for j in (i+1)..<min(i+5, lines.count) where lines[j].hasPrefix("Device:") {
                    let dev = lines[j].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                    return dev.isEmpty ? nil : dev
                }
            }
            i += 1
        }
        return nil
    }

    private func isWiFiPoweredOn() -> Bool {
        let dev = (cachedWiFiInterface ?? detectWiFiDevice()) ?? "en0"
        cachedWiFiInterface = dev
        var res = run(networksetup, ["-getairportpower", dev])
        if res?.status == 9 {
            res = run(networksetup, ["-getairportpower", "Wi-Fi"])
        }
        let out = res?.stdout ?? ""
        if res?.status != 0 { NSLog("[SleepNetGuard] getairportpower \(dev) failed: \(res?.stderr ?? "")") }
        return out.localizedCaseInsensitiveContains(": On")
    }

    private func setWiFiPower(_ on: Bool) -> Bool {
        let dev = (cachedWiFiInterface ?? detectWiFiDevice()) ?? "en0"
        cachedWiFiInterface = dev
        var res = run(networksetup, ["-setairportpower", dev, on ? "on" : "off"])
        if res?.status == 9 {
            res = run(networksetup, ["-setairportpower", "Wi-Fi", on ? "on" : "off"])
        }
        if res?.status != 0 { NSLog("[SleepNetGuard] setairportpower \(dev) \(on ? "on" : "off") failed: \(res?.stderr ?? "")") }
        return res?.status == 0
    }

    // MARK: Bluetooth via blueutil
    private func isBTPoweredOn() -> Bool {
        guard let blueutil = blueutilPath else { return true }
        guard let out = run(blueutil, ["--power"])?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        return out == "1"
    }

    private func setBTPower(_ on: Bool) -> Bool {
        guard let blueutil = blueutilPath else {
            NSLog("[SleepNetGuard] blueutil not found")
            return false
        }
        let res = run(blueutil, ["--power", on ? "1" : "0"])
        if res?.status != 0 { NSLog("[SleepNetGuard] blueutil --power \(on ? "1" : "0") failed: \(res?.stderr ?? "")") }
        return res?.status == 0
    }

    // MARK: Pref helper
    private func boolPref(_ key: String, default def: Bool) -> Bool {
        if prefs.object(forKey: key) == nil { return def }
        return prefs.bool(forKey: key)
    }

    // MARK: Process helper
    private struct CommandResult { let ok: Bool; let stdout: String; let stderr: String; let status: Int32 }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> CommandResult? {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch {
            return CommandResult(ok: false, stdout: "", stderr: "\(error)", status: -1)
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 || !err.isEmpty {
            NSLog("[SleepNetGuard] \(launchPath) \(args.joined(separator: " ")) -> status \(p.terminationStatus), stderr: \(err)")
        }
        return CommandResult(ok: p.terminationStatus == 0, stdout: out, stderr: err, status: p.terminationStatus)
    }
}
