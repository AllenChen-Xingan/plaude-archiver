import Foundation

// Persisted state in ~/Library/Application Support/PlaudMenuBar/.
// The RSA private key is the one secret worth protecting; the directory is created 0700.
struct Store: Codable {
    var userToken: String?        // UT token (pld_ut cookie), used for sn-sign / gen_key
    var apiHost: String = "https://api.plaud.ai"
    var devicePrivatePEM: String? // RSA private key from gen_key (PKCS#8 PEM)
    var devicePublicPEM: String?
    var snSignatures: [String: String] = [:]   // serial -> base64 signature
    var downloadDir: String?      // where recordings are saved

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PlaudMenuBar", isDirectory: true)
    }
    private static var file: URL { dir.appendingPathComponent("state.json") }

    static func load() -> Store {
        ensureDir()
        guard let data = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
        return s
    }

    func save() {
        Store.ensureDir()
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Store.file, options: .completeFileProtection)
        }
    }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    // Append a timestamped line to log.txt for diagnosis.
    static func log(_ s: String) {
        ensureDir()
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + s + "\n"
        let url = dir.appendingPathComponent("log.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    var defaultDownloadDir: URL {
        if let d = downloadDir { return URL(fileURLWithPath: d) }
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return dl.appendingPathComponent("Plaud Recordings", isDirectory: true)
    }

    var haveKeys: Bool { devicePrivatePEM != nil && !snSignatures.isEmpty }
}
