import XCTest
import AVFoundation
@testable import NihoMicCore

final class CoreTests: XCTestCase {
    func testGeminiAcceptsOnlyDirectAudioRead() throws {
        let path = "/private/tmp/synthetic.wav"
        let stream = """
        {"event":"step_update","step_update":{"state":"DONE","step_type":"tool","tool_name":"read_file","tool_info":{"parameters":{"Path":"/private/tmp/synthetic.wav"}}}}
        {"event":"result","result":{"status":"SUCCESS","response":"鎌倉では庭のシダを育てる話です。"}}
        """
        XCTAssertEqual(try GeminiASR.parseStream(Data(stream.utf8), expectedAudioPath: path), "鎌倉では庭のシダを育てる話です。")
        XCTAssertThrowsError(try GeminiASR.parseStream(Data(stream.utf8), expectedAudioPath: "/private/tmp/other.wav")) { error in
            XCTAssertEqual(error as? MicError, .geminiUnexpectedTool)
        }
    }

    func testGeminiRejectsSoftDeniedCommandEvenWithExitZero() {
        let stream = """
        {"event":"step_update","step_update":{"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"ls -la"}}}}
        {"event":"result","result":{"status":"SUCCESS","response":"","denied_actions":[{"action":"command"}]}}
        """
        XCTAssertThrowsError(try GeminiASR.parseStream(Data(stream.utf8), expectedAudioPath: "/private/tmp/synthetic.wav")) { error in
            XCTAssertEqual(error as? MicError, .geminiPermissionDenied)
        }
    }

    func testSelectionExplanationDropsMalformedStructuredTail() {
        XCTAssertEqual(LocalModels.cleanGeneratedField("庭の落ち葉が乾燥を防ぐ。\"}```json{", limit: 120), "庭の落ち葉が乾燥を防ぐ。")
    }

    func testPlainDraftParsingRejectsExtraContent() {
        let parsed = LocalModels.parseDraft("『話題: 土地の色』\n『土地の色は自然や歴史が重なるんだって。』")
        XCTAssertEqual(parsed?.topic, "土地の色")
        XCTAssertEqual(parsed?.text, "土地の色は自然や歴史が重なるんだって。")
        XCTAssertEqual(LocalModels.parseDraft("話題: 土地の色\n本文: 土地の色の話をしているよ。")?.text, "土地の色の話をしているよ。")
        XCTAssertNil(LocalModels.parseDraft("話題: 土地の色\n本文: 土地の色の話。\n秘密: 追加内容"))
    }

    func testGroundingAnchorsRejectUnsupportedNamesAndNumbers() {
        let evidence = "土地の色は自然や歴史、食の重なりで作られると話していました。"
        XCTAssertTrue(SafetyPolicy.anchorsSupported(topic: "土地の色", summary: "土地の色は自然や歴史の重なりで作られるんだって。", evidence: evidence))
        XCTAssertFalse(SafetyPolicy.anchorsSupported(topic: "三浦半島の色", summary: "三浦半島の色は自然や歴史の重なりで作られるんだって。", evidence: evidence))
        XCTAssertFalse(SafetyPolicy.anchorsSupported(topic: "土地の色", summary: "土地の色は10種類あるんだって。", evidence: evidence))
    }

    func testVerifiedASRRequiresIndependentAgreement() {
        let clear = "土地の色は自然と歴史と暮らしが重なって生まれる。観光はその土地の色を見に行くことだと話した。山や海の地形や風土も、その土地を特徴づける自然の色として紹介されていた。"
        let second = "土地の色は、自然・歴史・暮らしが重なって生まれる。観光はその土地の色を見に行くことだと話している。山や海の地形や風土も、その土地を特徴づける自然の色として紹介された。"
        let accepted = VerifiedASR.compare(primary: clear, second: second)
        XCTAssertNil(accepted.reason)
        XCTAssertGreaterThan(accepted.agreement ?? 0, 0.30)
        let unrelated = "庭ではシダを育てるために日陰と水やりを工夫する。土の表面が乾いたら鉢底から水が出るまで注ぐ。"
        XCTAssertEqual(VerifiedASR.compare(primary: clear, second: unrelated).reason, "asr_disagreement")
        XCTAssertEqual(VerifiedASR.compare(primary: clear, second: "はい").reason, "asr_second_opinion_short")
        let repeated = "庭ではシダについて話す。" + String(repeating: "ありがとうございました。", count: 12)
        XCTAssertEqual(VerifiedASR.compare(primary: repeated, second: clear).reason, "unclear")
    }

