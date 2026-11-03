import AppKit
import ChargeCapUI

/// Standalone ChargeCap: one menu bar icon with the battery percent. Left or right click opens the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let service = ChargeCapService()
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        service.onChange = { [weak self] in self?.updateIcon() }
        service.start()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: service.symbol, accessibilityDescription: "ChargeCap")
        button.imagePosition = .imageLeading
        button.title = " " + service.title
    }

    /// Rebuilt each time it opens, so the numbers and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        service.fillMenu(menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ChargeCap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
