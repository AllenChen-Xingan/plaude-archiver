import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
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
        openWindow()
    }

    @objc private func openWindow() {
        if window == nil {
            let host = NSHostingController(rootView: LibraryView())
            let w = NSWindow(contentViewController: host)
            w.title = "Plaude · 本地录音库与 AI"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 1020, height: 700))
            window = w
            w.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Library jobs use exact account-device matching; never auto-connect via legacy cached serials.
    }

    @objc private func openFolder() {
        let path = UserDefaults.standard.string(forKey:"LibraryFolder") ??
            FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("PlaudeArchiverCN/Library").path
        let url = URL(fileURLWithPath:path,isDirectory:true)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        NSWorkspace.shared.open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // UI lifetime does not own CLI transport or background jobs.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
