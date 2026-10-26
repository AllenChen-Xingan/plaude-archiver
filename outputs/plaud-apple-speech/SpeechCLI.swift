import Foundation
import Speech
import AVFoundation
import CoreMedia

struct TimedWord: Codable, Sendable { let word: String; let startTime: Double; let endTime: Double }
struct TextSegment: Codable, Sendable { let text: String; let start: Double; let end: Double }
struct Transcript: Codable, Sendable {
    let text: String
    let wordTimings: [TimedWord]
    let durationSeconds: Double
    let audioFile: String
    let engine: String
    let wordTimestampMethod: String
    let segments: [TextSegment]
    let untimedTextRuns: Int
}
struct Failure: Error { let message: String }
func output(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
func statusName(_ status: AssetInventory.Status) -> String {
    switch status { case .unsupported: "unsupported"; case .supported: "supported"; case .downloading: "downloading"; case .installed: "installed"; @unknown default: "unknown" }
}
@main struct SpeechCLI {
    static func main() async {
        do { try await run() }
        catch { try? output(["ok": false, "error": String(describing: error)]); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ key: String) -> String? { guard let i=args.firstIndex(of:key), i+1<args.count else{return nil}; return args[i+1] }
        if args.contains("--help") || args.isEmpty {
            print("apple-speech --status [--locale en-US]\napple-speech --install-assets [--locale en-US]\napple-speech --transcribe INPUT.wav --output RESULT.json [--locale en-US]")
            return
        }
        let requested = value("--locale") ?? "en-US"
        let available=SpeechTranscriber.isAvailable
        guard available else { try output(["ok":false,"available":false,"assetStatus":"unsupported","locale":requested,"reason":"SpeechTranscriber unavailable on this device"]); exit(3) }
        guard let locale=await SpeechTranscriber.supportedLocale(equivalentTo:Locale(identifier:requested)) else { try output(["ok":false,"available":true,"assetStatus":"unsupported","locale":requested,"reason":"Unsupported speech locale"]);exit(3) }
        let transcriber=SpeechTranscriber(locale:locale, transcriptionOptions:[], reportingOptions:[], attributeOptions:[.audioTimeRange])
        let status=await AssetInventory.status(forModules:[transcriber])
        if args.contains("--status") {
            let installed=await SpeechTranscriber.installedLocales
            try output(["ok":true,"available":available,"locale":locale.identifier,"assetStatus":statusName(status),"installedLocales":installed.map(\.identifier),"downloadStarted":false,"modelProvider":"Apple system SpeechTranscriber"])
            return
        }
        if args.contains("--install-assets") {
            if let request=try await AssetInventory.assetInstallationRequest(supporting:[transcriber]) {
                FileHandle.standardError.write(Data("Preparing Apple-managed speech assets...\n".utf8))
                try await request.downloadAndInstall()
            }
            let after=await AssetInventory.status(forModules:[transcriber])
            try output(["ok":after == .installed,"available":true,"locale":locale.identifier,"assetStatus":statusName(after)])
            if after != .installed { exit(4) }; return
        }
        guard let input=value("--transcribe"),let destination=value("--output") else {throw Failure(message:"Expected --transcribe INPUT.wav --output RESULT.json")}
        guard status == .installed else { try output(["ok":false,"available":true,"locale":locale.identifier,"assetStatus":statusName(status),"reason":"Speech assets not installed. Run --install-assets explicitly before transcription.","downloadStarted":false]);exit(4) }
        guard !FileManager.default.fileExists(atPath:destination) else {throw Failure(message:"Output exists; choose a new path")}
        let file=try AVAudioFile(forReading:URL(fileURLWithPath:input))
        let duration=Double(file.length)/file.processingFormat.sampleRate
        guard duration.isFinite && duration>0 else {throw Failure(message:"Invalid audio duration")}
        let consume=Task { () throws -> (String,[TimedWord],[TextSegment],Int) in
            var pieces:[String]=[];var words:[TimedWord]=[];var segments:[TextSegment]=[];var untimed=0
            for try await result in transcriber.results {
                guard result.isFinal else {continue}
                let text=String(result.text.characters)
                pieces.append(text)
                segments.append(TextSegment(text:text,start:result.range.start.seconds,end:CMTimeRangeGetEnd(result.range).seconds))
                for (range,indices) in result.text.runs[\.audioTimeRange] {
                    let part=String(result.text[indices].characters).trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !part.isEmpty else {continue}
                    guard let range else {untimed += 1;continue}
                    let start=range.start.seconds;let end=CMTimeRangeGetEnd(range).seconds
                    guard start.isFinite,end.isFinite,start>=0,end>=start,end<=duration+0.15 else {throw Failure(message:"Invalid Apple speech time range")}
                    if let previous=words.last, start<previous.startTime {throw Failure(message:"Non-monotonic Apple speech time ranges")}
                    words.append(TimedWord(word:part,startTime:min(start,duration),endTime:min(end,duration)))
                }
            }
            return (pieces.joined(separator:" "),words,segments,untimed)
        }
        let analyzer=SpeechAnalyzer(modules:[transcriber])
        do {
            if let last=try await analyzer.analyzeSequence(from:file) { try await analyzer.finalizeAndFinish(through:last) }
            else { await analyzer.cancelAndFinishNow() }
            let (text,words,segments,untimed)=try await consume.value
            guard !words.isEmpty,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw Failure(message:"No final timed transcription")}
            guard untimed==0 else {throw Failure(message:"Apple returned untimed text; refusing synthetic word timestamps")}
            let result=Transcript(text:text,wordTimings:words,durationSeconds:duration,audioFile:input,engine:"apple-speech",wordTimestampMethod:"Apple SpeechTranscriber AttributedString audioTimeRange runs; no synthetic timing",segments:segments,untimedTextRuns:untimed)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(result).write(to:URL(fileURLWithPath:destination),options:[.withoutOverwriting])
            try output(["ok":true,"engine":"apple-speech","durationSeconds":duration,"timedRuns":words.count,"assetStatus":"installed"])
        } catch { consume.cancel();await analyzer.cancelAndFinishNow();throw error }
    }
}
