import SwiftUI
import AppKit
import Security

struct LibraryRecording: Identifiable {
    let id: String
    let title: String
    let state: String
    let folder: URL
    let transcript: String
    let notes: String
}

@MainActor final class LibraryModel: ObservableObject {
    @Published var recordings: [LibraryRecording] = []
    @Published var selected: String?
    @Published var status = "选择录音，或导入本地音频。"
    @Published var busy = false
    @Published var engine = "qwen-asr" { didSet { UserDefaults.standard.set(engine,forKey:"PreferredASREngine") } }
    @Published var apiKey = ""
    @Published var keyProvider = "groq"
    @Published var terminology = ""
    @Published var bluetoothSerial = ""
    @Published var bluetoothDevices: [String] = []
    @Published var summaryProvider = "local" { didSet { UserDefaults.standard.set(summaryProvider,forKey:"SummaryProvider") } }
    @Published var summaryPrompt = "" { didSet { UserDefaults.standard.set(summaryPrompt,forKey:"SummaryPrompt") } }
    @Published var autoTitle = true
    @Published var library: URL
    @Published var runtime: URL?
    private var process: Process?
    private var activeJob: URL?
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        library = URL(fileURLWithPath: defaults.string(forKey: "LibraryFolder") ??
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PlaudeArchiverCN/Library").path)
        if let path = defaults.string(forKey: "RuntimeFolder") { runtime = URL(fileURLWithPath: path) }
        else if let file = Bundle.main.url(forResource: "RuntimeRoot", withExtension: "txt"),
                let path = try? String(contentsOf: file, encoding: .utf8) {
            runtime = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        engine = defaults.string(forKey:"PreferredASREngine") ?? "qwen-asr"
        summaryProvider = defaults.string(forKey:"SummaryProvider") ?? "local"
        if !["apple-speech","qwen-asr","whisper-large","parakeet","whisper","groq"].contains(engine) { engine = "qwen-asr" }
        if !["apple","local","groq","deepseek"].contains(summaryProvider) { summaryProvider = "local" }
        reload()
        summaryPrompt = defaults.string(forKey:"SummaryPrompt") ?? runtime.flatMap {
            try? String(contentsOf:$0.appendingPathComponent("outputs/plaud-app/default-summary-prompt.txt"),encoding:.utf8)
        } ?? "根据录音生成简洁名称和摘要，仅提取明确的决定与待办，不要编造事实。"
        if let path = defaults.string(forKey:"ActiveLibraryJob") { activeJob = URL(fileURLWithPath:path) }
        pollJob()
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.pollJob() }
        }
    }
    deinit { timer?.invalidate() }
    func pollJob() {
        if let data = try? Data(contentsOf:library.appendingPathComponent("bluetooth-devices.json")),
           let devices = (try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] {
            bluetoothDevices = devices.compactMap { $0["serial"] as? String }
        }
        if activeJob == nil { reload(); return }
        guard let job = activeJob,
              let data = try? Data(contentsOf:job),
              let info = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let state = info["state"] as? String else { return }
        if state == "queued" || state == "running" {
            busy = true
            let log = job.deletingLastPathComponent().appendingPathComponent("events.jsonl")
            if let line = (try? String(contentsOf:log,encoding:.utf8))?.split(separator:"\n").last,
               let event = (try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any],
               let message = event["status"] as? String { status = message + "（可关闭窗口，后台继续）" }
            return
        }
        busy = false
        if let id = info["recording_id"] as? String { selected = id }
        status = state == "complete" ? "后台任务完成，结果已保存到录音库。" : (info["error"] as? String ?? "后台任务已停止。")
        activeJob = nil; UserDefaults.standard.removeObject(forKey:"ActiveLibraryJob"); reload()
    }
    var current: LibraryRecording? { recordings.first { $0.id == selected } }
    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        recordings = dirs.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("recording.json")),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = object["id"] as? String, id == folder.lastPathComponent else { return nil }
            func read(_ key: String) -> String {
                guard let name = object[key] as? String, !name.contains("/"), !name.contains("..") else { return "" }
                return (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            return LibraryRecording(id: id, title: object["title"] as? String ?? "录音",
                state: object["state"] as? String ?? "", folder: folder, transcript: read("transcript"), notes: read("notes"))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func chooseLibrary() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.prompt = "使用此文件夹"; p.message = "录音、转写、摘要和待办都将存入此文件夹。切换不会移动或删除旧录音库。"
        if p.runModal() == .OK, let url = p.url {
            library = url; UserDefaults.standard.set(url.path, forKey: "LibraryFolder"); selected = nil; reload()
        }
    }
    func chooseRuntime() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "选择包含 outputs 和 work 的本地引擎文件夹。"
        if p.runModal() == .OK, let url = p.url {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("outputs/plaud-app/job.py").path) else {
                status = "该文件夹不含所需引擎。"; return
            }
            runtime = url; UserDefaults.standard.set(url.path, forKey: "RuntimeFolder")
        }
    }
    func importFile() {
        let p = NSOpenPanel(); p.allowedFileTypes = ["ogg","wav","mp3","m4a","flac","mp4","aac","webm"]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { job(["action":"import", "source":url.path]) }
    }
    func saveKey() {
        let value = apiKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.count >= 20, value.hasPrefix(keyProvider == "deepseek" ? "sk-" : "gsk_") else { status = "请核对 API Key 格式。"; return }
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:(keyProvider == "deepseek" ? "PlaudeArchiverCN.DeepSeek" : "PlaudeArchiverCN.Groq"), kSecAttrAccount as String:"api-key"]
        let data = Data(value.utf8)
        var code = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if code == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            code = SecItemAdd(insert as CFDictionary,nil)
        }
        if code == errSecSuccess { apiKey = ""; status = "API Key 已存入钥匙串。" }
        else { status = "钥匙串保存失败。" }
    }
    func confirmUpload(_ text: String) -> Bool {
        let alert = NSAlert(); alert.messageText = text
        alert.informativeText = "使用你自己的 API Key，可能消耗额度或产生费用。"
        alert.addButton(withTitle:"发送并处理"); alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func transcribe() {
        guard let selected else { return }
        var request: [String:Any] = ["action":"transcribe","id":selected,"engine":engine,"prompt":terminology]
        if engine == "groq" {
            guard confirmUpload("将所选录音上传到 Groq 转写？") else { return }
            request["allow_upload"] = true
        }
        job(request)
    }
    func summarize() {
        guard let selected else { return }
        UserDefaults.standard.set(summaryPrompt,forKey:"SummaryPrompt")
        var request: [String:Any] = ["action":"summarize","id":selected,"summary_provider":summaryProvider,
                                     "summary_prompt":summaryPrompt,"rename":autoTitle]
        if ["groq","deepseek"].contains(summaryProvider) {
            guard confirmUpload("将转写文本发送至 \(summaryProvider) 生成摘要？") else { return }
            request["allow_text_upload"] = true
        }
        job(request)
    }
    func renameCurrent() {
        guard let item = current else { return }
        let alert = NSAlert(); alert.messageText = "修改录音名称"
        alert.informativeText = "名称会保存在录音库元数据和“录音名称.txt”中，原始音频内容保持不变。"
        let field = NSTextField(string:item.title); field.frame = NSRect(x:0,y:0,width:380,height:28)
        field.setAccessibilityLabel("录音名称"); alert.accessoryView = field
        alert.addButton(withTitle:"保存名称"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn { job(["action":"rename","id":item.id,"title":field.stringValue]) }
    }
    func job(_ values: [String:Any]) {
        guard !busy else { return }
        guard let runtime else { status = "请在模型管理中选择引擎文件夹。"; return }
        let python = runtime.appendingPathComponent("work/plaud-research/venv/bin/python")
        let script = runtime.appendingPathComponent("outputs/plaud")
        guard FileManager.default.isExecutableFile(atPath:python.path), FileManager.default.fileExists(atPath:script.path) else {
            status = "本地引擎未安装完整，请选择正确引擎文件夹。"; return
        }
        var request = values; request["library"] = library.path; request["background"] = true
        guard let inputData = try? JSONSerialization.data(withJSONObject:request) else { return }
        busy = true; status = "正在处理…"
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = python; p.arguments = [script.path,"--json-request"]; p.currentDirectoryURL = runtime
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        process = p
        do { try p.run() } catch { busy = false; status = "无法启动本地引擎。"; process = nil; return }
        input.fileHandleForWriting.write(inputData); try? input.fileHandleForWriting.close()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var pending = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }; pending.append(chunk)
                while let end = pending.firstIndex(of:10) {
                    let line = pending.prefix(upTo:end); pending.removeSubrange(...end)
                    if let event = (try? JSONSerialization.jsonObject(with:line)) as? [String:Any] {
                        Task { @MainActor [weak self] in
                            if let status = event["status"] as? String { self?.status = status }
                            if let error = event["error"] as? String { self?.status = error }
                            if let id = event["id"] as? String { self?.selected = id }
                            if let path = event["status_file"] as? String {
                                self?.activeJob = URL(fileURLWithPath:path)
                                UserDefaults.standard.set(path,forKey:"ActiveLibraryJob")
                                self?.status = "任务已进入后台，关闭窗口后仍会继续。"
                                self?.pollJob()
                            }
                        }
                    }
                }
            }
            p.waitUntilExit()
            Task { @MainActor [weak self] in
                self?.busy = self?.activeJob != nil; self?.process = nil; self?.reload(); self?.pollJob()
                if p.terminationStatus != 0, self?.status == "正在处理…" { self?.status = "处理失败，已有录音和结果保留。" }
            }
        }
    }
    func installed(_ path: String) -> String {
        guard let runtime else { return "未配置" }
        return FileManager.default.fileExists(atPath:runtime.appendingPathComponent(path).path) ? "已安装" : "未安装"
    }
    func cancel() {
        if let activeJob, let runtime {
            let p = Process(); p.executableURL = runtime.appendingPathComponent("work/plaud-research/venv/bin/python")
            p.arguments = [runtime.appendingPathComponent("outputs/plaud").path,"cancel",activeJob.deletingLastPathComponent().lastPathComponent,"--library",library.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
        } else { process?.terminate() }
        status = "已请求停止，正在清理；原录音和已有结果保留。"
    }
}

