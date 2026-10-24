import Foundation
import Security
import SwiftUI
import AppKit

// One recording as the UI sees it.
struct Recording: Identifiable {
    enum State { case onDevice, downloaded, deleted }
    let sessionId: UInt32
    let sizeBytes: Int
    var state: State = .onDevice
    var localURL: URL?

    var id: UInt32 { sessionId }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(sessionId)) }
    // The device stores raw file size; the playable audio is a bit smaller after the header.
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file) }
}

// Drives the dashboard: owns the Bluetooth link, the API and persisted state,
// keeps a live connection, and exposes @Published state for SwiftUI.
@MainActor
final class DeviceModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var storage: StorageInfo?
    @Published var battery: Battery?
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var deviceName: String?
    @Published var serial: String?
    @Published var signedIn = false
    @Published var deleteAfterDownload = false {
        didSet { guard loaded else { return }; store.deleteAfterSync = deleteAfterDownload; store.save() }
    }

    private var store = Store.load()
    private let ble = BLEManager()
    private var login: LoginWindow?
    private var privKey: SecKey?
    private var loaded = false   // suppresses the didSet write during init

    init() {
        signedIn = store.userToken != nil
        deleteAfterDownload = store.deleteAfterSync
        loaded = true
        ble.onLog = { [weak self] s in self?.status = s }
    }

    var downloadDirName: String { store.defaultDownloadDir.lastPathComponent }

    func setDownloadDir(_ url: URL) {
        objectWillChange.send()
        store.downloadDir = url.path
        store.save()
    }

    func openDownloadFolder() {
        let dir = store.defaultDownloadDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: sign in

    func signIn() {
        guard login == nil else { return }   // a sign-in window is already open
        let win = LoginWindow { [weak self] token in
            guard let self else { return }
            self.store.userToken = token
            self.store.apiHost = PlaudAPI.hostFromToken(token)
            self.store.save()
            self.signedIn = true
            self.status = "Signed in."
            self.login = nil
        }
        win.onClose = { [weak self] in self?.login = nil }
        login = win
        win.show()
    }

    func signOut() {
        ble.disconnect()
        store = Store()
        store.save()
        signedIn = false; connected = false
        recordings = []; storage = nil; battery = nil
        status = "Signed out."
    }

    // MARK: connection

    private func ensureReady() async throws {
        guard let token = store.userToken else { throw APIError.message("not signed in") }
        var api = PlaudAPI(userToken: token, host: store.apiHost)
        if store.devicePrivatePEM == nil {
            status = "Fetching your encryption key…"
            let k = try await api.genKey()
            store.devicePrivatePEM = k.priv; store.devicePublicPEM = k.pub
            store.apiHost = k.host; api.host = k.host; store.save()
        }
        if privKey == nil, let pem = store.devicePrivatePEM {
            privKey = try Crypto.importRSAPrivateKey(pem: Data(pem.utf8))
        }
        if ble.isConnected { return }

        status = "Connecting to the device…"
        try await ble.connect()
        self.deviceName = ble.discoveredName
        // Serial may be missing from the advert that matched; fall back to the last one we saw,
        // or the single device we already have a signature for.
        let cachedSingle = store.snSignatures.count == 1 ? store.snSignatures.keys.first : nil
        guard let serial = ble.discoveredSerial ?? store.lastSerial ?? cachedSingle else {
            throw BLEError.message("could not read the device serial")
        }
        self.serial = serial
        store.lastSerial = serial; store.save()
        if store.snSignatures[serial] == nil {
            status = "Authorising the device…"
            let s = try await api.snSign(serial: serial)
            store.snSignatures[serial] = s.sig; store.apiHost = s.host; store.save()
        }
        guard let pem = store.devicePrivatePEM, let pub = store.devicePublicPEM,
              let sig = store.snSignatures[serial], let key = privKey else {
            throw BLEError.message("missing keys")
        }
        _ = pem
        try await ble.unlockProtocol20(signatureBase64: sig, privateKey: key, publicKeyPEM: pub)
        let userId = PlaudAPI.subject(of: token) ?? serial
        try await ble.handshake(token: userId)
        connected = true
    }

    func disconnect() {
        ble.disconnect()
        connected = false
        status = "Disconnected."
    }

    // Headless full-loop self-test (for --selftest): connect, read status, list, then
    // download + verify ONE recording and delete it from the device. Lossless: the delete
    // only runs after a decrypted .ogg (>0 bytes) is confirmed on disk.
    func selfTest() async throws -> String {
        try await ensureReady()
        guard let key = privKey else { throw BLEError.message("no key") }
        var out = ["connected: \(ble.discoveredName ?? "?") serial=\(serial ?? "?")"]
        let before = try? await ble.getStorage()
        if let s = before { out.append("storage before: free=\(s.free) total=\(s.total)") }
        var files = try await ble.listSessions()
        out.append("recordings before: \(files.count) -> \(files.map { $0.sessionId })")
        guard let target = files.min(by: { $0.size < $1.size }) else { return (out + ["no recordings to test with"]).joined(separator: "\n") }
        out.append("target: session \(target.sessionId) (\(target.size) bytes)")

        let raw = try await ble.pullFile(target) { _, _ in }
        guard raw.prefix(8) == Data("PLAUD.AI".utf8) else { throw BLEError.message("unexpected file format; aborting before delete") }
        let dir = store.defaultDownloadDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try raw.write(to: dir.appendingPathComponent("plaud_\(target.sessionId).plaud"))
        let ogg = localURL(for: target.sessionId)
        let clear = try Crypto.decryptRecordingFile(raw, privateKey: key)
        try clear.write(to: ogg)
        let n = ((try? FileManager.default.attributesOfItem(atPath: ogg.path)[.size]) as? Int) ?? 0
        guard n > 0 else { throw BLEError.message("decrypted file empty; aborting before delete") }
        out.append("downloaded + decrypted: \(n) bytes -> \(ogg.lastPathComponent) (verified copy on disk)")

        out.append("deleting session \(target.sessionId) from device…")
        try await ble.deleteRecording(target.sessionId)
        files = try await ble.listSessions()
        let gone = !files.contains { $0.sessionId == target.sessionId }
        out.append("recordings after: \(files.count) -> \(files.map { $0.sessionId })")
        out.append(gone ? "DELETE CONFIRMED: session no longer on device ✓" : "DELETE FAILED: session still listed ✗")
        if let s = try? await ble.getStorage(), let b = before {
            out.append("storage after: free=\(s.free) (reclaimed \(Int64(s.free) - Int64(b.free)) bytes)")
        }
        ble.disconnect()
        return out.joined(separator: "\n")
    }

    // Headless read-only check of the live device ops (for --probe-device). Never deletes.
    func probe() async throws -> String {
        try await ensureReady()
        var out = ["connected: \(ble.discoveredName ?? "?")  serial=\(serial ?? "?")"]
        if let s = try? await ble.getStorage() {
            out.append("storage: free=\(s.free) total=\(s.total) duration=\(s.durationSeconds)")
        } else { out.append("storage: (no reply)") }
        if let b = try? await ble.getBattery() {
            out.append("battery: \(b.level)% charging=\(b.charging)")
        } else { out.append("battery: (no reply)") }
        if let r = try? await ble.getRecordingState() {
            out.append("recording: \(r.recording) sessionId=\(r.sessionId)")
        } else { out.append("recording: (no reply)") }
        let files = try await ble.listSessions()
        out.append("recordings: \(files.count)")
        for f in files.prefix(10) { out.append("  session \(f.sessionId) (\(dateText(f.sessionId)))  \(f.size) bytes") }
        ble.disconnect()
        return out.joined(separator: "\n")
    }

    // MARK: actions

    private func run(_ label: String, _ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do { try await op() }
            catch { status = "Error: \(error)"; connected = ble.isConnected }
            busy = false
        }
    }

    func refresh() {
        run("refresh") {
            try await self.ensureReady()
            self.status = "Reading device…"
            self.storage = try? await self.ble.getStorage()
            self.battery = try? await self.ble.getBattery()
            let files = try await self.ble.listSessions()
            let existing = Dictionary(uniqueKeysWithValues: self.recordings.map { ($0.sessionId, $0) })
            self.recordings = files.map { f in
                if let r = existing[f.sessionId] {
                    return Recording(sessionId: f.sessionId, sizeBytes: Int(f.size), state: r.state, localURL: r.localURL)
                }
                let url = self.localURL(for: f.sessionId)
                let onDisk = FileManager.default.fileExists(atPath: url.path)
                return Recording(sessionId: f.sessionId, sizeBytes: Int(f.size),
                                 state: onDisk ? .downloaded : .onDevice, localURL: onDisk ? url : nil)
            }.sorted { $0.sessionId > $1.sessionId }
            self.status = "\(self.recordings.count) recording(s) on the device."
        }
    }

    func downloadAll() {
        run("downloadAll") {
            try await self.ensureReady()
            let todo = self.recordings.filter { $0.state == .onDevice }
            for rec in todo { try await self.downloadOne(rec.sessionId) }
            self.status = "Done."
        }
    }

    func download(_ sessionId: UInt32) {
        run("download") {
            try await self.ensureReady()
            try await self.downloadOne(sessionId)   // sets its own final status
        }
    }

    func delete(_ sessionId: UInt32) {
        run("delete") {
            try await self.ensureReady()
            try await self.ble.deleteRecording(sessionId)
            self.mark(sessionId, .deleted)
            self.storage = try? await self.ble.getStorage()
            self.status = "Deleted from device."
        }
    }

    // MARK: helpers

    private func downloadOne(_ sessionId: UInt32) async throws {
        guard let rec = recordings.first(where: { $0.sessionId == sessionId }), let key = privKey else { return }
        let info = RecordingInfo(sessionId: sessionId, size: UInt32(rec.sizeBytes))
        status = "Downloading \(dateText(sessionId))…"
        let raw = try await ble.pullFile(info) { got, total in
            if total > 0 { self.status = "Downloading \(self.dateText(sessionId)) — \(got * 100 / total)%" }
        }
        let dir = store.defaultDownloadDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try raw.write(to: dir.appendingPathComponent("plaud_\(sessionId).plaud"))
        // Only a verified decrypt counts as a safe local copy. If the device ever returns an
        // unexpected format, keep the raw .plaud and NEVER delete the device's copy.
        guard raw.prefix(8) == Data("PLAUD.AI".utf8) else {
            status = "Saved an encrypted copy in an unexpected format — keeping it on the device."
            return
        }
        let ogg = localURL(for: sessionId)
        try Crypto.decryptRecordingFile(raw, privateKey: key).write(to: ogg)
        updateLocal(sessionId, url: ogg)
        status = "Downloaded \(dateText(sessionId))."
        if deleteAfterDownload {
            try await ble.deleteRecording(sessionId)
            mark(sessionId, .deleted)
            storage = try? await ble.getStorage()
            status = "Downloaded and removed \(dateText(sessionId)) from the device."
        }
    }

    private func localURL(for sessionId: UInt32) -> URL {
        store.defaultDownloadDir.appendingPathComponent("plaud_\(sessionId).ogg")
    }
    func dateText(_ sessionId: UInt32) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(sessionId)))
    }
    private func mark(_ sessionId: UInt32, _ state: Recording.State) {
        if let i = recordings.firstIndex(where: { $0.sessionId == sessionId }) { recordings[i].state = state }
    }
    private func updateLocal(_ sessionId: UInt32, url: URL) {
        if let i = recordings.firstIndex(where: { $0.sessionId == sessionId }) {
            recordings[i].state = .downloaded; recordings[i].localURL = url
        }
    }
}
