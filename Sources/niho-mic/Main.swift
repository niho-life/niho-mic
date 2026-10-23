import Foundation
import FoundationModels
import Speech
import AVFoundation
import Darwin
import NihoMicCore

@main
struct NihoMic {
    static let help = """
    にほちゃんマイク v1 — macOS 26+ / Apple Silicon / 既定は Mac 内処理

    niho-mic inputs
    niho-mic doctor [--input <機器UID>] [--asr verified|apple|whisper|gemini]
    niho-mic install-speech-model
    niho-mic run --input <機器UID> [--segment-seconds <2〜300>] [--asr verified|apple|whisper|gemini] [--event-context-file <UTF-8ファイル>]
    niho-mic once --audio <音声ファイル> [--asr verified|apple|whisper|gemini] [--session <ID>] [--event-context-file <UTF-8ファイル>]
    niho-mic audio-check --audio <音声ファイル>
    niho-mic transcribe --audio <音声ファイル> [--asr verified|apple|whisper|gemini]
    niho-mic review-audio --audio <音声ファイル> [--asr verified|apple|whisper|gemini] [--event-context-file <UTF-8ファイル>] [--internal-prompt-file <ファイル>] [--selection-prompt-file <ファイル>] [--prompt-file <ファイル>]
    niho-mic review-text --transcript-file <文字起こしファイル> [--event-context-file <UTF-8ファイル>] [--internal-prompt-file <ファイル>] [--selection-prompt-file <ファイル>] [--prompt-file <ファイル>]
    niho-mic inspect [--latest <1〜50>]
    niho-mic selection-prompt
    niho-mic internal-prompt
    niho-mic prompt
    niho-mic preview --segment <区切りID> [--event-context-file <UTF-8ファイル>] [--internal-prompt-file <ファイル>] [--selection-prompt-file <ファイル>] [--prompt-file <ファイル>]
    niho-mic prune
    niho-mic delete-logs --confirm
    niho-mic help

    録音は運営者が目的を説明し、参加者の同意を得てから手動で開始してください。
    run は既定180秒（指定可能範囲2〜300秒）で区切り、録音を続けながら直前の区切りを処理します。Ctrl-C で録音を止め、最後の区切りを処理します。
    無音・雑音をMac内で判定し、発話が足りない区切りは文字起こし前に見送ります。audio-check で判定だけ試せます。
    文字起こしの既定 verified はWhisperとAppleをMac内で照合し、食い違う区切りを見送ります。各エンジンも --asr で単独指定できます。--asr gemini は比較実験用で音声を Google へ送ります。消費者向けAntigravityアカウントでの外部アプリ連携は公式FAQで非サポートです。自動切替はしません。
    指定機器の切断、既定入力や入力設定の変更を検出すると停止します。
    once、transcribe、review-audio は2〜300秒の録音が対象です。元ファイルは変更しません。
    once は呼び出しごとに独立した会話です。連続区間を明示的につなぐ場合だけ同じ --session ID を指定してください。
    当日の予定は --event-context-file で任意指定できます（UTF-8、最大4096バイト）。発話や現在の話者の証拠には使いません。preview で再現する際も同じファイルを再指定してください。
    transcribe は要約・保存せず、生の文字起こしを端末に表示します。画面共有中は注意してください。
    review-audio は同じ音声で文字起こし・採用判断・投稿案を試し、端末に表示します。記録は変更しません。
    review-text は保存済みの文字起こしテキストから採用判断・投稿案だけを試します。記録は変更しません。
    保存先: ~/Library/Application Support/life.niho.mic (0700 / ファイル0600)
    音声72時間、文字起こし168時間。起動時と稼働中に期限切れを削除します。
    停止中は削除されないため、再起動時または prune で削除してください。
    短文ログは保存先の logs/YYYY-MM-DD.jsonl です。標準出力には本文を表示しません。
    inspect はこの端末に限り、文字起こし・使用判定・要約・最終チェックを順に表示します。画面共有中は注意してください。
    preview は保存済み文字起こしを現在の Mac 内 AI で使用判定・再要約します。ログは変更しません。
    internal-prompt / selection-prompt / prompt の出力をファイルへ保存・編集し、preview で試せます。根拠と最終の安全性確認は常に適用されます。
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
        guard let asr = ASREngine(rawValue: flags["--asr"] ?? "verified") else { throw MicError.invalidArguments }
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
            do { try GeminiASR.requireReady(); print("Gemini CLI: installed (ログインとモデルの利用可否は実行時に確認)") }
            catch { print("Gemini CLI: unavailable (README の準備手順を確認)") }
            do { try AudioQuality.requireReady(); print("Mac 内の発話判定: ready") }
            catch { print("Mac 内の発話判定: unavailable") }
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
                let session = record.sessionID.map { " / session \($0)" } ?? ""
                print("\n=== \(record.generatedAt.formatted(date: .abbreviated, time: .standard)) / \(record.segmentID)\(session) ===")
                try printReview(transcript: store.transcript(id: record.segmentID), record: record, trace: store.reviewTrace(id: record.segmentID))
            }
        case "selection-prompt":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print(LocalModels.selectionInstructions)
        case "internal-prompt":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print(LocalModels.internalInstructions)
        case "prompt":
            guard tail.isEmpty else { throw MicError.invalidArguments }
            print(LocalModels.instructions)
        case "preview":
            let flags = try options(tail, allowed: ["--segment", "--prompt-file", "--selection-prompt-file", "--internal-prompt-file", "--event-context-file"])
            guard let id = flags["--segment"], id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw MicError.invalidArguments }
            let store = try PrivateStore()
            guard let record = try store.records().first(where: { $0.segmentID == id }),
                  let transcript = try store.transcript(id: id) else { throw MicError.invalidArguments }
            let summaryInstructions = try readInstructions(flags["--prompt-file"])
            let selectionInstructions = try readInstructions(flags["--selection-prompt-file"])
            let internalInstructions = try readInstructions(flags["--internal-prompt-file"])
            let eventContext = try readEventContext(flags["--event-context-file"])
            try await LocalModels.requireReady()
            try await LocalModels.requireBodyReady()
            let contextAt = record.speechEndedAt ?? record.audioEndedAt
            let context = try store.recentContext(before: contextAt, sessionID: record.sessionID, excluding: id)
            let outcome = try await LocalModels.summarize(transcript, recent: [], id: id, endedAt: record.audioEndedAt,
                                                          summaryInstructions: summaryInstructions, selectionInstructions: selectionInstructions,
                                                          internalInstructions: internalInstructions,
                                                          context: context, contextAt: contextAt, eventContext: eventContext)
            printReview(transcript: transcript, record: outcome.record, trace: outcome.trace, preview: true)
        case "review-text":
            let flags = try options(tail, allowed: ["--transcript-file", "--prompt-file", "--selection-prompt-file", "--internal-prompt-file", "--event-context-file"])
            guard let path = flags["--transcript-file"] else { throw MicError.invalidArguments }
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 64_000,
                  let transcript = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw MicError.invalidArguments }
            try LocalModels.requireSummaryReady()
            try await LocalModels.requireBodyReady()
            let outcome = try await LocalModels.summarize(transcript, recent: [], id: String(repeating: "0", count: 64), endedAt: Date(),
                                                          summaryInstructions: readInstructions(flags["--prompt-file"]),
                                                          selectionInstructions: readInstructions(flags["--selection-prompt-file"]),
                                                          internalInstructions: readInstructions(flags["--internal-prompt-file"]),
                                                          eventContext: readEventContext(flags["--event-context-file"]))
            if ProcessInfo.processInfo.environment["NIHO_MIC_SAFE_STATUS"] == "1" {
                print("internal=\(outcome.trace.internalReason ?? "unknown") internalChars=\(outcome.trace.internalSummary?.count ?? 0) selection=\(outcome.trace.selectionReason ?? "unknown") final=\(outcome.record.reason)")
            } else {
                printReview(transcript: transcript, record: outcome.record, trace: outcome.trace, preview: true)
            }
        case "delete-logs":
            guard tail == ["--confirm"] else { throw MicError.invalidArguments }
            let store = try PrivateStore(); try store.deleteLogs()
            print("短文ログを削除しました。処理済み判定も削除されます。")
        case "once":
            let flags = try options(tail, allowed: ["--audio", "--asr", "--session", "--event-context-file"])
            guard let path = flags["--audio"] else { throw MicError.invalidArguments }
            let sessionID: String
            if let requested = flags["--session"] {
                guard requested.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else {
                    throw MicError.invalidArguments
                }
                sessionID = requested
            } else { sessionID = UUID().uuidString.lowercased() }
            let asr = try selectedASR(flags)
            let store = try PrivateStore()
            try await LocalModels.requireReady(asr: asr, store: store)
            try await LocalModels.requireBodyReady()
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // Validate before importing; never copy an arbitrarily long recording.
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: source) } catch { throw MicError.invalidAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw MicError.invalidAudio }
            guard duration <= 300 else { throw MicError.audioTooLong }
            let pipeline = Pipeline(store: store, asr: asr, sessionID: sessionID,
                                    eventContext: try readEventContext(flags["--event-context-file"]))
            try await resume(store, pipeline)
            try await pipeline.process(source)
        case "audio-check":
            let flags = try options(tail, allowed: ["--audio"])
            guard let path = flags["--audio"] else { throw MicError.invalidArguments }
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: source) } catch { throw MicError.invalidAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration >= 2, duration <= 300 else { throw MicError.invalidAudio }
            print(try AudioQuality.assess(audio).description)
        case "transcribe", "review-audio":
            let flags = try options(tail, allowed: command == "review-audio" ? ["--audio", "--asr", "--prompt-file", "--selection-prompt-file", "--internal-prompt-file", "--event-context-file"] : ["--audio", "--asr"])
            guard let path = flags["--audio"] else { throw MicError.invalidArguments }
            let asr = try selectedASR(flags)
            let store = try PrivateStore()
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: source) } catch { throw MicError.invalidAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration >= 2, duration <= 300 else { throw MicError.invalidAudio }
            if command == "review-audio" {
                try await LocalModels.requireReady(asr: asr, store: store)
                try await LocalModels.requireBodyReady()
                let quality = try AudioQuality.assess(audio)
                print(quality.description)
                guard quality.shouldTranscribe else {
                    let record = LocalRecord(segmentID: try PrivateStore.hash(source), audioEndedAt: Date(), decision: "skip", reason: quality.reason)
                    printReview(transcript: nil, record: record, trace: nil, preview: true)
                    break
                }
            }
            let transcription = try await transcribe(source, asr: asr, store: store)
            if command == "transcribe" { print(transcription.text); break }
            if let agreement = transcription.agreement { print("文字起こし照合: \(String(format: "%.2f", agreement))") }
            if let reason = transcription.reason {
                let record = LocalRecord(segmentID: try PrivateStore.hash(source), audioEndedAt: Date(), decision: "skip", reason: reason)
                printReview(transcript: transcription.text, record: record, trace: nil, preview: true)
                break
            }
            let outcome = try await LocalModels.summarize(transcription.text, recent: [], id: PrivateStore.hash(source), endedAt: Date(),
                                                          summaryInstructions: readInstructions(flags["--prompt-file"]),
                                                          selectionInstructions: readInstructions(flags["--selection-prompt-file"]),
                                                          internalInstructions: readInstructions(flags["--internal-prompt-file"]),
                                                          eventContext: readEventContext(flags["--event-context-file"]))
            printReview(transcript: transcription.text, record: outcome.record, trace: outcome.trace, preview: true)
        case "run":
            let flags = try options(tail, allowed: ["--input", "--segment-seconds", "--asr", "--event-context-file"])
            guard let uid = flags["--input"] else { throw MicError.invalidArguments }
            let asr = try selectedASR(flags)
            let seconds: Double
            if let value = flags["--segment-seconds"] {
                guard let parsed = Double(value), parsed.isFinite, (2...300).contains(parsed) else { throw MicError.invalidArguments }
                seconds = parsed
            } else { seconds = 180 }
            let store = try PrivateStore()
            try await LocalModels.requireReady(asr: asr, store: store)
            try await LocalModels.requireBodyReady()
            let pipeline = Pipeline(store: store, asr: asr,
                                    eventContext: try readEventContext(flags["--event-context-file"]))
            try await resume(store, pipeline)
            try await run(uid: uid, seconds: seconds, store: store, pipeline: pipeline)
        default: throw MicError.invalidArguments
        }
    }

    static func transcribe(_ source: URL, asr: ASREngine, store: PrivateStore) async throws -> TranscriptionResult {
        switch asr {
        case .verified: return try await VerifiedASR.transcribe(source, store: store)
        case .apple:
            guard try await LocalModels.speechStatus() == .installed else { throw MicError.japaneseModelMissing }
            return TranscriptionResult(text: try await LocalModels.transcribe(source))
        case .whisper: return TranscriptionResult(text: try await WhisperASR.transcribe(source, store: store))
        case .gemini: return TranscriptionResult(text: try await GeminiASR.transcribe(source, store: store))
        }
    }

    static func readInstructions(_ path: String?) throws -> String? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 16_384, let value = String(data: data, encoding: .utf8) else { throw MicError.invalidArguments }
        return value
    }

    static func readEventContext(_ path: String?) throws -> String? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 4096 else { throw MicError.invalidArguments }
        return try LocalModels.eventContext(from: Data(contentsOf: url))
    }

    static func printReview(transcript: String?, record: LocalRecord, trace: ReviewTrace?, preview: Bool = false) {
        print("1. 文字起こし:\n\(transcript ?? "（保存なし・期限切れ・録音段階で見送り）")")
        if let trace {
            print("1a. 内部要約: \(trace.internalSummary?.isEmpty == false ? trace.internalSummary! : "（作成なし）")")
            if let topic = trace.internalTopic, !topic.isEmpty { print("    継続話題: \(topic)") }
            if let evidence = trace.internalEvidence, !evidence.isEmpty { print("    今回の根拠: \(evidence)") }
            if let sourceID = trace.topicSourceSegmentID, let source = trace.topicSourceEvidence {
                print("    話題名の出典 [\(sourceID)]: \(source)")
            }
            print("    内部判定: \(trace.internalReason ?? "旧版のため記録なし")")
        } else { print("1a. 内部要約: （保存なし・旧版）") }
        if let decision = trace?.selectionDecision, let reason = trace?.selectionReason {
            print("2. 使用判定: \(decision == "use" ? "使用" : "見送り") / \(reasonDescription(reason)) [\(reason)]")
            if let topic = trace?.selectedTopic, !topic.isEmpty { print("   選んだ話題: \(topic)") }
            if let explanation = trace?.selectionExplanation, !explanation.isEmpty { print("   理由: \(explanation)") }
            if let evidence = trace?.selectionEvidence, !evidence.isEmpty { print("   根拠の発言: \(evidence)") }
        } else if ["audio_too_short", "no_speech", "insufficient_speech", "low_speech_confidence", "asr_second_opinion_short", "asr_disagreement", "unclear"].contains(record.reason) {
            print("2. 使用判定: 見送り / \(reasonDescription(record.reason)) [\(record.reason)]")
        } else { print("2. 使用判定: （旧版のため記録なし）") }
        let candidate = trace?.candidateText ?? ""
        print("3. 要約候補: \(candidate.isEmpty ? "（生成なし）" : candidate)")
        if let topic = trace?.candidateTopic, !topic.isEmpty { print("   候補の話題名: \(topic)") }
        print("4. 最終チェック: \(record.decision == "publish" ? "採用" : "見送り") / \(reasonDescription(record.reason)) [\(record.reason)]")
        print("   最終短文: \(record.text.isEmpty ? "（なし）" : record.text)")
        print("5. 発信: \(preview ? "試行のみ・保存なし" : (record.decision == "publish" ? "Mac 内ログに記録済み" : "なし"))")
    }

    static func reasonDescription(_ reason: String) -> String {
        switch reason {
        case "ok": return "内容を採用"
        case "no_speech", "audio_too_short", "blank_or_short": return "発話がない、または短すぎる"
        case "insufficient_speech": return "発話と判定された時間が短い"
        case "low_speech_confidence": return "発話分類の確信度が低い"
        case "asr_second_opinion_short": return "2種類目の文字起こしが短く、内容を確認できない"
        case "asr_disagreement": return "Mac内の2種類の文字起こしが大きく食い違う"
        case "unclear", "no_clear_topic": return "話題を読み取れない"
        case "evidence_not_in_transcript": return "選ばれた根拠の発言を文字起こしで確認できない"
        case "unsupported_summary": return "短文の内容を根拠の発言で確認できない"
        case "insufficient_detail": return "根拠にある内容から80字以上の具体的な短文を作れない"
        case "grounding_model_error": return "Mac内AIの根拠確認を完了できなかった"
        case "no_shareable_topic": return "理解できる共有価値のある話題を切り出せない"
        case "selection_model_error": return "Mac 内 AI の使用判定を完了できなかった"
        case "internal_model_error": return "Mac 内 AI の内部要約を確認できなかった"
        case "internal_evidence_missing": return "内部要約の根拠を今回の文字起こしで確認できなかった"
        case "internal_unsupported": return "内部要約の内容を今回の発言で確認できなかった"
        case "unintelligible": return "発言の内容を理解できなかった"
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
            try await pipeline.process(url, endedAt: ended, alreadyArchived: true, inheritSession: false)
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