struct LibraryView: View {
    @StateObject private var bluetoothLogin = BluetoothLogin()
    @StateObject private var model = LibraryModel()
    @State private var section = FileManager.default.fileExists(atPath:Store.dir.appendingPathComponent("bluetooth-identity.json").path) ? 0 : 1
    @State private var showNotes = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("录音库页面",selection:$section) {
                Text("录音库").tag(0); Text("首次设置与模型").tag(1)
            }.pickerStyle(.segmented)
            if section == 0 { library } else { models }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small); Button("停止处理",action:model.cancel) }
                Text(model.status).font(.callout).textSelection(.enabled)
            }
        }.padding(14).frame(minWidth:760,minHeight:560)
        .onChange(of:bluetoothLogin.loginGeneration) { _ in
            model.bluetoothSerial = ""
            model.job(["action":"prepare-bluetooth"])
        }
    }
    private var library: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Button("选择录音库文件夹…",action:model.chooseLibrary).accessibilityLabel("选择录音库文件夹")
                Button("在 Finder 中打开") { NSWorkspace.shared.open(model.library) }.accessibilityLabel("在 Finder 中打开录音库")
                Spacer()
                Button("导入音频…",action:model.importFile).accessibilityLabel("导入本地音频")
                Button("扫描蓝牙") { model.job(["action":"scan"]) }.accessibilityLabel("扫描附近的 Note Pro")
                Picker("蓝牙设备",selection:$model.bluetoothSerial) {
                    Text("自动匹配已认证设备").tag("")
                    ForEach(model.bluetoothDevices,id:\.self) { Text($0).tag($0) }
                }
                Button("验证连接") { model.job(["action":"connect","serial":model.bluetoothSerial]) }
                Button("蓝牙导入一条") { model.job(["action":"download","serial":model.bluetoothSerial]) }.accessibilityLabel("通过蓝牙导入一条录音")
            }.disabled(model.busy)
            Text(model.library.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HSplitView {
                List(model.recordings,selection:$model.selected) { item in
                    VStack(alignment:.leading) { Text(item.title); Text(item.state).font(.caption).foregroundStyle(.secondary) }.tag(item.id)
                }.frame(minWidth:180,idealWidth:230)
                VStack(alignment:.leading,spacing:10) {
                    if let item = model.current {
                        HStack {
                            Text(item.title).font(.headline)
                            Button("重命名…",action:model.renameCurrent).disabled(model.busy).accessibilityLabel("修改录音名称")
                        }
                        Picker("识别模型",selection:$model.engine) {
                            Text("Apple Speech · 系统语音模型").tag("apple-speech")
                            Text("Qwen3-ASR 1.7B · 本地语音识别").tag("qwen-asr")
                            Text("Whisper large-v3 · 本地大模型").tag("whisper-large")
                            Text("Phonon-2 · 本地快速").tag("parakeet")
                            Text("Whisper base · 本地轻量").tag("whisper")
                            Text("Groq Whisper large-v3 · 云端").tag("groq")
                        }
                        TextField("术语提示：人名、公司名、专业词（Qwen / Whisper）",text:$model.terminology)
                            .disabled(model.engine == "parakeet" || model.engine == "apple-speech")
                        HStack {
                            Button("转写并标注说话人",action:model.transcribe).accessibilityLabel("开始转写并标注说话人")
                            Button("生成名称、摘要和待办",action:model.summarize)
                                .disabled(item.transcript.isEmpty)
                                .accessibilityLabel("生成名称、摘要和待办")
                            Button("查看文件") { NSWorkspace.shared.open(item.folder) }.accessibilityLabel("查看当前录音的全部文件")
                        }.disabled(model.busy)
                        Picker("结果",selection:$showNotes) { Text("原始转写").tag(false); Text("AI 摘要和待办").tag(true) }.pickerStyle(.segmented)
                        ScrollView {
                            Text(showNotes ? (item.notes.isEmpty ? "尚未生成摘要。" : item.notes) : (item.transcript.isEmpty ? "尚未转写。" : item.transcript))
                                .frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(8)
                        }
                    } else {
                        Text("导入一段录音，或从左侧选择。录音和所有结果均保存在所选录音库。").foregroundStyle(.secondary)
                        Spacer()
                    }
                }.padding(8).frame(minWidth:440)
            }
        }
    }
    private var models: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:14) {
            Text("首次登录只获取设备认证，不读取 Plaud 云端录音。之后通过蓝牙下载；认证失效时可重新准备。")
            Text("1. 选择账号区域并登录").font(.headline)
            Picker("Plaud 账号区域",selection:$bluetoothLogin.region) {
                Text("中国区 · plaud.cn").tag("cn")
                Text("国际区 · plaud.ai").tag("global")
            }.disabled(bluetoothLogin.isLoggingIn || model.busy)
            Text(bluetoothLogin.status)
            HStack {
                Button("登录并准备蓝牙认证",action:bluetoothLogin.signIn).disabled(bluetoothLogin.isLoggingIn || model.busy)
                Button("准备蓝牙密钥") { model.job(["action":"prepare-bluetooth","serial":model.bluetoothSerial]) }.disabled(model.busy)
            }
            Text("2. 选择录音库，再到录音库页面扫描并验证设备。首次使用请让手机暂时断开设备蓝牙。")
            Button("选择录音库文件夹…",action:model.chooseLibrary).disabled(model.busy)
            Text("3. 本地模型").font(.headline)
            Text("Apple Speech：首次选用会检测并下载缺失语言资产。Apple Intelligence 摘要由系统设置管理。")
            Button("准备苹果语音模型") { model.job(["action":"install","model":"apple-speech"]) }
                .disabled(model.busy).accessibilityLabel("检查并准备苹果语音模型")
            Text("Qwen3-ASR 1.7B 与 ForcedAligner：\(model.installed("outputs/plaud-qwen-asr/install-verification.json"))")
            Text("Whisper large-v3（约 3.1 GB）：\(model.installed("work/plaud-research/models/ggml-large-v3.bin"))")
            Text("Phonon-2：\(model.installed("work/plaud-english/models/phonon-2/Encoder.mlmodelc"))")
            Text("说话人标注 VBx：\(model.installed("work/plaud-diarization/models"))")
            Text("Qwen3-4B 本地摘要：\(model.installed("work/plaud-summary/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"))")
            HStack {
                Button("安装 / 校验 Qwen3-ASR") { model.job(["action":"install","model":"qwen-asr"]) }.accessibilityLabel("安装或校验 Qwen3 语音识别模型")
                Button("安装 / 校验 large-v3（3.1 GB）") { model.job(["action":"install","model":"large"]) }.accessibilityLabel("安装或校验 Whisper large-v3")
                Button("安装快速识别和分人") { model.job(["action":"install","model":"fast"]) }.accessibilityLabel("安装快速识别和说话人模型")
                Button("安装 / 校验摘要（2.5 GB）") { model.job(["action":"install","model":"summary"]) }.accessibilityLabel("安装或校验本地摘要模型")
            }.disabled(model.busy)
            Button("选择引擎文件夹…",action:model.chooseRuntime).disabled(model.busy).accessibilityLabel("选择引擎文件夹")
            Text("模型与录音库分开保存，切换录音库无需重复下载模型。模型越大不保证每段录音都更准确；术语提示不会保证正确拼写。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("摘要与录音名称").font(.headline)
            Picker("摘要模型",selection:$model.summaryProvider) {
                Text("Apple Intelligence · 系统自带").tag("apple")
                Text("Qwen3-4B · 本地").tag("local")
                Text("Groq Qwen · 云端摘要").tag("groq")
                Text("DeepSeek · 云端摘要").tag("deepseek")
            }
            Toggle("生成摘要时使用 AI 建议名称",isOn:$model.autoTitle)
            Button("打开 Apple Intelligence 系统设置") { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/System Settings.app")) }
                .accessibilityLabel("打开系统设置以启用 Apple Intelligence")
            Text("可选云端模型 API Key").font(.headline)
            Picker("API 服务商",selection:$model.keyProvider) {
                Text("Groq").tag("groq"); Text("DeepSeek").tag("deepseek")
            }
            SecureField("API Key",text:$model.apiKey)
            Button("保存到钥匙串",action:model.saveKey).disabled(model.apiKey.isEmpty)
                .accessibilityLabel("将所选云端模型 API Key 保存到钥匙串")
            Text("摘要提示词（可修改；适用于会议、讲座、访谈和个人录音）")
            TextEditor(text:$model.summaryPrompt).frame(minHeight:100,maxHeight:150)
                .accessibilityLabel("摘要提示词")
            Spacer()
        }
        .frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
