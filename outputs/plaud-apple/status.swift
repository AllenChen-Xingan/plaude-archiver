import Foundation
import FoundationModels
let model = SystemLanguageModel.default
var info: [String: Any] = ["provider":"Apple Foundation Models"]
switch model.availability {
case .available: info["available"] = true
case .unavailable(let reason): info["available"] = false; info["reason"] = String(describing: reason)
}
info["languages"] = model.supportedLanguages.map { $0.minimalIdentifier }.sorted()
print(String(data:try JSONSerialization.data(withJSONObject:info,options:.sortedKeys),encoding:.utf8)!)
