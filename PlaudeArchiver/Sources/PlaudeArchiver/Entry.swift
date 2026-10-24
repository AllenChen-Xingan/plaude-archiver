import AppKit

@main
struct PlaudApp {
    @MainActor
    static func main() {
        // Hidden self-test: decrypt a downloaded .plaud file with an RSA PEM, write .ogg. For verification.
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--decrypt" {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                let key = try Crypto.importRSAPrivateKey(pem: try Data(contentsOf: URL(fileURLWithPath: args[3])))
                let out = try Crypto.decryptRecordingFile(data, privateKey: key)
                let dst = (args[2] as NSString).deletingPathExtension + ".swift.ogg"
                try out.write(to: URL(fileURLWithPath: dst))
                FileHandle.standardOutput.write(Data("decrypted \(out.count) bytes -> \(dst)\n".utf8))
                exit(0)
            } catch { FileHandle.standardError.write(Data("selftest error: \(error)\n".utf8)); exit(1) }
        }

        // Hidden read-only device probe: connect, read status, list recordings; never deletes.
        if args.contains("--probe-device") || args.contains("--selftest") {
            let full = args.contains("--selftest")
            let model = DeviceModel()
            Task {
                do {
                    let report = try await (full ? model.selfTest() : model.probe())
                    FileHandle.standardOutput.write(Data((report + "\n").utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("probe error: \(error)\n".utf8))
                    exit(1)
                }
            }
            // Spin the main run loop so CoreBluetooth (queue: nil = main) delivers callbacks.
            RunLoop.main.run()
            return
        }

        // Hidden README screenshots from sample data; never touches the device or the network.
        if args.count == 3, args[1] == "--screenshots" {
            Screenshots.run(outDir: args[2])
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
