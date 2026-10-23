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
    @Published var recordingState: RecordingState?
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var deviceName: String?
    @Published var serial: String?
    @Published var signedIn = false
    @Published var deleteAfterDownload = false {
        didSet { store.deleteAfterSync = deleteAfterDownload; store.save() }
    }

    private var store = Store.load()
    private let ble = BLEManager()
    private var login: LoginWindow?
    private var privKey: SecKey?

    init() {
        signedIn = store.userToken != nil
        deleteAfterDownload = store.deleteAfterSync
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
        recordings = []; storage = nil; battery = nil; recordingState = nil
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
        guard let serial = ble.discoveredSerial else { throw BLEError.message("could not read the device serial") }
        self.serial = serial
        self.deviceName = ble.discoveredName
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
            self.recordingState = try? await self.ble.getRecordingState()
            let files = try await self.ble.listSessions()
            let existing = Dictionary(uniqueKeysWithValues: self.recordings.map { ($0.sessionId, $0) })
            self.recordings = files.map { f in
                if var r = existing[f.sessionId] { r = Recording(sessionId: f.sessionId, sizeBytes: Int(f.size), state: r.state, localURL: r.localURL); return r }
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
            try await self.downloadOne(sessionId)
            self.status = "Downloaded."
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

    func stopRecording() {
        run("stop") {
            try await self.ensureReady()
            try await self.ble.stopRecording()
            self.recordingState = try? await self.ble.getRecordingState()
            self.status = "Recording stopped."
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
        let ogg = localURL(for: sessionId)
        if raw.prefix(8) == Data("PLAUD.AI".utf8) {
            try Crypto.decryptRecordingFile(raw, privateKey: key).write(to: ogg)
        }
        updateLocal(sessionId, url: ogg)
        if deleteAfterDownload {
            try await ble.deleteRecording(sessionId)
            mark(sessionId, .deleted)
            storage = try? await ble.getStorage()
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
