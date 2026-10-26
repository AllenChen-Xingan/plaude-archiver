import SwiftUI
@MainActor final class BluetoothLogin: ObservableObject {
    @Published var region = Store.load().accountRegion ?? (Store.load().apiHost == "https://api.plaud.cn" ? "cn" : "global")
    @Published var status = "首次登录仅用于获取蓝牙认证材料。"
    @Published var loginGeneration = 0
    @Published var isLoggingIn = false
    private var login: LoginWindow?
    private func claims(_ token: String?) -> [String:Any] {
        guard let token else { return [:] }
        let parts = token.split(separator:"."); guard parts.count > 1 else { return [:] }
        var part = String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        part += String(repeating:"=",count:(4-part.count%4)%4)
        guard let data = Data(base64Encoded:part), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] }
        return value
    }
    func signIn() {
        guard login == nil else { return }
        let chosen = region
        let window = LoginWindow(region:chosen) { [weak self] token in
            guard let self else { return }
            let old = Store.load()
            let sameAccount = self.claims(old.userToken)["sub"] as? String == self.claims(token)["sub"] as? String &&
                (old.accountRegion ?? (old.apiHost == "https://api.plaud.cn" ? "cn" : "global")) == chosen
            var store = sameAccount ? old : Store()
            if !sameAccount {
                let identity = Store.dir.appendingPathComponent("bluetooth-identity.json")
                if FileManager.default.fileExists(atPath:identity.path) {
                    let backup = Store.dir.appendingPathComponent("bluetooth-identity-previous-\(UUID().uuidString).json")
                    do { try FileManager.default.moveItem(at:identity,to:backup) }
                    catch { self.status = "无法切换本地设备认证，请检查存储权限。"; self.isLoggingIn = false; self.login = nil; return }
                }
            }
            store.userToken = token; store.accountRegion = chosen
            let hosts = ["aws:ap-southeast-1":"https://api-apse1.plaud.ai", "aws:us-east-1":"https://api-use1.plaud.ai", "aws:eu-central-1":"https://api-euc1.plaud.ai", "aws:us-west-2":"https://api-usw2.plaud.ai"]
            store.apiHost = chosen == "cn" ? "https://api.plaud.cn" : hosts[self.claims(token)["region"] as? String ?? ""] ?? "https://api.plaud.ai"
            store.save()
            self.status = "已登录，正在准备蓝牙认证。若账号有多台设备，请扫描选择后重新准备。"
            self.isLoggingIn = false; self.login = nil; self.loginGeneration += 1
        }
        window.onClose = { [weak self] in self?.login = nil; self?.isLoggingIn = false }
        isLoggingIn = true; login = window; window.show()
    }
}