    func testSelectionEvidenceMustBeCopiedFromTranscript() {
        let source = "西御門の谷戸は縄文時代から続いているという話をしていました。鎌倉時代には別の使われ方をしたそうです。"
        XCTAssertTrue(LocalModels.evidenceIsInTranscript("西御門の谷戸は縄文時代から続いているという話をしていました。", transcript: source))
        XCTAssertEqual(EvidenceMatcher.excerpt("西御門の谷戸は弥生時代から続いているという話をしていました。", from: source),
                       "西御門の谷戸は縄文時代から続いているという話をしていました")
        XCTAssertFalse(LocalModels.evidenceIsInTranscript("鎌倉駅前の建築物は現代に建てられ、白い壁が特徴だそうです。", transcript: source))
        XCTAssertFalse(LocalModels.evidenceIsInTranscript("西御門の谷戸", transcript: source))
        XCTAssertEqual(EvidenceMatcher.excerpt("鎌倉のこの地域については自然と歴史の重なりが", from: "土地の話です。鎌倉のこの地域については自然と歴史の重なりが\nその土地の色を作ると話していました。"),
                       "鎌倉のこの地域については自然と歴史の重なりが\nその土地の色を作ると話していました。")
    }

    func testSensitiveWholeWindow() {
        for text in ["来週、Aさんが病院へ行く", "政治の話と日陰の植物の育て方", "連絡は sample@example.com です", "電話 090-1234-5678", "神奈川県の三丁目という住所", "家族で旅行に行った話", "未成年者についての話", "今いる人数は三人です", "hello https://example.com", "お金の相談です", "田中さんが鎌倉に住んでいる話"] {
            XCTAssertTrue(SafetyPolicy.isSensitive(text), "synthetic sensitive fixture was accepted")
        }
    }

