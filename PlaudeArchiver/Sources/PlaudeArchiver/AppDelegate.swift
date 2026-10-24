import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let model = DeviceModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Plaude Archiver")

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Plaude Archiver…", action: #selector(openWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Open recordings folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func openWindow() {
        if window == nil {
            let host = NSHostingController(rootView: DashboardView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Plaude Archiver"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 580, height: 500))
            window = w
            w.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if model.signedIn { model.refresh() }
    }

    @objc private func openFolder() { model.openDownloadFolder() }

    @objc private func quit() { model.disconnect(); NSApp.terminate(nil) }

    // Returning to menu-bar-only and dropping the Bluetooth link when the window closes.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            model.disconnect()
        }
    }
}
