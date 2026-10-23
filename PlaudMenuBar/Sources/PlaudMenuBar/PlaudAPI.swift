import Foundation

enum APIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "api error" }
}

// Talks to the Plaud device endpoints with the UT token.
// Mirrors the app: X-Encrypt-Response: 1, Fernet-decrypt replies, follow the -302 region redirect.
struct PlaudAPI {
    var userToken: String
    var host: String

    private func decodeEnvelope(_ resp: HTTPURLResponse, _ body: Data) throws -> [String: Any] {
        var text = String(data: body, encoding: .utf8) ?? ""
        if resp.value(forHTTPHeaderField: "x-encrypt-response") == "1" {
            text = String(data: try Crypto.fernetDecrypt(text), encoding: .utf8) ?? ""
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw APIError.message("bad JSON from \(resp.url?.path ?? "?")")
        }
        return obj
    }

    // Returns the parsed envelope, following a one-shot region redirect and updating `host`.
    private func call(_ method: String, _ path: String, body: [String: Any]?) async throws
        -> (json: [String: Any], host: String)
    {
        var currentHost = host
        for _ in 0..<2 {
            var req = URLRequest(url: URL(string: currentHost + path)!)
            req.httpMethod = method
            req.setValue("Bearer " + userToken, forHTTPHeaderField: "Authorization")
            req.setValue("web", forHTTPHeaderField: "app-platform")
            req.setValue("web", forHTTPHeaderField: "edit-from")
            req.setValue("1", forHTTPHeaderField: "X-Encrypt-Response")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.message("no HTTP response") }
            let json = try decodeEnvelope(http, data)
            let status = (json["status"] as? Int) ?? (json["code"] as? Int)
            if status == -302, let domains = (json["data"] as? [String: Any])?["domains"] as? [String: Any],
               let api = domains["api"] as? String {
                currentHost = api
                continue
            }
            return (json, currentHost)
        }
        throw APIError.message("region redirect loop")
    }

    // POST /device-app/device/sn-sign -> base64 signature for the serial.
    func snSign(serial: String) async throws -> (sig: String, host: String) {
        let (json, h) = try await call("POST", "/device-app/device/sn-sign", body: ["sns": [serial]])
        guard ((json["status"] as? Int) ?? -1) == 0,
              let sig = ((json["data"] as? [String: Any])?["signature"] as? [String: Any])?[serial] as? String
        else { throw APIError.message("sn-sign: \(json["msg"] ?? json)") }
        return (sig, h)
    }

    // POST /device-app/e2ee/gen_key -> (privatePEM, publicPEM).
    func genKey() async throws -> (priv: String, pub: String, host: String) {
        let (json, h) = try await call("POST", "/device-app/e2ee/gen_key", body: [:])
        guard ((json["status"] as? Int) ?? -1) == 0, let data = json["data"] as? [String: Any],
              let privB64 = data["private_key_base64"] as? String,
              let pubB64 = data["public_key_base64"] as? String,
              let priv = Data(base64Encoded: privB64).flatMap({ String(data: $0, encoding: .utf8) }),
              let pub = Data(base64Encoded: pubB64).flatMap({ String(data: $0, encoding: .utf8) })
        else { throw APIError.message("gen_key: \(json["msg"] ?? json)") }
        return (priv, pub, h)
    }

    // Region from the UT token's JWT `region` claim, e.g. aws:ap-southeast-1 -> api-apse1.plaud.ai.
    static func hostFromToken(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Crypto.base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let region = obj["region"] as? String else { return "https://api.plaud.ai" }
        let map = ["aws:ap-southeast-1": "apse1", "aws:us-east-1": "use1",
                   "aws:eu-central-1": "euc1", "aws:us-west-2": "usw2"]
        if let sub = map[region] { return "https://api-\(sub).plaud.ai" }
        return "https://api.plaud.ai"
    }

    // The `sub` claim is the user_id, which is also the BLE bind token.
    static func subject(of token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Crypto.base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return obj["sub"] as? String
    }
}