    func testSafeSyntheticTopics() {
        for text in ["日陰の庭ではシダの葉が美しく育つという植物の話です。", "西御門の谷戸には縄文時代から人が住んでいたらしいという話です。", "木材の乾燥方法や道具の手入れの工夫について話しています。", "古い学校の校舎に使う木材について話しています。"] {
            XCTAssertNil(SafetyPolicy.transcriptRejection(text))
        }
        XCTAssertFalse(SafetyPolicy.isSensitive("古い学校の校舎に使う木材なんだって。"))
        let namedSpeaker = "松本さんが、西御門の谷戸には縄文時代から人が住んでいたらしいと話しました。谷戸の成り立ちについての話です。"
        XCTAssertNil(SafetyPolicy.transcriptRejection(namedSpeaker))
        XCTAssertFalse(SafetyPolicy.isSensitive("松本さんが谷戸を説明したんだって。"))
        XCTAssertFalse(SafetyPolicy.isSensitive("林さんが庭を説明したんだって。"))
        XCTAssertEqual(SafetyPolicy.normalizeSummary("松本さんは千葉出身のデザイナーなんだって。"), "松本さんは千葉出身のデザイナーなんだって。")
        XCTAssertNil(SafetyPolicy.transcriptRejection("松本さんの家族について話しています。庭の話もしました。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("松本さんの家族が庭で話したなんだって。"))
    }

    func testBlankShortAndUnclear() {
        XCTAssertEqual(SafetyPolicy.transcriptRejection("  \n "), "blank_or_short")
        XCTAssertEqual(SafetyPolicy.transcriptRejection("はい、そうですね"), "blank_or_short")
        XCTAssertEqual(SafetyPolicy.transcriptRejection("この部分は聞き取れず、不明瞭で意味を取れない音声です。"), "unclear")
        XCTAssertEqual(SafetyPolicy.transcriptRejection(String(repeating: "庭", count: 6001)), "too_long_for_local_context")
        XCTAssertNil(SafetyPolicy.transcriptRejection("庭のシダの育て方を話しました。途中で松本さんの家族についても短く話しました。"))
        XCTAssertEqual(SafetyPolicy.transcriptRejection("地域の課題について話している。本田県の補正などの補正などの補正などの補正などの補正などの会議です。"), "unclear")
    }

    func testSummaryNormalizationDoesNotTruncate() {
        let text = "日陰ではシダがよく育つなんだって。"
        XCTAssertEqual(SafetyPolicy.normalizeSummary(" \n" + text + "\n "), text)
        XCTAssertEqual(SafetyPolicy.normalizeSummary(text + "」}<ctrl46>"), text)
        XCTAssertEqual(SafetyPolicy.normalizeSummary(text + "」}<ctrl46>}"), text)
        XCTAssertEqual(SafetyPolicy.normalizeSummary(text + "」}" + String(repeating: " </div>", count: 150)), text)
        XCTAssertEqual(SafetyPolicy.normalizeSummary(text + "」}```json```{"), text)
        XCTAssertEqual(SafetyPolicy.normalizeSummary("土地の色は自然と歴史の重なりなんだって。なんだって。"), "土地の色は自然と歴史の重なりなんだって。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("土地の色は自然と歴史の重なりなんだって。今どんな話をしているよ。"), "土地の色は自然と歴史の重なりなんだって。")
        XCTAssertNil(SafetyPolicy.normalizeSummary("今どんな話をしているよ。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary(text + "」} 文の外に続く壊れた出力。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary(text + "」}" + String(repeating: "<ctrl46>", count: 150)))
        XCTAssertEqual(SafetyPolicy.normalizeSummary("庭ではシダが育つんだって。"), "庭ではシダが育つんだって。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("日陰の庭でシダが育つという話だ。"), "日陰の庭でシダが育つという話だ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("日陰の庭ではシダが育つようだ。"), "日陰の庭ではシダが育つようだ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("松本さんは千葉出身のデザイナーみたいだよ。"), "松本さんは千葉出身のデザイナーみたいだよ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("今は西御門の谷戸の成り立ちについて話しているよ。"), "今は西御門の谷戸の成り立ちについて話しているよ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("今は木材の色に合わせてロゴを考えているよ。みんなでデザインの案を話しているよ。"), "今は木材の色に合わせてロゴを考えているよ。みんなでデザインの案を話しているよ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("今は木材の色に合わせたロゴについて話しているよ。デザインの案が広がっているよ。"), "今は木材の色に合わせたロゴについて話しているよ。デザインの案が広がっているよ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("庭ではシダが育つなんだって。葉を残して冬を越すなんだって。"), "庭ではシダが育つなんだって。葉を残して冬を越すなんだって。")
        XCTAssertNil(SafetyPolicy.normalizeSummary(String(repeating: "庭", count: 135) + "なんだって。"))
        XCTAssertNotNil(SafetyPolicy.normalizeSummary(String(repeating: "庭", count: 134) + "なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("断定した歴史的事実です。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("庭の話。\n植物なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("庭\u{200B}の植物なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("病気の話なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("[伏せ字]なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("A garden story."))
        XCTAssertNil(SafetyPolicy.normalizeSummary("説明の流れが話題だったよ。という話をしていたよ。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("庭の植物についての話という話をしていたよ。"))
    }

    func testDuplicatesAndNewTopics() {
        let recent = ["日陰でも育てやすいシダの水やりの工夫という話をしていたよ。"]
        XCTAssertTrue(SafetyPolicy.isDuplicate(recent[0], recent: recent))
        XCTAssertTrue(SafetyPolicy.isDuplicate("日陰でも育てやすいシダの水やりの工夫なんだって。", recent: recent))
        XCTAssertTrue(SafetyPolicy.isDuplicate("水やりの注意を説明した上で、それでも育てたいならシダを選ぶという流れが話題だったよ。という話をしていたよ。", recent: ["鉢の違いを説明して水やりの注意を伝えた上で、それでも育てたいならシダを選ぶという話なんだって。"]))
        XCTAssertFalse(SafetyPolicy.isDuplicate("木材を乾燥させると反りを防げるという話をしていたよ。", recent: recent))
        XCTAssertFalse(SafetyPolicy.isDuplicate("日陰でも育てやすいシダの水やりの工夫に加え、鉢底へ軽石を入れると根腐れを防げるという話をしていたよ。", recent: recent))
        XCTAssertTrue(SafetyPolicy.isDuplicate("　", recent: []))
    }

    func testSummaryRejectionReasons() {
        XCTAssertEqual(SafetyPolicy.summaryRejectionReason("病気の話なんだって。"), "sensitive_output")
        XCTAssertEqual(SafetyPolicy.summaryRejectionReason("説明したという話という話をしていたよ。"), "vague_summary")
        XCTAssertEqual(SafetyPolicy.summaryRejectionReason("説明した。"), "invalid_summary_format")
    }

    func testRetentionBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(Retention.expired(createdAt: now.addingTimeInterval(-Retention.audio + 1), lifetime: Retention.audio, now: now))
        XCTAssertTrue(Retention.expired(createdAt: now.addingTimeInterval(-Retention.audio), lifetime: Retention.audio, now: now))
        XCTAssertFalse(Retention.expired(createdAt: now.addingTimeInterval(-Retention.transcript + 1), lifetime: Retention.transcript, now: now))
        XCTAssertTrue(Retention.expired(createdAt: now.addingTimeInterval(-Retention.transcript), lifetime: Retention.transcript, now: now))
    }

    func testOldReviewTraceRemainsReadable() throws {
        let old = #"{"candidateTopic":"庭","candidateText":"庭の話なんだって。","normalizedText":"庭の話なんだって。","gateReason":"ok"}"#
        let trace = try JSONDecoder().decode(ReviewTrace.self, from: Data(old.utf8))
        XCTAssertNil(trace.selectionDecision)
        XCTAssertNil(trace.selectedTopic)
        XCTAssertNil(trace.selectionEvidence)
        XCTAssertEqual(trace.candidateTopic, "庭")
    }

    func withStore(_ body: (PrivateStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("niho-mic-synthetic-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PrivateStore(root: root)
        try body(store, root)
    }

    func testPrivateModesAndDurableReceipt() throws {
        try withStore { store, root in
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let id = String(repeating: "a", count: 64)
            let record = LocalRecord(segmentID: id, audioEndedAt: Date(), decision: "publish", topicKey: "植物", text: "庭のシダなんだって。", reason: "ok")
            try store.append(record)
            try store.append(record)
            XCTAssertEqual(try store.records().count, 1)
            let logs = root.appendingPathComponent("logs")
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).first)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertThrowsError(try PrivateStore(root: root))
        }
    }

    func testExpiryDeletesOnlyExpiredPrivateArtifacts() throws {
        try withStore { store, _ in
            let audio = store.audioDirectory.appendingPathComponent("synthetic.caf")
            let geminiAudio = store.geminiScratchDirectory.appendingPathComponent("synthetic.wav")
            let transcript = store.transcriptDirectory.appendingPathComponent("synthetic.txt")
            let id = String(repeating: "b", count: 64)
            try store.writeReviewTrace(ReviewTrace(candidateTopic: "庭", candidateText: "庭にシダが育つなんだって。", gateReason: "ok"), id: id)
            XCTAssertEqual(try store.reviewTrace(id: id)?.candidateTopic, "庭")
            let trace = store.transcriptDirectory.appendingPathComponent(id + ".review.json")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: trace.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try Data("synthetic".utf8).write(to: audio)
            try Data("synthetic".utf8).write(to: geminiAudio)
            try Data("synthetic".utf8).write(to: transcript)
            try store.expire(now: Date().addingTimeInterval(Retention.audio + 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: geminiAudio.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
            try store.expire(now: Date().addingTimeInterval(Retention.transcript + 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: trace.path))
        }
    }

    func testRestartRemovesInterruptedGeminiScratchAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("niho-mic-synthetic-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch: URL
        do {
            let store = try PrivateStore(root: root)
            scratch = store.geminiScratchDirectory.appendingPathComponent("synthetic.wav")
            try Data("synthetic audio".utf8).write(to: scratch)
        }
        _ = try PrivateStore(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testStoreRejectsSymlinks() throws {
        try withStore { store, root in
            let target = root.appendingPathComponent("synthetic")
            try Data("synthetic".utf8).write(to: target)
            let link = store.audioDirectory.appendingPathComponent("unsafe.caf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try store.expire())
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testHashAndPendingDedup() throws {
        try withStore { store, root in
            let source = root.appendingPathComponent("synthetic-source")
            try Data("synthetic fixture only".utf8).write(to: source)
            let id = try PrivateStore.hash(source)
            XCTAssertEqual(id.count, 64)
            _ = try store.archive(source, id: id)
            // Whisper's interrupted conversion must never be resumed as a recording.
            try Data("synthetic scratch".utf8).write(to: store.audioDirectory.appendingPathComponent("whisper-scratch.wav"))
            XCTAssertEqual(try store.pendingAudio().count, 1)
            try store.append(LocalRecord(segmentID: id, audioEndedAt: Date(), decision: "skip", reason: "no_speech"))
            XCTAssertTrue(try store.pendingAudio().isEmpty)
        }
    }

    func testCorruptLogFailsClosed() throws {
        try withStore { store, root in
            try Data("{broken json}\n".utf8).write(to: root.appendingPathComponent("logs/2026-01-01.jsonl"))
            XCTAssertThrowsError(try store.records())
        }
    }

    func testSyntheticSilenceAndTone() throws {
        try withStore { _, root in
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            for amplitude: Float in [0, 0.1] {
                let url = root.appendingPathComponent("synthetic-\(amplitude).caf")
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
                buffer.frameLength = 32_000
                for index in 0..<32_000 { buffer.floatChannelData![0][index] = amplitude * sin(Float(index) * 0.1) }
                do { let output = try AVAudioFile(forWriting: url, settings: format.settings); try output.write(from: buffer) }
                XCTAssertEqual(try AudioQuality.hasAudibleSignal(AVAudioFile(forReading: url)), amplitude > 0)
                let assessment = try AudioQuality.assess(AVAudioFile(forReading: url))
                XCTAssertFalse(assessment.shouldTranscribe, "無音や純音を発話として文字起こししない")
            }
        }
    }

    func testAudioGateRulesKeepShortClearSpeechAndRejectNoise() {
        XCTAssertEqual(AudioGateResult(duration: 180, candidateSpeech: 0).reason, "insufficient_speech")
        XCTAssertEqual(AudioGateResult(duration: 180, candidateSpeech: 30, speech: 8,
                                       confidentSpeech: 1).reason, "low_speech_confidence")
        XCTAssertEqual(AudioGateResult(duration: 180, candidateSpeech: 162, speech: 110,
                                       confidentSpeech: 78).reason, "low_speech_confidence")
        XCTAssertEqual(AudioGateResult(duration: 180, candidateSpeech: 177, speech: 150,
                                       confidentSpeech: 132).reason, "ok")
        XCTAssertEqual(AudioGateResult(duration: 180, candidateSpeech: 9, speech: 8,
                                       confidentSpeech: 6).reason, "ok")
        XCTAssertEqual(AudioGateResult(duration: 180, candidateSpeech: 120, speech: 95,
                                       confidentSpeech: 70).reason, "ok")
    }

    func testEnergyCheckIncludesBothStereoChannels() throws {
        try withStore { _, root in
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
            buffer.frameLength = 32_000
            for index in 0..<32_000 {
                buffer.floatChannelData![0][index] = 0
                buffer.floatChannelData![1][index] = 0.1 * sin(Float(index) * 0.1)
            }
            let url = root.appendingPathComponent("synthetic-stereo.caf")
            do { let output = try AVAudioFile(forWriting: url, settings: format.settings); try output.write(from: buffer) }
            XCTAssertTrue(try AudioQuality.hasAudibleSignal(AVAudioFile(forReading: url)))
        }
    }
}
