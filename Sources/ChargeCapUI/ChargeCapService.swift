import AppKit
import ChargeCapCore
import ChargeCapKit

/// Everything the menu bar side does, behind one small API, so it runs on its own (the ChargeCap app) or as a
/// module inside KTools. It never touches the SMC: it reads the battery and the keys (no root needed), and
/// changes the limit by replacing config.json, which the root daemon watches and applies at once.
@MainActor
public final class ChargeCapService: NSObject {
    public static let presets = [60, 65, 70, 75, 80, 85, 90, 95]
    public static let heatPresets = [35, 38, 40]

    /// Called after every refresh, so the host can update its icon or text.
    public var onChange: (() -> Void)?
    public private(set) var battery: BatteryInfo?
    public private(set) var config = Config()
    public private(set) var keys: SMCState?

    private let directory = ConfigStore.directory()
    private var timer: Timer?
    private var watcher: PowerWatcher?
    private static let plist = "/Library/LaunchDaemons/dev.kelvin.chargecap.plist"

    public override init() {
        super.init()
    }

    public var isRunning: Bool { timer != nil }

    public func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        watcher = PowerWatcher { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        watcher = nil
    }

    public func refresh() {
        battery = Battery.read()
        config = ConfigStore.load(from: directory)
        keys = try? SMCClient().readState()
        onChange?()
    }

    // MARK: - What to show

    public var daemonInstalled: Bool { FileManager.default.fileExists(atPath: Self.plist) }

    /// "80%" next to the icon.
    public var title: String { battery.map { "\($0.percent)%" } ?? "–" }

    public var symbol: String {
        guard let b = battery else { return "battery.0percent" }
        if b.isCharging { return "battery.100percent.bolt" }
        return b.notChargingReason != 0 ? "battery.75percent" : "battery.100percent"
    }

    /// One line for the menu header and the KTools row.
    public var summary: String {
        guard let b = battery else { return "Baterai tidak terbaca" }
        let limit = config.enabled && config.limit < 100 ? "batas \(config.limit)%" : "tanpa batas"
        let what: String
        if config.topUp { what = "mengisi sampai 100% (sekali)" }
        else if !b.externalConnected { what = "memakai baterai" }
        else if b.isCharging { what = "mengisi" }
        else if b.notChargingReason != 0 { what = "ditahan di batas" }
        else { what = "tidak mengisi" }
        return "\(b.percent)% · \(what) · \(limit)"
    }

    /// A problem worth a warning line, or nil.
    public var warning: String? {
        if !daemonInstalled { return "⚠︎ Daemon belum terpasang (jalankan scripts/install.sh)" }
        if let keys, let b = battery {
            let want = Policy.decide(config: config, conditions: b.conditions, previous: PolicyState()).target
            if !keys.satisfies(want) { return "⚠︎ Kunci SMC belum sesuai config; menunggu daemon" }
        }
        return nil
    }

    // MARK: - Menu

    public func fillMenu(_ menu: NSMenu) {
        refresh()
        let header = menu.addItem(withTitle: summary, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let b = battery, let t = b.temperatureC {
            let line = menu.addItem(withTitle: String(format: "Suhu baterai %.1f°C", t), action: nil, keyEquivalent: "")
            line.isEnabled = false
        }
        if let warning {
            let w = menu.addItem(withTitle: warning, action: nil, keyEquivalent: "")
            w.isEnabled = false
        }
        menu.addItem(.separator())

        let limitMenu = NSMenu()
        for value in Self.presets {
            let item = add(to: limitMenu, "\(value)%", #selector(chooseLimit(_:)))
            item.representedObject = value
            item.state = config.enabled && config.limit == value ? .on : .off
        }
        limitMenu.addItem(.separator())
        let none = add(to: limitMenu, "Tanpa batas (100%)", #selector(chooseLimit(_:)))
        none.representedObject = 100
        none.state = !config.enabled || config.limit >= 100 ? .on : .off
        menu.addItem(withTitle: "Batas pengisian", action: nil, keyEquivalent: "").submenu = limitMenu

        let topUp = add(to: menu, config.topUp ? "Batalkan isi sampai 100%" : "Isi sampai 100% sekali", #selector(toggleTopUp))
        topUp.state = config.topUp ? .on : .off

        let heatMenu = NSMenu()
        let heatOff = add(to: heatMenu, "Mati", #selector(chooseHeat(_:)))
        heatOff.representedObject = 0
        heatOff.state = config.heatLimitC == 0 ? .on : .off
        for value in Self.heatPresets {
            let item = add(to: heatMenu, "Berhenti mengisi di \(value)°C", #selector(chooseHeat(_:)))
            item.representedObject = value
            item.state = config.heatLimitC == value ? .on : .off
        }
        menu.addItem(withTitle: "Proteksi suhu", action: nil, keyEquivalent: "").submenu = heatMenu

        menu.addItem(.separator())
        add(to: menu, "Buka log", #selector(openLog))
        add(to: menu, "Buka folder config", #selector(openConfig))
    }

    /// Pops the menu up at the mouse (for hosts that have no status item button of their own).
    public func popUpMenu() {
        let menu = NSMenu()
        fillMenu(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func chooseLimit(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        update { $0.enabled = value < 100; $0.limit = value; $0.topUp = false }
    }

    @objc private func toggleTopUp() {
        update { $0.topUp.toggle() }
    }

    @objc private func chooseHeat(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        update { $0.heatLimitC = value }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: FileLog().path))
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(directory)
    }

    /// Loads the file again (it may have changed), applies the change, saves. The daemon does the rest.
    private func update(_ change: (inout Config) -> Void) {
        var next = ConfigStore.load(from: directory)
        change(&next)
        do {
            try ConfigStore.save(next, to: directory)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Tidak bisa menyimpan pengaturan"
            alert.informativeText = "\(error.localizedDescription)\n\nJalankan ulang `sudo scripts/install.sh` supaya folder config bisa ditulis tanpa sudo."
            alert.runModal()
        }
        refresh()
    }
}
