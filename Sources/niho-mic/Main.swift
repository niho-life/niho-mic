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
    niho-mic doctor [--input <機器UID>] [--asr apple|whisper]
    niho-mic install-speech-model
    niho-mic run --input <機器UID> [--segment-seconds <2〜300>] [--asr apple|whisper]
    niho-mic once --audio <音声ファイル> [--asr apple|whisper]
    niho-mic transcribe --audio <音声ファイル> [--asr apple|whisper]
    niho-mic inspect [--latest <1〜50>]
    niho-mic selection-prompt
    niho-mic prompt
    niho-mic preview --segment <区切りID> [--selection-prompt-file <ファイル>] [--prompt-file <ファイル>]
    niho-mic prune
    niho-mic delete-logs --confirm
    niho-mic help

    録音は運営者が目的を説明し、参加者の同意を得てから手動で開始してください。
    run は既定120秒（指定可能範囲2〜300秒）で区切ります。Ctrl-C で録音を止め、最後の区切りを処理します。
    文字起こしは既定 apple、--asr whisper で Mac 内の無料 Whisper に切り替えます。モデルと whisper-cli は別途準備してください。
    指定機器の切断、既定入力や入力設定の変更を検出すると停止します。
    once と transcribe は2〜300秒の録音が対象です。元ファイルは変更しません。
    transcribe は要約・保存せず、生の文字起こしを端末に表示します。画面共有中は注意してください。
    保存先: ~/Library/Application Support/life.niho.mic (0700 / ファイル0600)
    音声72時間、文字起こし168時間。起動時と稼働中に期限切れを削除します。
    停止中は削除されないため、再起動時または prune で削除してください。
    短文ログは保存先の logs/YYYY-MM-DD.jsonl です。標準出力には本文を表示しません。
    inspect はこの端末に限り、文字起こし・使用判定・要約・最終チェックを順に表示します。画面共有中は注意してください。
    preview は保存済み文字起こしを現在の Mac 内 AI で使用判定・再要約します。ログは変更しません。
    selection-prompt / prompt の出力をファイルへ保存・編集し、preview で試せます。最終の安全性確認は常に適用されます。
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

    static func selectedASR(_ flags: [String: String]) throws -> ASREngine {
        guard let asr = ASREngine(rawValue: flags["--asr"] ?? "apple") else { throw MicError.invalidArguments }
        return asr
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
            let flags = try options(tail, allowed: ["--input", "--asr"])
            let asr = try selectedASR(flags)
            let store = try PrivateStore()
            print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("SpeechTranscriber: \(SpeechTranscriber.isAvailable ? "available" : "unavailable")")
            do { print("日本語音声モデル: \(try await LocalModels.speechStatus())") }
            catch { print("日本語音声モデル: unavailable") }
            do { try WhisperASR.requireReady(store: store); print("Whisper: ready") }
            catch { print("Whisper: unavailable (README の準備手順を確認)") }
            print("選択した文字起こし: \(asr.rawValue)")
            let model = SystemLanguageModel.default
            print("Mac 内 AI: \(model.availability)")
            print("Mac 内 AI 日本語: \(model.supportsLocale(Locale(identifier: "ja-JP")) ? "supported" : "unsupported")")
            if !model.isAvailable { print(MicError.intelligenceUnavailable.localizedDescription) }
            if let uid = flags["--input"] {
                _ = try AudioInputs.selected(uid)
                print("選択入力: available (UID一致)")
            } else { print("選択入力: 未指定。run には --input が必須です。") }
            print("保存先: \(store.root.path) (期限削除済み)")
            try await LocalModels.requireReady(asr: asr, store: store)
        case "install-speech-model":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print("日本語音声モデルの取得を開始します。")
            try await LocalModels.installSpeech()
            print("日本語音声モデル: installed")
        case "prune":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            let store = try PrivateStore(); try store.expire()
            print("期限切れの音声と文字起こしを削除しました。")
        case "inspect":
            let flags = try options(tail, allowed: ["--latest"])
            let count: Int
            if let value = flags["--latest"] {
                guard let parsed = Int(value), (1...50).contains(parsed) else { throw MicError.invalidArguments }
                count = parsed
            } else { count = 5 }
            let store = try PrivateStore()
            for record in try store.records().suffix(count) {
                print("\n=== \(record.generatedAt.formatted(date: .abbreviated, time: .standard)) / \(record.segmentID) ===")
                try printReview(transcript: store.transcript(id: record.segmentID), record: record, trace: store.reviewTrace(id: record.segmentID))
            }
        case "selection-prompt":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print(LocalModels.selectionInstructions)
        case "prompt":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print(LocalModels.instructions)
        case "preview":
            let flags = try options(tail, allowed: ["--segment", "--prompt-file", "--selection-prompt-file"])
            guard let id = flags["--segment"], id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw MicError.invalidArguments }
            let store = try PrivateStore()
            guard let record = try store.records().first(where: { $0.segmentID == id }),
                  let transcript = try store.transcript(id: id) else { throw MicError.invalidArguments }
            let summaryInstructions = try readInstructions(flags["--prompt-file"])
            let selectionInstructions = try readInstructions(flags["--selection-prompt-file"])
            try await LocalModels.requireReady()
            let outcome = try await LocalModels.summarize(transcript, recent: [], id: id, endedAt: record.audioEndedAt,
                                                          summaryInstructions: summaryInstructions, selectionInstructions: selectionInstructions)
            printReview(transcript: transcript, record: outcome.record, trace: outcome.trace, preview: true)
        case "delete-logs":
            guard tail == ["--confirm"] else { throw MicError.invalidArguments }
            let store = try PrivateStore(); try store.deleteLogs()
            print("短文ログを削除しました。処理済み判定も削除されます。")
        case "once":
            let flags = try options(tail, allowed: ["--audio", "--asr"])
            guard let path = flags["--audio"] else { throw MicError.invalidArguments }
            let asr = try selectedASR(flags)
            let store = try PrivateStore()
            try await LocalModels.requireReady(asr: asr, store: store)
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // Validate before importing; never copy an arbitrarily long recording.
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: source) } catch { throw MicError.invalidAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw MicError.invalidAudio }
            guard duration <= 300 else { throw MicError.audioTooLong }
            let pipeline = Pipeline(store: store, asr: asr)
            try await resume(store, pipeline)
            try await pipeline.process(source)
        case "transcribe":
            let flags = try options(tail, allowed: ["--audio", "--asr"])
            guard let path = flags["--audio"] else { throw MicError.invalidArguments }
            let asr = try selectedASR(flags)
            let store = try PrivateStore()
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: source) } catch { throw MicError.invalidAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration >= 2, duration <= 300 else { throw MicError.invalidAudio }
            let transcript: String
            switch asr {
            case .apple:
                guard try await LocalModels.speechStatus() == .installed else { throw MicError.japaneseModelMissing }
                transcript = try await LocalModels.transcribe(source)
            case .whisper:
                transcript = try await WhisperASR.transcribe(source, store: store)
            }
            print(transcript)
        case "run":
            let flags = try options(tail, allowed: ["--input", "--segment-seconds", "--asr"])
            guard let uid = flags["--input"] else { throw MicError.invalidArguments }
            let asr = try selectedASR(flags)
            let seconds: Double
            if let value = flags["--segment-seconds"] {
                guard let parsed = Double(value), parsed.isFinite, (2...300).contains(parsed) else { throw MicError.invalidArguments }
                seconds = parsed
            } else { seconds = 120 }
            let store = try PrivateStore()
            try await LocalModels.requireReady(asr: asr, store: store)
            let pipeline = Pipeline(store: store, asr: asr)
            try await resume(store, pipeline)
            try await run(uid: uid, seconds: seconds, store: store, pipeline: pipeline)
        default: throw MicError.invalidArguments
        }
    }

    static func readInstructions(_ path: String?) throws -> String? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 16_384, let value = String(data: data, encoding: .utf8) else { throw MicError.invalidArguments }
        return value
    }

    static func printReview(transcript: String?, record: LocalRecord, trace: ReviewTrace?, preview: Bool = false) {
        print("1. 文字起こし:\n\(transcript ?? "（保存なし・期限切れ・録音段階で見送り）")")
        if let decision = trace?.selectionDecision, let reason = trace?.selectionReason {
            print("2. 使用判定: \(decision == "use" ? "使用" : "見送り") / \(reasonDescription(reason)) [\(reason)]")
            if let topic = trace?.selectedTopic, !topic.isEmpty { print("   選んだ話題: \(topic)") }
            if let explanation = trace?.selectionExplanation, !explanation.isEmpty { print("   理由: \(explanation)") }
        } else if ["audio_too_short", "no_speech"].contains(record.reason) {
            print("2. 使用判定: 見送り / \(reasonDescription(record.reason)) [\(record.reason)]")
        } else { print("2. 使用判定: （旧版のため記録なし）") }
        let candidate = trace?.candidateText ?? ""
        print("3. 要約候補: \(candidate.isEmpty ? "（生成なし）" : candidate)")
        print("4. 最終チェック: \(record.decision == "publish" ? "採用" : "見送り") / \(reasonDescription(record.reason)) [\(record.reason)]")
        print("   最終短文: \(record.text.isEmpty ? "（なし）" : record.text)")
        print("5. 発信: \(preview ? "試行のみ・保存なし" : (record.decision == "publish" ? "Mac 内ログに記録済み" : "なし"))")
    }

    static func reasonDescription(_ reason: String) -> String {
        switch reason {
        case "ok": return "内容を採用"
        case "no_speech", "audio_too_short", "blank_or_short": return "発話がない、または短すぎる"
        case "unclear", "no_clear_topic": return "話題を読み取れない"
        case "no_shareable_topic": return "理解できる共有価値のある話題を切り出せない"
        case "selection_model_error": return "Mac 内 AI の使用判定を完了できなかった"
        case "too_long_for_local_context": return "文字起こしが長すぎる"
        case "unsafe_topic": return "候補の話題名に個人情報またはセンシティブな内容がある"
        case "personal_name_output": return "旧版の氏名検査で見送り"
        case "sensitive_output": return "要約候補に個人情報またはセンシティブな内容がある"
        case "vague_summary": return "要約候補が抽象的で内容が伝わらない"
        case "invalid_summary_format": return "要約候補が140字・1〜2文・文末などの形式に合わない"
        case "duplicate": return "直近とほぼ同じ内容"
        case "safety_review_rejected": return "Mac 内 AI が要約候補の公開を見送った"
        case "safety_model_error": return "Mac 内 AI の安全性確認を完了できなかった"
        case "model_error": return "Mac 内 AI の要約生成を完了できなかった"
        case "unsafe_model_output": return "旧版の安全性確認で見送り"
        case "private", "sensitive": return "旧版のモデル判定で見送り"
        default: return reason
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
