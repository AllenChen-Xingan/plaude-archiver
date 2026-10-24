import Foundation
import CoreBluetooth
import CryptoKit
import Security

struct RecordingInfo { let sessionId: UInt32; let size: UInt32 }

enum BLEError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "ble error" }
}

@MainActor
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var session: Session?
    private var portVersion = 20

    // Ordered packet buffer + a single pending data waiter (flows are sequential).
    private var buffer: [Data] = []
    private var waiter: (CheckedContinuation<Data, Error>, DispatchWorkItem)?

    // Single continuation for the current connection-setup step.
    private enum Step { case power, connect, ready }
    private var stepCont: CheckedContinuation<Void, Error>?
    private var stepTimeout: DispatchWorkItem?
    private var stepKind: Step?

    var onLog: (String) -> Void = { _ in }
    private(set) var discoveredName: String?
    private(set) var discoveredSerial: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)   // main queue
    }

    private func log(_ s: String) { onLog(s) }

    // MARK: connection

    func connect(timeout: TimeInterval = 25) async throws {
        do {
            if central.state != .poweredOn { try await awaitStep(.power, timeout) }
            guard central.state == .poweredOn else { throw BLEError.message("Bluetooth not available") }
            log("Scanning for a Plaude device…")
            // The device advertises service 0x504C (and the full 0x1910 is only visible after
            // connecting), so scan broadly and match in didDiscover.
            central.scanForPeripherals(withServices: nil, options: nil)
            try await awaitStep(.connect, timeout)
            log("Connected. Discovering services…")
            try await awaitStep(.ready, timeout)
            log("Ready\(discoveredName.map { " (\($0))" } ?? "").")
        } catch {
            // Don't leave the central scanning or a peripheral half-connected on failure.
            central.stopScan()
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil; writeChar = nil; notifyChar = nil
            throw error
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil; notifyChar = nil; session = nil; portVersion = 20
        // Drop any state left from the prior session so a reconnect starts clean.
        buffer.removeAll(); secretParts.removeAll(); secretTotal = nil; sawFE11 = false
        failWaiter(BLEError.message("disconnected"))
    }

    var isConnected: Bool { peripheral?.state == .connected && writeChar != nil && session != nil }

    private func awaitStep(_ kind: Step, _ timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stepKind = kind
            stepCont = cont
            let item = DispatchWorkItem { [weak self] in self?.resolveStep(.failure(BLEError.message("timed out"))) }
            stepTimeout = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    private func resolveStep(_ result: Result<Void, Error>) {
        guard let cont = stepCont else { return }
        stepTimeout?.cancel(); stepTimeout = nil; stepCont = nil; stepKind = nil
        cont.resume(with: result)
    }

    // MARK: central/peripheral delegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Store.log("central state = \(c.state.rawValue) (poweredOn=5, unauthorized=3, poweredOff=4)")
        switch c.state {
        case .poweredOn: if stepKind == .power { resolveStep(.success(())) }
        case .unauthorized:
            resolveStep(.failure(BLEError.message("Bluetooth permission denied. Allow it in System Settings › Privacy & Security › Bluetooth.")))
        case .poweredOff:
            resolveStep(.failure(BLEError.message("Bluetooth is turned off.")))
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral == nil else { return }   // already connecting to one
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // Require a strong Plaud signal: the service UUID or a Plaud name. The manufacturer-data
        // serial is NOT enough to match on — its loose hex heuristic fires on unrelated beacons,
        // and a wrong connect stops the scan and then stalls until timeout.
        let isPlaud = uuids.contains(CBUUID(string: "504C")) || uuids.contains(CBUUID(string: Proto.service))
            || (name?.lowercased().contains("plaud") ?? false)
        guard isPlaud else { return }   // not a Plaud device; keep scanning
        c.stopScan()
        peripheral = p
        discoveredName = name
        // The serial lives in the manufacturer-data packet, which isn't always the same
        // advertisement that carried the name/service. Only set it when this packet has it;
        // don't clobber a serial learned from an earlier advert or connection.
        if let s = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            .flatMap({ BLEManager.serial(fromManufacturerData: $0) }) {
            discoveredSerial = s
        }
        log("Found \(name ?? "device")\(discoveredSerial.map { " (serial \($0))" } ?? "").")
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        if stepKind == .connect { resolveStep(.success(())) }
        p.discoverServices([CBUUID(string: Proto.service)])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        resolveStep(.failure(BLEError.message("connect failed: \(error?.localizedDescription ?? "?")")))
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        resolveStep(.failure(BLEError.message("device disconnected")))
        failWaiter(BLEError.message("device disconnected"))
        // Clear state so the next connect() isn't blocked by the stale peripheral guard.
        peripheral = nil; writeChar = nil; notifyChar = nil; session = nil
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == CBUUID(string: Proto.service) }) else {
            resolveStep(.failure(BLEError.message("Plaude service not found"))); return
        }
        p.discoverCharacteristics([CBUUID(string: Proto.notifyChar), CBUUID(string: Proto.writeChar)], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for ch in svc.characteristics ?? [] {
            if ch.uuid == CBUUID(string: Proto.notifyChar) { notifyChar = ch; p.setNotifyValue(true, for: ch) }
            if ch.uuid == CBUUID(string: Proto.writeChar) { writeChar = ch }
        }
        if notifyChar != nil && writeChar != nil { resolveStep(.success(())) }
        else { resolveStep(.failure(BLEError.message("characteristics missing"))) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == CBUUID(string: Proto.notifyChar), let raw = ch.value else { return }
        if let s = session {
            if let inner = s.open(raw) { incoming(inner) }   // nil => replay / undecryptable; drop
        } else {
            incoming(raw)
        }
    }

    // MARK: packet plumbing

    private func incoming(_ pkt: Data) {
        if let (cont, item) = waiter { waiter = nil; item.cancel(); cont.resume(returning: pkt) }
        else { buffer.append(pkt) }
    }

    private func failWaiter(_ err: Error) {
        guard let (cont, item) = waiter else { return }
        waiter = nil; item.cancel(); cont.resume(throwing: err)
    }

    private func nextPacket(timeout: TimeInterval) async throws -> Data {
        if !buffer.isEmpty { return buffer.removeFirst() }
        return try await withCheckedThrowingContinuation { cont in
            let item = DispatchWorkItem { [weak self] in
                guard let self, let w = self.waiter else { return }
                self.waiter = nil
                w.0.resume(throwing: BLEError.message("timed out waiting for the device"))
            }
            waiter = (cont, item)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    private func send(_ data: Data) throws {
        guard let w = writeChar, let p = peripheral else { throw BLEError.message("not connected") }
        let payload = try (session?.seal(data)) ?? data
        p.writeValue(payload, for: w, type: .withoutResponse)
    }

    // MARK: protocol-20 unlock

    private var secretParts: [Int: Data] = [:]
    private var secretTotal: Int?
    private var sawFE11 = false

    func unlockProtocol20(signatureBase64: String, privateKey: SecKey, publicKeyPEM: String) async throws {
        guard let sig = Data(base64Encoded: signatureBase64) else { throw BLEError.message("bad signature base64") }
        secretParts.removeAll(); secretTotal = nil; sawFE11 = false
        log("Sending the device signature (\(sig.count) bytes)…")

        func sendChunks(_ cmd: UInt16, _ blob: Data) async throws {
            let n = (blob.count + 99) / 100
            for i in 0..<n {
                let slice = blob.subdata(in: (i * 100)..<min((i + 1) * 100, blob.count))
                try send(Proto.feChunk(cmd, total: n, index: i, slice))
                _ = try? await collectSecret(timeout: i < n - 1 ? 3 : 10)
            }
        }

        try await sendChunks(Proto.FE10, sig)
        if sawFE11 {
            log("First bind: sending your public key…")
            secretParts.removeAll()
            try await sendChunks(Proto.FE12, Data(publicKeyPEM.utf8))
        }
        while secretTotal == nil || secretParts.count < (secretTotal ?? 1) {
            _ = try await collectSecret(timeout: 10)
        }

        let blob = secretParts.keys.sorted().reduce(Data()) { acc, k in
            let p = secretParts[k]!
            return acc + p.suffix(from: p.startIndex.advanced(by: 4))
        }
        let plain = try Crypto.rsaDecryptPKCS1(blob, key: privateKey)
        guard plain.count >= 56 else { throw BLEError.message("session secret too short (\(plain.count))") }
        let key = Data(plain.prefix(32))
        let nonce = plain.subdata(in: plain.startIndex.advanced(by: 32)..<plain.startIndex.advanced(by: 44))
        let aad = plain.subdata(in: plain.startIndex.advanced(by: 44)..<plain.startIndex.advanced(by: 56))

        // Verify the tail decrypts to "PLAUD.AI".
        let tail = Data(plain.suffix(from: plain.startIndex.advanced(by: 56)))
        if tail.count >= 16 {
            let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonce),
                                               ciphertext: tail.prefix(tail.count - 16), tag: tail.suffix(16))
            let v = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
            guard v == Data("PLAUD.AI".utf8) else { throw BLEError.message("session check failed") }
        }
        session = Session(key: key, nonce: nonce, aad: aad)
        log("Encrypted session established.")
    }

    private func collectSecret(timeout: TimeInterval) async throws -> Data {
        let pkt = try await nextPacket(timeout: timeout)
        guard pkt.count >= 2 else { return pkt }
        let cmd = UInt16(pkt[pkt.startIndex]) | (UInt16(pkt[pkt.startIndex + 1]) << 8)
        if cmd == Proto.FE30 {
            throw BLEError.message("device started an ECC session (0xFE30); this build only supports protocol 20")
        }
        if cmd == Proto.FE11 { sawFE11 = true }
        if cmd == Proto.FE12, pkt.count >= 4 {
            sawFE11 = false
            secretTotal = Int(pkt[pkt.startIndex + 2])
            secretParts[Int(pkt[pkt.startIndex + 3])] = pkt
        }
        return pkt
    }

    // MARK: handshake / list / pull

    func handshake(token: String) async throws {
        try send(Proto.handshake(token: token, portVersion: portVersion, second: false))
        var rsp = try await waitCommand([Proto.CMD_HANDSHAKE, Proto.CMD_GET_SSN], timeout: 10)
        if cmdOf(rsp) == Proto.CMD_GET_SSN {
            log("Second handshake…")
            try send(Proto.handshake(token: token, portVersion: portVersion, second: true))
            rsp = try await waitCommand([Proto.CMD_HANDSHAKE], timeout: 10)
        }
        let status = rsp.count > 3 ? Int(rsp[rsp.startIndex + 3]) : -1
        guard status == 0 else { throw BLEError.message("handshake refused, status=\(status)") }
        if rsp.count >= 6 { portVersion = Int(rsp[rsp.startIndex + 4]) | (Int(rsp[rsp.startIndex + 5]) << 8) }
        log("Handshake OK (protocol \(portVersion)).")
    }

    func listSessions() async throws -> [RecordingInfo] {
        try send(Proto.sessionList())
        var files: [RecordingInfo] = []
        var seen = Set<UInt32>()
        var total: Int? = nil
        while total == nil || files.count < total! {
            let b = try await waitCommand([Proto.CMD_GET_REC_SESSIONS], timeout: 15)
            if total == nil, b.count >= 9 { total = Int(b[b.startIndex + 7]) | (Int(b[b.startIndex + 8]) << 8) }
            guard b.count >= 11 else { continue }
            let idx = Int(b[b.startIndex + 9]) | (Int(b[b.startIndex + 10]) << 8)
            if idx != files.count { continue }
            let entry = portVersion == 1 ? 8 : (portVersion <= 6 ? 9 : 10)
            var off = 11
            while off + entry <= b.count {
                let sid = le32(b, b.startIndex.advanced(by: off))
                let size = le32(b, b.startIndex.advanced(by: off + 4))
                if seen.insert(sid).inserted { files.append(RecordingInfo(sessionId: sid, size: size)) }
                off += entry
            }
        }
        return files
    }

    func pullFile(_ rec: RecordingInfo, onProgress: (Int, Int) -> Void) async throws -> Data {
        try send(Proto.syncStart(session: rec.sessionId, start: 0, end: rec.size))
        let head = try await waitCommand([Proto.CMD_SYNC_FILE_START], timeout: 15)
        if head.count > 7, head[head.startIndex + 7] > 0 {
            throw BLEError.message("device refused sync, status=\(head[head.startIndex + 7])")
        }
        var data = Data()
        while true {
            let pkt = try await nextPacket(timeout: 20)
            if pkt.count >= 3, pkt[pkt.startIndex] == 1, cmdOf(pkt) == Proto.CMD_SYNC_FILE_TAIL { break }
            guard pkt.count >= 1, pkt[pkt.startIndex] == 2 else { continue }
            var i = 1
            if portVersion >= 7 {
                guard pkt.count >= 5, le32(pkt, pkt.startIndex.advanced(by: 1)) == rec.sessionId else { continue }
                i = 5
            }
            guard pkt.count >= i + 5 else { continue }
            let offset = le32(pkt, pkt.startIndex.advanced(by: i))
            if offset == 0xFFFF_FFFF { break }
            let n = Int(pkt[pkt.startIndex.advanced(by: i + 4)])
            let start = pkt.startIndex.advanced(by: i + 5)
            let chunk = pkt.subdata(in: start..<min(start.advanced(by: n), pkt.endIndex))
            if Int(offset) != data.count { break }   // gap: stop here; the size check below fails
            data.append(chunk)
            onProgress(data.count, Int(rec.size))
        }
        // A dropped packet ends the loop early; don't present a short file as complete.
        if rec.size > 0, data.count != Int(rec.size) {
            throw BLEError.message("incomplete download: got \(data.count) of \(rec.size) bytes")
        }
        return data
    }

    // MARK: helpers

    private func waitCommand(_ cmds: [UInt16], timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw BLEError.message("timed out") }
            let pkt = try await nextPacket(timeout: remaining)
            if pkt.count >= 3, pkt[pkt.startIndex] == 1, cmds.contains(cmdOf(pkt)) { return pkt }
        }
    }

    // The serial is 8 bytes inside the manufacturer data; its uppercase hex is the serial
    // string and starts with the 3-digit model code (881 = Note Pro, 888 Note, 880/882 Pin, 860 One).
    static func serial(fromManufacturerData data: Data) -> String? {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        let models = ["881", "888", "880", "882", "860"]
        var i = hex.startIndex
        while let end = hex.index(i, offsetBy: 16, limitedBy: hex.endIndex) {
            let window = String(hex[i..<end])
            if models.contains(where: { window.hasPrefix($0) }) { return window }
            guard let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) else { break }
            i = next   // stay byte-aligned
        }
        return nil
    }

    private func cmdOf(_ pkt: Data) -> UInt16 {
        UInt16(pkt[pkt.startIndex + 1]) | (UInt16(pkt[pkt.startIndex + 2]) << 8)
    }
    private func le32(_ d: Data, _ i: Data.Index) -> UInt32 {
        UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }
    private func le64(_ d: Data, _ o: Int) -> UInt64 {
        let i = d.startIndex.advanced(by: o)
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(d[i + k]) << (8 * k) }
        return v
    }

    // MARK: device status and management (all after the handshake)

    // getStorage (cmd 6): free, total, duration in the device's units.
    func getStorage() async throws -> StorageInfo {
        try send(Proto.command(Proto.CMD_GET_STORAGE))
        let b = try await waitCommand([Proto.CMD_GET_STORAGE], timeout: 10)
        guard b.count >= 19 else { throw BLEError.message("short storage reply") }
        let free = le64(b, 3), total = le64(b, 11)
        let dur: UInt64 = b.count >= 27 ? le64(b, 19) : 0
        return StorageInfo(free: free, total: total, durationSeconds: dur)
    }

    // getBattStatus (cmd 9): charging flag + level 0–100.
    func getBattery() async throws -> Battery {
        try send(Proto.command(Proto.CMD_GET_BATTERY))
        let b = try await waitCommand([Proto.CMD_GET_BATTERY], timeout: 10)
        return Battery(charging: b.count > 3 && b[b.startIndex + 3] == 1,
                       level: b.count > 4 ? Int(b[b.startIndex + 4]) : 0)
    }

    // getState (cmd 3): is it recording, and the current session id.
    func getRecordingState() async throws -> RecordingState {
        try send(Proto.command(Proto.CMD_GET_STATE))
        let b = try await waitCommand([Proto.CMD_GET_STATE], timeout: 10)
        let sid = b.count >= 7 ? le32(b, b.startIndex.advanced(by: 3)) : 0
        let recording = b.count > 7 && b[b.startIndex + 7] == 1
        return RecordingState(recording: recording, sessionId: sid)
    }

    // Delete one recording: send cmd 30 with the session id, wait for cmd 31 + status (0 = deleted).
    func deleteRecording(_ sessionId: UInt32) async throws {
        try send(Proto.command(Proto.CMD_DELETE_FILE, Proto.u32le(sessionId)))
        let b = try await waitCommand([Proto.CMD_DELETE_FILE_RSP], timeout: 15)
        // status is at byte 7 when the reply echoes the session id (protocol >= 7), else byte 3.
        let status = portVersion >= 7 ? (b.count > 7 ? Int(b[b.startIndex + 7]) : -1)
                                      : (b.count > 3 ? Int(b[b.startIndex + 3]) : -1)
        guard status == 0 else { throw BLEError.message("device refused delete, status=\(status)") }
    }

    // Stop an in-progress recording (cmd 145).
    func stopRecording() async throws {
        try send(Proto.command(Proto.CMD_STOP_RECORD))
        _ = try await waitCommand([Proto.CMD_STOP_RECORD_RSP], timeout: 10)
    }
}

struct StorageInfo { let free: UInt64; let total: UInt64; let durationSeconds: UInt64 }
struct Battery { let charging: Bool; let level: Int }
struct RecordingState { let recording: Bool; let sessionId: UInt32 }
