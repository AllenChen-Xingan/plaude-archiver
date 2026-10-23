import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.signedIn {
                signedOut
            } else {
                TabView {
                    RecordingsTab(model: model).tabItem { Label("Recordings", systemImage: "waveform") }
                    DeviceTab(model: model).tabItem { Label("Device", systemImage: "externaldrive") }
                    SettingsTab(model: model).tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .padding(.top, 6)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.deviceName ?? "Plaud").font(.headline)
                Text(model.connected ? (model.serial ?? "connected") : "not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let b = model.battery {
                Label("\(b.level)%", systemImage: b.charging ? "battery.100.bolt" : "battery.75")
                    .font(.callout).foregroundStyle(b.level < 20 ? .red : .secondary)
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.busy)
                .help("Refresh")
        }
        .padding(12)
    }

    private var signedOut: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Sign in to Plaud to fetch your device keys.").foregroundStyle(.secondary)
            Button("Sign in to Plaud…") { model.signIn() }.controlSize(.large)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack {
            if model.busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

// MARK: Recordings

struct RecordingsTab: View {
    @ObservedObject var model: DeviceModel
    @State private var confirmDelete: Recording?

    var body: some View {
        VStack(spacing: 0) {
            StorageBar(storage: model.storage)
            HStack {
                Toggle("Delete from device after download", isOn: $model.deleteAfterDownload)
                    .toggleStyle(.checkbox).font(.callout)
                Spacer()
                Button("Download all") { model.downloadAll() }
                    .disabled(model.busy || !model.recordings.contains { $0.state == .onDevice })
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if model.recordings.isEmpty {
                emptyState
            } else {
                List(model.recordings) { rec in
                    RecordingRow(rec: rec, model: model, confirmDelete: $confirmDelete)
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog("Delete this recording from the device?",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { rec in
            Button("Delete from device", role: .destructive) { model.delete(rec.sessionId); confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { _ in Text("This removes it from the device. If it isn't downloaded, it's gone for good.") }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(model.connected ? "No recordings on the device." : "Hit refresh to connect and list recordings.")
                .foregroundStyle(.secondary)
            if !model.connected { Button("Connect & refresh") { model.refresh() }.disabled(model.busy) }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
}

struct RecordingRow: View {
    let rec: Recording
    @ObservedObject var model: DeviceModel
    @Binding var confirmDelete: Recording?

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(model.dateText(rec.sessionId)).font(.body)
                Text(rec.sizeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if rec.state == .deleted {
                Text("deleted").font(.caption).foregroundStyle(.secondary)
            } else {
                if rec.state == .downloaded, let url = rec.localURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Play")
                }
                Button { model.download(rec.sessionId) } label: {
                    Image(systemName: rec.state == .downloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                }.buttonStyle(.borderless).disabled(model.busy).help("Download")
                Button { confirmDelete = rec } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).disabled(model.busy).help("Delete from device")
            }
        }
        .padding(.vertical, 2)
    }

    private var statusDot: some View {
        Circle().fill(rec.state == .downloaded ? Color.green : rec.state == .deleted ? Color.secondary : Color.accentColor)
            .frame(width: 8, height: 8)
    }
}

struct StorageBar: View {
    let storage: StorageInfo?
    var body: some View {
        Group {
            if let s = storage, s.total > 0 {
                let used = Double(s.total - s.free) / Double(s.total)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Storage").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(bytes(s.free)) free of \(bytes(s.total))").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(max(used, 0), 1)).tint(used > 0.9 ? .red : .accentColor)
                }.padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }
    private func bytes(_ v: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }
}

// MARK: Device

struct DeviceTab: View {
    @ObservedObject var model: DeviceModel
    var body: some View {
        Form {
            Section("Status") {
                row("Name", model.deviceName ?? "—")
                row("Serial", model.serial ?? "—")
                row("Connection", model.connected ? "connected" : "not connected")
                if let b = model.battery { row("Battery", "\(b.level)%\(b.charging ? " (charging)" : "")") }
                if let s = model.storage, s.total > 0 {
                    row("Free space", ByteCountFormatter.string(fromByteCount: Int64(s.free), countStyle: .file))
                }
            }
            Section("Recording") {
                if let r = model.recordingState, r.recording {
                    HStack {
                        Label("Recording now", systemImage: "record.circle").foregroundStyle(.red)
                        Spacer()
                        Button("Stop", role: .destructive) { model.stopRecording() }.disabled(model.busy)
                    }
                } else {
                    Text("Not recording").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).textSelection(.enabled) }
    }
}

// MARK: Settings

struct SettingsTab: View {
    @ObservedObject var model: DeviceModel
    var body: some View {
        Form {
            Section("Downloads") {
                HStack {
                    Text("Save to"); Spacer()
                    Text(model.downloadDirName).foregroundStyle(.secondary)
                    Button("Change…") { chooseFolder() }
                }
                Toggle("Delete from device after download", isOn: $model.deleteAfterDownload)
            }
            Section("Account") {
                Button("Sign out", role: .destructive) { model.signOut() }
            }
            Section {
                Text("Fully loaded devices fill up fast. Turning on \u{201C}delete after download\u{201D} frees space as you go — each recording is only deleted after it has downloaded and decrypted cleanly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.setDownloadDir(url) }
    }
}
