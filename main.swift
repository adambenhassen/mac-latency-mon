import Cocoa
import ServiceManagement

let kIP = "targetIP"
let kInterval = "intervalSeconds"

/// Bar sparkline of recent RTTs. nil = timeout, drawn as a red baseline tick.
final class SparklineView: NSView {
    var samples: [Int?] = [] { didSet { needsDisplay = true } }
    let capacity = 60

    override func draw(_ dirtyRect: NSRect) {
        guard !samples.isEmpty else { return }
        // 21pt left = standard menu-item text indent; 14pt right ≈ trailing text margin
        let plot = NSRect(x: 21, y: bounds.minY + 6,
                          width: bounds.width - 21 - 14, height: bounds.height - 12)
        let labelBand: CGFloat = 12               // reserved strip for the peak label
        let barTop = plot.height - labelBand      // bars never enter the label band
        let slot = plot.width / CGFloat(capacity)
        let barW = max(1, (slot - 1).rounded(.down))   // pixel-aligned, 1px gap
        let peakMs = samples.compactMap { $0 }.max() ?? 1
        let peak = CGFloat(peakMs)

        // baseline hairline
        NSColor.separatorColor.setFill()
        NSRect(x: plot.minX, y: plot.minY - 1, width: plot.width, height: 1).fill()

        // faint peak guide + label, so the scale is readable at a glance
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: plot.minX, y: plot.minY + barTop, width: plot.width, height: 1).fill()
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let peakLabel = NSAttributedString(string: "\(peakMs) ms", attributes: labelAttrs)
        peakLabel.draw(at: NSPoint(x: plot.maxX - peakLabel.size().width,
                                   y: plot.minY + barTop + 1))

        let lastIndex = samples.count - 1
        for (i, s) in samples.enumerated() {
            let x = (plot.minX + CGFloat(i) * slot).rounded()
            if let ms = s {
                // sqrt scale: keeps normal jitter readable when one spike dominates
                let h = max(3, (barTop * sqrt(CGFloat(ms) / max(peak, 1))).rounded())
                let color = (i == lastIndex) ? NSColor.controlAccentColor
                                             : NSColor.labelColor.withAlphaComponent(0.55)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: plot.minY, width: barW, height: h),
                             xRadius: 1, yRadius: 1).fill()
            } else {
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: plot.minY, width: barW, height: 3),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}

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

    // Stats since launch / reset
    private var okCount = 0
    private var timeoutCount = 0
    private var sumMs = 0
    private var minMs: Int?
    private var maxMs: Int?
    private var latencyItem: NSMenuItem!
    private var lossItem: NSMenuItem!
    private var latencyField: NSTextField!
    private var lossField: NSTextField!
    private let sparkline = SparklineView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))

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
        let (header, headerField) = Self.labelItem()
        headerField.stringValue = "Target: \(ip)"
        menu.addItem(header)
        menu.addItem(.separator())
        (latencyItem, latencyField) = Self.labelItem()
        menu.addItem(latencyItem)
        (lossItem, lossField) = Self.labelItem()
        menu.addItem(lossItem)
        updateStatsItems()
        let chartItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sparkline.autoresizingMask = [.width]   // stretch to actual menu width
        chartItem.view = sparkline
        menu.addItem(chartItem)
        menu.addItem(NSMenuItem(title: "Reset Stats", action: #selector(resetStats), keyEquivalent: ""))
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
            if !v.isEmpty { ip = v; resetStats(); buildMenu(); restartTimer() }
        }
    }

    // MARK: - Stats

    @objc private func resetStats() {
        okCount = 0; timeoutCount = 0; sumMs = 0; minMs = nil; maxMs = nil
        sparkline.samples = []
        updateStatsItems()
    }

    private func record(_ ms: Int?) {
        if let ms = ms {
            okCount += 1
            sumMs += ms
            minMs = min(minMs ?? ms, ms)
            maxMs = max(maxMs ?? ms, ms)
        } else {
            timeoutCount += 1
        }
        sparkline.samples.append(ms)
        if sparkline.samples.count > sparkline.capacity {
            sparkline.samples.removeFirst(sparkline.samples.count - sparkline.capacity)
        }
        updateStatsItems()
    }

    /// The system dims action-less menu items regardless of attributed-title
    /// color, so stat rows are view-backed with a text field we fully control.
    private static func labelItem() -> (NSMenuItem, NSTextField) {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.textColor = .labelColor
        // 21pt left indent / 14pt right margin match standard menu-item text
        field.frame = NSRect(x: 21, y: 2, width: 240 - 21 - 14, height: 17)
        field.autoresizingMask = [.width]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 21))
        view.autoresizingMask = [.width]
        view.addSubview(field)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        return (item, field)
    }

    private func updateStatsItems() {
        let total = okCount + timeoutCount
        if total == 0 {
            latencyField.stringValue = "No samples yet"
            lossItem.isHidden = true
            return
        }
        lossItem.isHidden = false
        if let mn = minMs, let mx = maxMs, okCount > 0 {
            latencyField.stringValue = "Min \(mn) · Avg \(sumMs / okCount) · Max \(mx) ms"
        } else {
            latencyField.stringValue = "No replies yet"
        }
        let lossPct = Int((Double(timeoutCount) / Double(total) * 100).rounded())
        lossField.stringValue = "Loss \(lossPct)% (\(timeoutCount)/\(total))"
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
        record(ms)
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
