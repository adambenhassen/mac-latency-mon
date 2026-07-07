import Cocoa
import ServiceManagement

let kIP = "targetIP"
let kInterval = "intervalSeconds"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private var ip: String {
        get { defaults.string(forKey: kIP) ?? "1.1.1.1" }
        set { defaults.set(newValue, forKey: kIP) }
    }
    private var interval: Double {
        get { let v = defaults.double(forKey: kInterval); return v == 0 ? 5 : v }
        set { defaults.set(newValue, forKey: kInterval) }
    }
    private var isPinging = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        buildMenu()
        if defaults.string(forKey: kIP) == nil { promptForIP() }
        restartTimer()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Target: \(ip)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Set IP…", action: #selector(setIP), keyEquivalent: "s"))

        let intervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for sec in [0.1, 0.5, 1, 2, 5, 10] as [Double] {
            let label = (sec == sec.rounded()) ? "\(Int(sec))s" : "\(sec)s"
            let it = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.representedObject = sec
            it.state = (sec == interval) ? .on : .off
            intervalMenu.addItem(it)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func setIP() { promptForIP() }

    private func promptForIP() {
        let alert = NSAlert()
        alert.messageText = "Target IP or host"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = ip
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { ip = v; buildMenu(); restartTimer() }
        }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Double else { return }
        interval = sec
        buildMenu()
        restartTimer()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert(); a.messageText = "Login item change failed"
            a.informativeText = error.localizedDescription; a.runModal()
        }
        buildMenu()
    }

    // MARK: - Pinging

    private func restartTimer() {
        timer?.invalidate()
        ping()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.ping()
        }
    }

    private func ping() {
        if isPinging { return }   // don't stack pings when interval < ping duration
        isPinging = true
        let target = ip
        DispatchQueue.global().async { [weak self] in
            let ms = Self.pingOnce(target)
            DispatchQueue.main.async { self?.isPinging = false; self?.render(ms) }
        }
    }

    private func render(_ ms: Int?) {
        guard let button = statusItem.button else { return }
        if let ms = ms {
            button.image = nil
            button.title = "\(ms)ms"
        } else {
            button.title = ""
            let img = NSImage(systemSymbolName: "exclamationmark.triangle",
                              accessibilityDescription: "timeout")
            img?.isTemplate = true   // monochrome, follows menu-bar color (white)
            button.image = img
        }
    }

    /// Returns rounded RTT in ms, or nil on timeout/unreachable/parse-failure.
    static func pingOnce(_ host: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "1", "-t", "2", "-W", "1000", host]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: data, encoding: .utf8) ?? ""
        return parseRTT(out)
    }

    /// Extract the `time=NN.N` value (ms) from ping stdout.
    static func parseRTT(_ output: String) -> Int? {
        guard let r = output.range(of: #"time=([0-9.]+)"#, options: .regularExpression) else { return nil }
        let token = output[r].dropFirst("time=".count)
        guard let v = Double(token) else { return nil }
        return Int(v.rounded())
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
