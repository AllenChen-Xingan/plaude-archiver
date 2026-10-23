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

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
