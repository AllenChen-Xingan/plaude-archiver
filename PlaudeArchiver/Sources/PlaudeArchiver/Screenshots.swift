import AppKit
import SwiftUI

// Hidden: render the dashboard with sample data to PNGs for the README.
// Needs no device and no account. Run from the built bundle so the app icon loads:
//   "./Plaude Archiver.app/Contents/MacOS/PlaudeArchiver" --screenshots ../assets/screenshots
@MainActor
enum Screenshots {
    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let model = sampleModel()
        let shots: [(name: String, tab: Int, dark: Bool)] = [
            ("recordings", 0, false), ("recordings-dark", 0, true),
            ("device", 1, false), ("settings", 2, false),
        ]
        for shot in shots {
            let host = NSHostingController(rootView: DashboardView(model: model, initialTab: shot.tab))
            let w = NSWindow(contentViewController: host)
            w.title = "Plaude Archiver"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
            w.setContentSize(NSSize(width: 580, height: 500))
            w.center()
            app.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))   // let SwiftUI lay out the list

            let png = framed(capture(w))
            let path = (outDir as NSString).appendingPathComponent("\(shot.name).png")
            do { try png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)") }
            catch { FileHandle.standardError.write(Data("write failed: \(error)\n".utf8)); exit(1) }
            w.orderOut(nil)
        }
        exit(0)
    }

    // Sample data only: no real serials, recordings or accounts.
    private static func sampleModel() -> DeviceModel {
        let m = DeviceModel()
        m.signedIn = true
        m.connected = true
        m.deviceName = "Plaud Note Pro"
        m.serial = "SN 0000-DEMO"
        m.battery = Battery(charging: false, level: 82)
        m.storage = StorageInfo(free: 41_300_000_000, total: 64_000_000_000, durationSeconds: 0)
        m.recordingState = RecordingState(state: .idle, sessionId: 0, rawCode: 0, rawKey: 0)
        m.settingsLoaded = true
        m.settingValues = [25: 0, 26: 1, 24: 0, 15: 0, 49: 1, 23: 3, 32: 0, 20: 0, 19: 0, 18: 0, 27: 2, 4: 1]
        // (day, hour, minute) in October 2026, size in bytes, state
        let sample: [(Int, Int, Int, Int, Recording.State)] = [
            (24, 10, 5, 18_400_000, .onDevice), (23, 16, 40, 42_100_000, .onDevice),
            (23, 9, 12, 6_300_000, .downloaded), (22, 14, 30, 27_800_000, .downloaded),
            (21, 11, 0, 12_900_000, .downloaded), (20, 18, 25, 3_100_000, .deleted),
        ]
        m.recordings = sample.map { day, hour, minute, size, state in
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day,
                                                                  hour: hour, minute: minute))!
            return Recording(sessionId: UInt32(date.timeIntervalSince1970), sizeBytes: size, state: state,
                             localURL: state == .downloaded ? URL(fileURLWithPath: "/tmp/sample.ogg") : nil)
        }
        m.status = "Connected. 6 recordings, 3 downloaded."
        return m
    }

    // The window frame view holds the title bar and the content, so one capture gets both.
    private static func capture(_ w: NSWindow) -> NSBitmapImageRep {
        let view = w.contentView!.superview!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // Rounds the corners and adds a soft shadow on a transparent canvas, like a macOS window.
    private static func framed(_ rep: NSBitmapImageRep) -> Data {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let pad: CGFloat = 40, radius: CGFloat = 12
        let size = NSSize(width: rep.size.width + pad * 2, height: rep.size.height + pad * 2)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = NSRect(x: pad, y: pad, width: rep.size.width, height: rep.size.height)
        let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()

        clip.addClip()
        rep.draw(in: rect)
        NSColor.black.withAlphaComponent(0.15).setStroke()
        clip.lineWidth = 1 / scale
        clip.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])!
    }
}
