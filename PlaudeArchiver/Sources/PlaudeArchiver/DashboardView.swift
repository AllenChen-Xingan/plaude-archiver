import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var model: DeviceModel
    @State private var tab: Int

    init(model: DeviceModel, initialTab: Int = 0) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.signedIn {
                signedOut
            } else {
                Picker("", selection: $tab) {
                    Text("Recordings").tag(0)
                    Text("Device").tag(1)
                    Text("Settings").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                Group {
                    switch tab {
                    case 0: RecordingsTab(model: model)
                    case 1: DeviceTab(model: model)
                    default: SettingsTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.deviceName ?? "Plaude Archiver").font(.headline)
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
            Text("Sign in to Plaude to fetch your device keys.").foregroundStyle(.secondary)
            Button("Sign in to Plaude…") { model.signIn() }.controlSize(.large)
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
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            StorageBar(storage: model.storage)
            HStack {
                if model.connected { RecordingControls(model: model) }
                Spacer()
                Button("Delete all…", role: .destructive) { confirmDeleteAll = true }
                    .disabled(model.busy || recording || !model.recordings.contains { $0.state != .deleted })
                if model.downloading {
                    Button("Cancel download") { model.cancelDownload() }
                } else {
                    Button("Download all") { model.downloadAll() }
                        .disabled(model.busy || recording || !model.recordings.contains { $0.state == .onDevice })
                }
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
        .confirmationDialog("Delete every recording from the device?", isPresented: $confirmDeleteAll) {
            Button("Delete all from device", role: .destructive) {
                model.deleteAll(confirmed: Set(model.recordings.map(\.sessionId)))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let left = model.recordings.filter { $0.state == .onDevice }.count
            Text((left == 0 ? "Every recording in this list is downloaded." : "\(left) recording(s) in this list are not downloaded. They will be gone for good.")
                 + " If the device holds a recording that is not in this list, nothing is deleted.")
        }
    }

    // While the device records it refuses transfers, and Delete all would hit the live file.
    private var recording: Bool { model.recordingState?.recording == true }

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
                    // Reveal in Finder rather than open: .ogg/Opus needs a capable player
                    // (e.g. VLC), and launching a missing/Intel-only handler just errors.
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }.buttonStyle(.borderless).help("Show in Finder")
                }
                Button { model.download(rec.sessionId) } label: {
                    Image(systemName: rec.state == .downloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                }.buttonStyle(.borderless).disabled(model.busy || model.recordingState?.recording == true).help("Download")
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

// Record / pause / stop, with the live time from device events.
struct RecordingControls: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        HStack(spacing: 8) {
            if model.recordingState?.recording == true {
                Circle().fill(model.recordingPaused ? Color.orange : Color.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(model.recordingPaused ? "Paused" : elapsed(at: ctx.date)).font(.callout.monospacedDigit())
                }
                Button { model.togglePause() } label: {
                    Image(systemName: model.recordingPaused ? "play.fill" : "pause.fill")
                }.help(model.recordingPaused ? "Resume" : "Pause")
                Button { model.stopRecording() } label: { Image(systemName: "stop.fill") }.help("Stop recording")
            } else {
                Button { model.startRecording() } label: { Label("Record", systemImage: "record.circle") }
                    .help("Start a recording on the device")
            }
        }
        .disabled(model.busy)
    }

    // The device's own duration when it sends one, else the local clock for a recording started
    // here. A recording started on the device itself shows no time.
    private func elapsed(at now: Date) -> String {
        let seconds: Int
        if let ms = model.recordingMillis { seconds = Int(ms / 1000) }
        else if let clock = model.recordingClock { seconds = Int(clock.elapsed(at: now)) }
        else { return "Recording" }
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct StorageBar: View {
    let storage: StorageInfo?
    var body: some View {
        Group {
            if let s = storage, s.total > 0 {
                let used = Double(s.total - min(s.free, s.total)) / Double(s.total)   // guard free > total
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
    @State private var newName = ""

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
                if let r = model.recordingState { row("State", stateText(r)) }
                if let f = model.firmwareUpdate {
                    row("Firmware update", f.toVersion == 0 ? "none pending" : "\(f.toVersionType)\(f.toVersion) pending")
                }
            }
            if model.connected {
                Section("Device") {
                    HStack {
                        TextField("Name", text: $newName, prompt: Text(model.deviceName ?? "Device name"))
                        Button("Rename") { model.rename(newName.trimmingCharacters(in: .whitespaces)); newName = "" }
                            .disabled(model.busy || newName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || newName.utf8.count > 32)
                    }
                }
                Section {
                    if model.settingsLoaded {
                        ForEach(DeviceSetting.all.filter { model.settingValues[$0.id] != nil }) { def in
                            SettingRow(def: def, model: model)
                        }
                    } else {
                        Button("Read device settings") { model.loadDeviceInfo() }.disabled(model.busy)
                    }
                } header: {
                    Text("Device settings")
                } footer: {
                    if model.settingsLoaded {
                        Text("Read from the device. Some settings are shown only: their allowed values are not known, or the device does not accept changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .onAppear { if model.connected && !model.settingsLoaded && !model.busy { model.loadDeviceInfo() } }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).textSelection(.enabled) }
    }

    private func stateText(_ r: RecordingState) -> String {
        switch r.state {
        case .idle: return "idle"
        case .recording: return model.recordingPaused ? "recording (paused)" : "recording"
        case .transfer: return "transferring"
        case .switchingOn: return "switching on"
        case .switchingOff: return "switching off"
        }
    }
}

struct SettingRow: View {
    let def: DeviceSetting
    @ObservedObject var model: DeviceModel

    var body: some View {
        let value = model.settingValues[def.id] ?? 0
        Group {
            switch def.kind {
            case .toggle:
                Toggle(def.label, isOn: Binding(get: { value != 0 }, set: { model.setSetting(def, $0 ? 1 : 0) }))
            case .choice(let options):
                Picker(def.label, selection: Binding(get: { value }, set: { model.setSetting(def, $0) })) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                    if !options.contains(where: { $0.0 == value }) { Text("\(value)").tag(value) }
                }
            case .readOnly:
                HStack {
                    Text(def.label); Spacer()
                    Text("\(value)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .disabled(model.busy)
        .help(def.help ?? "")
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
        .formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.setDownloadDir(url) }
    }
}
