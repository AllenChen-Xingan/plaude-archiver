import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store = Store.load()
    private let ble = BLEManager()
    private var login: LoginWindow?
    private var status = "Idle"
    private var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Plaud")
        }
        ble.onLog = { [weak self] s in self?.setStatus(s) }
        rebuildMenu()
    }

    // MARK: menu

    private func setStatus(_ s: String) { status = s; Store.log(s); rebuildMenu() }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(status))
        menu.addItem(.separator())

        if store.userToken == nil {
            menu.addItem(action("Sign in to Plaud…", #selector(signIn)))
        } else {
            menu.addItem(disabled("Signed in" + (store.haveKeys ? " · keys ready" : "")))
            menu.addItem(action("Download my recordings", #selector(download)))
        }
        menu.addItem(action("Open recordings folder", #selector(openFolder)))
        menu.addItem(action("Choose download folder…", #selector(chooseFolder)))
        menu.addItem(.separator())
        if store.userToken != nil {
            menu.addItem(action("Sign out", #selector(signOut)))
        }
        menu.addItem(action("Quit", #selector(quit)))

        for item in menu.items where item.action != nil && busy && item.action != #selector(quit) {
            item.isEnabled = false
        }
        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; return i
    }

    // MARK: actions

    @objc private func signIn() {
        let win = LoginWindow { [weak self] token in
            guard let self else { return }
            self.store.userToken = token
            self.store.apiHost = PlaudAPI.hostFromToken(token)
            self.store.save()
            self.setStatus("Signed in.")
            self.login = nil
        }
        win.onClose = { [weak self] in self?.login = nil }
        login = win
        win.show()
    }

    @objc private func signOut() {
        store = Store()
        store.save()
        ble.disconnect()
        setStatus("Signed out.")
    }

    @objc private func openFolder() {
        let dir = store.defaultDownloadDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.downloadDir = url.path
            store.save()
            setStatus("Saving to \(url.lastPathComponent).")
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() { ble.disconnect(); NSApp.terminate(nil) }

    @objc private func download() {
        guard !busy else { return }
        busy = true; rebuildMenu()
        Task {
            do { try await self.runDownload() }
            catch { self.setStatus("Error: \(error)") }
            self.busy = false; self.rebuildMenu()
        }
    }

    // MARK: the whole flow

    private func runDownload() async throws {
        guard let token = store.userToken else { throw APIError.message("not signed in") }
        var api = PlaudAPI(userToken: token, host: store.apiHost)

        // 1. RSA key pair (fetch once).
        if store.devicePrivatePEM == nil {
            setStatus("Fetching your encryption key…")
            let k = try await api.genKey()
            store.devicePrivatePEM = k.priv; store.devicePublicPEM = k.pub
            store.apiHost = k.host; api.host = k.host
            store.save()
        }

        // 2. Connect over Bluetooth and read the serial.
        setStatus("Connecting to the device…")
        try await ble.connect()
        defer { ble.disconnect() }   // always drop the link, even if a later step throws
        guard let serial = ble.discoveredSerial else { throw BLEError.message("could not read the device serial") }

        // 3. SN signature for this serial (fetch once per device).
        if store.snSignatures[serial] == nil {
            setStatus("Authorising the device…")
            let s = try await api.snSign(serial: serial)
            store.snSignatures[serial] = s.sig
            store.apiHost = s.host; store.save()
        }

        // 4. Unlock + handshake.
        guard let pem = store.devicePrivatePEM, let pub = store.devicePublicPEM,
              let sig = store.snSignatures[serial] else { throw BLEError.message("missing keys") }
        let privKey = try Crypto.importRSAPrivateKey(pem: Data(pem.utf8))
        try await ble.unlockProtocol20(signatureBase64: sig, privateKey: privKey, publicKeyPEM: pub)

        let userId = PlaudAPI.subject(of: token) ?? serial
        try await ble.handshake(token: userId)

        // 5. List and pull.
        setStatus("Listing recordings…")
        let files = try await ble.listSessions()
        if files.isEmpty { setStatus("No recordings on the device."); return }

        let dir = store.defaultDownloadDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var saved = 0
        for (n, rec) in files.enumerated() {
            let base = dir.appendingPathComponent("plaud_\(rec.sessionId)")
            let ogg = base.appendingPathExtension("ogg")
            if FileManager.default.fileExists(atPath: ogg.path) { saved += 1; continue }
            setStatus("Downloading \(n + 1)/\(files.count)…")
            let raw = try await ble.pullFile(rec) { got, total in
                if total > 0 { self.setStatus("Downloading \(n + 1)/\(files.count) — \(got * 100 / total)%") }
            }
            try raw.write(to: base.appendingPathExtension("plaud"))
            if raw.prefix(8) == Data("PLAUD.AI".utf8) {
                let clear = try Crypto.decryptRecordingFile(raw, privateKey: privKey)
                try clear.write(to: ogg)
            }
            saved += 1
        }
        setStatus("Done. \(saved) recording(s) in \(dir.lastPathComponent).")
    }
}
