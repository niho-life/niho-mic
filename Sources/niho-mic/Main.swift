import Foundation
import FoundationModels
import Speech
import AVFoundation
import Darwin
import NihoMicCore

@main
struct NihoMic {
    static let help = """
    にほちゃんマイク v1 — macOS 26+ / Apple Silicon / Mac 内処理のみ

    niho-mic inputs
    niho-mic doctor [--input <機器UID>]
    niho-mic install-speech-model
    niho-mic run --input <機器UID> [--segment-seconds <2〜300>]
    niho-mic once --audio <音声ファイル>
    niho-mic prune
    niho-mic delete-logs --confirm
    niho-mic help

    録音は運営者が目的を説明し、参加者の同意を得てから手動で開始してください。
    run は連続録音を最大300秒で区切ります。Ctrl-C で録音を止め、最後の区切りを処理します。
    指定機器の切断、既定入力や入力設定の変更を検出すると停止します。
    once は2〜300秒の録音が対象です。元ファイルは変更しません。
    保存先: ~/Library/Application Support/life.niho.mic (0700 / ファイル0600)
    音声72時間、文字起こし168時間。起動時と稼働中に期限切れを削除します。
    停止中は削除されないため、再起動時または prune で削除してください。
    短文ログは保存先の logs/YYYY-MM-DD.jsonl です。標準出力には本文を表示しません。
    モデルの取得は install-speech-model の明示操作のみ。Mac 内 AI は Apple Intelligence 設定で準備します。
    """

    static func main() async {
        umask(0o077)
        do { try await execute(Array(CommandLine.arguments.dropFirst())) }
        catch {
            // Apple framework errors may contain source text, paths or other private values.
            let message = (error as? MicError)?.localizedDescription ?? "処理に失敗しました。内容や内部エラーを診断出力へ含めず停止しました。"
            FileHandle.standardError.write(Data(("エラー: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func options(_ args: [String], allowed: Set<String>) throws -> [String: String] {
        var result: [String: String] = [:], index = 0
        while index < args.count {
            let key = args[index]
            guard allowed.contains(key), result[key] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw MicError.invalidArguments }
            result[key] = args[index + 1]; index += 2
        }
        return result
    }

    static func execute(_ args: [String]) async throws {
        let command = args.first ?? "help", tail = Array(args.dropFirst())
        if ["help", "--help", "-h"].contains(command) { print(help); return }
        #if !arch(arm64)
        throw MicError.unsupportedPlatform
        #endif
        switch command {
        case "inputs":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            for device in try AudioInputs.list() { print("\(device.uid)\t\(device.name)") }
        case "doctor":
            let flags = try options(tail, allowed: ["--input"])
            let store = try PrivateStore()
            print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("SpeechTranscriber: \(SpeechTranscriber.isAvailable ? "available" : "unavailable")")
            do { print("日本語音声モデル: \(try await LocalModels.speechStatus())") }
            catch { print("日本語音声モデル: unavailable") }
            let model = SystemLanguageModel.default
            print("Mac 内 AI: \(model.availability)")
            print("Mac 内 AI 日本語: \(model.supportsLocale(Locale(identifier: "ja-JP")) ? "supported" : "unsupported")")
            if !model.isAvailable { print(MicError.intelligenceUnavailable.localizedDescription) }
            if let uid = flags["--input"] {
                _ = try AudioInputs.selected(uid)
                print("選択入力: available (UID一致)")
            } else { print("選択入力: 未指定。run には --input が必須です。") }
            print("保存先: \(store.root.path) (期限削除済み)")
            try await LocalModels.requireReady()
        case "install-speech-model":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print("日本語音声モデルの取得を開始します。")
            try await LocalModels.installSpeech()
            print("日本語音声モデル: installed")
        case "prune":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            let store = try PrivateStore(); try store.expire()
            print("期限切れの音声と文字起こしを削除しました。")
        case "delete-logs":
            guard tail == ["--confirm"] else { throw MicError.invalidArguments }
            let store = try PrivateStore(); try store.deleteLogs()
            print("短文ログを削除しました。処理済み判定も削除されます。")
        case "once":
            let flags = try options(tail, allowed: ["--audio"])
            guard let path = flags["--audio"] else { throw MicError.invalidArguments }
            let store = try PrivateStore()
            try await LocalModels.requireReady()
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // Validate before importing; never copy an arbitrarily long recording.
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: source) } catch { throw MicError.invalidAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw MicError.invalidAudio }
            guard duration <= 300 else { throw MicError.audioTooLong }
            let pipeline = Pipeline(store: store)
            try await resume(store, pipeline)
            try await pipeline.process(source)
        case "run":
            let flags = try options(tail, allowed: ["--input", "--segment-seconds"])
            guard let uid = flags["--input"] else { throw MicError.invalidArguments }
            let seconds: Double
            if let value = flags["--segment-seconds"] {
                guard let parsed = Double(value), parsed.isFinite, (2...300).contains(parsed) else { throw MicError.invalidArguments }
                seconds = parsed
            } else { seconds = 300 }
            let store = try PrivateStore()
            try await LocalModels.requireReady()
            let pipeline = Pipeline(store: store)
            try await resume(store, pipeline)
            try await run(uid: uid, seconds: seconds, store: store, pipeline: pipeline)
        default: throw MicError.invalidArguments
        }
    }

    static func resume(_ store: PrivateStore, _ pipeline: Pipeline) async throws {
        for url in try store.pendingAudio() {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let ended = attributes[.modificationDate] as? Date ?? Date()
            print("未完了の保存済み区切りを再開します。")
            try await pipeline.process(url, endedAt: ended, alreadyArchived: true)
        }
    }

    static func run(uid: String, seconds: Double, store: PrivateStore, pipeline: Pipeline) async throws {
        let flag = StopFlag()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { flag.stop() }; terminate.setEventHandler { flag.stop() }
        interrupt.resume(); terminate.resume()
        defer { interrupt.cancel(); terminate.cancel() }
        let recorder = try WindowRecorder(uid: uid, directory: store.audioDirectory)
        try await recorder.start()
        print("録音中 ● 指定した入力機器のみ使用しています。停止: Ctrl-C")
        var previous: Task<Void, Error>?
        let pending = PendingCounter()
        var failure: Error?
        var boundary = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        var cleanup = ContinuousClock.now.advanced(by: .seconds(60))
        func enqueue(_ url: URL, ended: Date) {
            let preceding = previous
            pending.increment()
            previous = Task {
                defer { pending.decrement() }
                do {
                    if let preceding { try await preceding.value }
                    try await pipeline.process(url, endedAt: ended, alreadyArchived: true)
                } catch { flag.stop(); throw error }
            }
        }
        do {
            while !flag.stopped {
                try recorder.verify()
                if ContinuousClock.now >= boundary {
                    if pending.count >= 2 {
                        print("処理待ちの区切りが上限に達したため、録音を停止します。")
                        flag.stop(); break
                    }
                    if let url = try recorder.rotate() { enqueue(url, ended: Date()) }
                    boundary = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
                    print("録音中 ● 次の区切りへ進みました。")
                }
                if ContinuousClock.now >= cleanup {
                    try await pipeline.expire(); cleanup = ContinuousClock.now.advanced(by: .seconds(60))
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch { failure = error }
        let last = recorder.stop()
        let lastEnded = Date()
        print("録音停止。保存済み区切りの処理を完了します。")
        if let previous { try await previous.value }
        if let failure { throw failure }
        if let last { try await pipeline.process(last, endedAt: lastEnded, alreadyArchived: true) }
        try store.expire()
        print("停止しました。")
    }
}
