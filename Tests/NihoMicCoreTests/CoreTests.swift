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

    func testSpeakerAttributionRequiresCopiedIntroduction() {
        let transcript = "今日は松本さんも来ています。私は代表理事を務めております。土地の色についてお話しします。"
        XCTAssertEqual(LocalModels.verifiedSpeaker(label: "代表理事", evidence: "私は代表理事を務めております。", transcript: transcript)?.label, "代表理事")
        XCTAssertNil(LocalModels.verifiedSpeaker(label: "田中さん", evidence: "田中さんが話します。", transcript: transcript))
        XCTAssertNil(LocalModels.verifiedSpeaker(label: "松本さん", evidence: "今日は松本さんも来ています。", transcript: transcript))
        XCTAssertEqual(LocalModels.selfIntroducedSpeaker(in: "ここで今代表理事を務めております\n土地の話をします")?.label, "代表理事")
        XCTAssertEqual(LocalModels.selfIntroducedSpeaker(in: "松本と申します。\n庭の話をします")?.label, "松本")
        XCTAssertNil(LocalModels.selfIntroducedSpeaker(in: "今日は松本さんも来ています。\n庭の話をします"))
    }

    func testEventContextIsBoundedReferenceOnly() throws {
        let planned = "谷戸の手入れを考える会。ゲストは佐藤さん、18時から。"
        let value = try LocalModels.eventContext(from: Data(planned.utf8))
        let section = LocalModels.eventContextSection(value)
        XCTAssertTrue(section.contains(planned))
        XCTAssertTrue(section.contains("発話内容・現在話者の証拠ではない"))
        XCTAssertEqual(LocalModels.eventContextSection(nil), "")
        XCTAssertNoThrow(try LocalModels.eventContext(from: Data(repeating: 0x61, count: 4096)))
        XCTAssertThrowsError(try LocalModels.eventContext(from: Data(repeating: 0x61, count: 4097)))
        XCTAssertThrowsError(try LocalModels.eventContext(from: Data([0xFF])))
        XCTAssertThrowsError(try LocalModels.eventContext(from: Data(" \n ".utf8)))
        XCTAssertThrowsError(try LocalModels.eventContext(from: Data("予定\u{0000}本文".utf8)))
        let transcript = "谷戸の斜面にある道を手入れしたという話です。"
        XCTAssertNil(LocalModels.verifiedSpeaker(label: "佐藤さん", evidence: "ゲストは佐藤さん", transcript: transcript))
        XCTAssertFalse(SafetyPolicy.anchorsSupported(topic: "", summary: "佐藤さんが谷戸の道を手入れした。", evidence: transcript))
    }

    func testExtractiveListSummaryNeedsAnExplicitRelation() {
        let evidence = "庭の色は\n石垣 苔庭 雨水 木々 落葉 日陰 砂利 草花みたいなのですね\nそれらの重なりが庭の色を作ると思います"
        let summary = LocalModels.listSummary(topic: "庭の色", evidence: evidence, speaker: "松本さん")
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("石垣、苔庭、雨水、木々、落葉、日陰、砂利、草花") == true)
        XCTAssertTrue(summary?.hasPrefix("松本さんが") == true)
        XCTAssertTrue((80...140).contains(summary?.count ?? 0))
        XCTAssertNil(LocalModels.listSummary(topic: "庭の色", evidence: "石 苔 水 木 花 草 砂 光みたいなのですね", speaker: nil))
        XCTAssertNil(LocalModels.listSummary(topic: "山の色", evidence: evidence, speaker: nil))
        XCTAssertNil(LocalModels.listSummary(topic: "庭の色", evidence: "重なりで庭の色を作る\n石垣 苔庭 雨水 木々 落葉 日陰 砂利 草花", speaker: nil))
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

    func testVerifiedASRUsesSentenceBoundariesOnlyAfterAgreement() {
        let whisper = "庭のシダは日陰で育てる\n土の表面が乾いたら鉢底から水が出るまで水やりする\n葉がしおれた時には土の状態も確認する"
        let apple = "庭のシダは日陰で育てる。土の表面が乾いたら鉢底から水が出るまで水やりする。葉がしおれた時には土の状態も確認する。"
        let agreed = VerifiedASR.compareForSummary(whisper: whisper, apple: apple)
        XCTAssertNil(agreed.reason)
        XCTAssertEqual(agreed.text, apple)
        XCTAssertGreaterThan(agreed.agreement ?? 0, 0.30)
        let punctuatedWhisper = VerifiedASR.compareForSummary(whisper: apple, apple: apple)
        XCTAssertEqual(punctuatedWhisper.text, apple)
        let unrelated = VerifiedASR.compareForSummary(whisper: whisper,
            apple: "鎌倉の古い道について話す。海沿いの道は風が強く、山側の道は静かだという話だった。")
        XCTAssertEqual(unrelated.reason, "asr_disagreement")
        XCTAssertEqual(unrelated.text, whisper)
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
        XCTAssertFalse(SafetyPolicy.isSensitive("桜寺の住職・松本さんが寺の観光について話していたよ。"))
        XCTAssertTrue(SafetyPolicy.isSensitive("松本さん個人の信仰について話していたよ。"))
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
        XCTAssertEqual(SafetyPolicy.normalizeSummary("谷戸では斜面の途中に道を通したと話していたよ。と話していたよ。"),
                       "谷戸では斜面の途中に道を通したと話していたよ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("谷戸では斜面の途中に道を通したと話していたよ。と話していたよ。と話していたよ。"),
                       "谷戸では斜面の途中に道を通したと話していたよ。")
        XCTAssertEqual(SafetyPolicy.normalizeSummary("谷戸では斜面の途中に道を通したという話をしていたよ。という話をしていたよ。"),
                       "谷戸では斜面の途中に道を通したという話をしていたよ。")
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
        XCTAssertNil(trace.internalSummary)
        XCTAssertEqual(trace.candidateTopic, "庭")
    }

    func testOldRecordWithoutSessionCannotSupplyContext() throws {
        let old = #"{"segmentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","generatedAt":"2027-01-15T08:00:00Z","audioEndedAt":"2027-01-15T08:00:00Z","decision":"publish","topicKey":"鎌倉","text":"","reason":"ok"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(LocalRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.sessionID)
        try withStore { store, _ in
            try store.writeReviewTrace(ReviewTrace(internalSummary: "鎌倉の土地について話した。", internalTopic: "鎌倉",
                                                   internalReason: "ok", gateReason: "ok"), id: record.segmentID)
            try store.append(record)
            XCTAssertTrue(try store.recentContext(before: record.audioEndedAt.addingTimeInterval(60), sessionID: nil).isEmpty)
            XCTAssertTrue(try store.recentContext(before: record.audioEndedAt.addingTimeInterval(60), sessionID: "event-a").isEmpty)
        }
    }

    func testContextIsStrictlyScopedToSessionAndSpeechClock() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try withStore { store, _ in
            func add(_ char: String, minute: Double, sessionID: String, summary: String?) throws {
                let id = String(repeating: char, count: 64)
                try store.writeReviewTrace(ReviewTrace(internalSummary: summary,
                                                       internalTopic: summary == nil ? nil : sessionID,
                                                       internalReason: summary == nil ? "unintelligible" : "ok",
                                                       gateReason: "no_shareable_topic"), id: id)
                try store.append(LocalRecord(segmentID: id, audioEndedAt: start.addingTimeInterval(minute * 60),
                                             sessionID: sessionID, decision: "skip", reason: "no_shareable_topic"))
            }
            try add("a", minute: 0, sessionID: "event-a", summary: "鎌倉の土地について話した。")
            try add("b", minute: 3, sessionID: "event-a", summary: "鎌倉の谷について続けた。")
            try add("c", minute: 6, sessionID: "event-b", summary: "別の物件について話した。")
            try add("d", minute: 10, sessionID: "event-b", summary: nil)
            XCTAssertEqual(try store.recentContext(before: start.addingTimeInterval(7 * 60), sessionID: "event-a").map(\.segmentID),
                           [String(repeating: "a", count: 64), String(repeating: "b", count: 64)])
            XCTAssertEqual(try store.recentContext(before: start.addingTimeInterval(7 * 60), sessionID: "event-b").map(\.segmentID),
                           [String(repeating: "c", count: 64)])
            XCTAssertTrue(try store.recentContext(before: start.addingTimeInterval(7 * 60), sessionID: "event-c").isEmpty)
            XCTAssertTrue(try store.recentContext(before: start.addingTimeInterval(18 * 60), sessionID: "event-a").isEmpty,
                          "別セッションの発話は継続時間を延ばさない")
            XCTAssertEqual(try store.recentContext(before: start.addingTimeInterval(18 * 60), sessionID: "event-b").map(\.segmentID),
                           [String(repeating: "c", count: 64)], "同一セッションの発話は内部要約がなくても継続時間を延ばす")
        }
    }

    func testContextUsesAudioTimeAndUnpublishedIntelligibleSegments() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = "event-a"
        try withStore { store, _ in
            func add(_ char: String, offset: TimeInterval, decision: String, summary: String?, topic: String?) throws {
                let id = String(repeating: char, count: 64)
                try store.writeReviewTrace(ReviewTrace(internalSummary: summary, internalTopic: topic,
                                                       internalEvidence: "合成された今回の発言", internalReason: summary == nil ? "unintelligible" : "ok",
                                                       gateReason: decision == "publish" ? "ok" : "no_shareable_topic"), id: id)
                try store.append(LocalRecord(segmentID: id, generatedAt: start.addingTimeInterval(100_000),
                                             audioEndedAt: start.addingTimeInterval(offset), sessionID: sessionID, decision: decision,
                                             reason: decision == "publish" ? "ok" : "no_shareable_topic"))
            }
            try add("a", offset: 0, decision: "publish", summary: "鎌倉の土地の成り立ちを説明した。", topic: "鎌倉")
            try add("b", offset: 8 * 60, decision: "skip", summary: "その土地に重なる要素を説明した。", topic: "鎌倉")
            try add("c", offset: 12 * 60, decision: "skip", summary: nil, topic: nil)
            let recent = try store.recentContext(before: start.addingTimeInterval(16 * 60), sessionID: sessionID)
            XCTAssertEqual(recent.map(\.segmentID), [String(repeating: "a", count: 64), String(repeating: "b", count: 64)])
            XCTAssertEqual(try store.recentContext(before: start.addingTimeInterval(23 * 60), sessionID: sessionID).count, 2,
                           "内部要約に失敗した発話でも会話の時計は進む")
            XCTAssertTrue(try store.recentContext(before: start.addingTimeInterval(27 * 60), sessionID: sessionID).isEmpty,
                          "最後の発話から15分で失効")
        }
    }

    func testPublishedPostSuppliesContextWhenInternalMemoFailed() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = String(repeating: "e", count: 64)
        try withStore { store, _ in
            try store.writeReviewTrace(ReviewTrace(internalReason: "internal_model_error",
                                                   selectionDecision: "use", gateReason: "ok"), id: id)
            try store.append(LocalRecord(segmentID: id, audioEndedAt: start, speechEndedAt: start,
                                         sessionID: "event-a", decision: "publish",
                                         topicKey: "価格交渉", text: "外国籍の方は価格交渉の進め方を説明していたよ。",
                                         reason: "ok"))
            let recent = try store.recentContext(before: start.addingTimeInterval(3 * 60), sessionID: "event-a")
            XCTAssertEqual(recent.map(\.topic), ["価格交渉"])
            XCTAssertEqual(recent.first?.summary, "外国籍の方は価格交渉の進め方を説明していたよ。")
            XCTAssertNil(recent.first?.topicCitation, "投稿文を過去の原文引用として扱わない")
            XCTAssertTrue(try store.recentContext(before: start.addingTimeInterval(16 * 60), sessionID: "event-a").isEmpty)
        }
    }

    func testExplicitNewPlaceOverridesPriorTopic() {
        let old = ContextEntry(segmentID: "old", endedAt: Date(timeIntervalSince1970: 100),
                               topic: "鎌倉", summary: "鎌倉の土地の成り立ち。")
        XCTAssertEqual(ContextWindow.resolvedTopic(explicitTopic: "", transcript: "それが土地の特徴です。", previous: old), "鎌倉")
        XCTAssertEqual(ContextWindow.resolvedTopic(explicitTopic: "アメリカ", transcript: "アメリカでは別の成り立ちです。", previous: old), "アメリカ")
        XCTAssertEqual(ContextWindow.resolvedTopic(explicitTopic: "アメリカ", transcript: "それは別の話です。", previous: old), "鎌倉",
                       "今回の文字起こしにない地名を新しい対象として採用しない")
    }

    func testSensitiveInternalMemoIsNotPassedToNextSegment() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let publicContext = ContextEntry(segmentID: "a", endedAt: now, topic: "鎌倉", summary: "鎌倉の土地について話した。")
        let privateContext = ContextEntry(segmentID: "b", endedAt: now.addingTimeInterval(60),
                                          topic: "家庭", summary: "家庭の事情を話した。")
        XCTAssertEqual(ContextWindow.recent([publicContext, privateContext], at: now.addingTimeInterval(120)), [publicContext])
    }

    func testPriorCitationAllowsOnlyReferencedNameAndSwitchesOnExplicitPlace() throws {
        let firstText = "鎌倉の土地の成り立ちについて、地形を手がかりに話しています。"
        let first = ContextEntry(segmentID: String(repeating: "a", count: 64), endedAt: Date(), topic: "鎌倉",
                                 summary: "鎌倉の土地の成り立ちについて話した。",
                                 topicCitation: ContextWindow.citation(explicitTopic: "鎌倉", transcript: firstText,
                                                                       segmentID: String(repeating: "a", count: 64), previous: nil))
        let currentEvidence = "その土地には川の流れが関係すると話していました。"
        let citation = try XCTUnwrap(ContextWindow.priorCitation(for: currentEvidence, explicitTopic: "", previous: first))
        XCTAssertEqual(citation.segmentID, first.segmentID)
        XCTAssertNotNil(ContextWindow.priorCitation(for: "土地の成り立ちには川が関係します。", explicitTopic: "", previous: first))
        XCTAssertEqual(ContextWindow.unsupportedAnchors(topic: "鎌倉", summary: "鎌倉の土地には川の流れが関係する。",
                                                        currentEvidence: currentEvidence, priorCitation: citation), [])
        XCTAssertTrue(ContextWindow.unsupportedAnchors(topic: "鎌倉", summary: "鎌倉の縄文時代には川の流れが関係する。",
                                                       currentEvidence: currentEvidence, priorCitation: citation).contains("縄文時代"))
        XCTAssertNil(ContextWindow.priorCitation(for: "アメリカでは土地に川が流れる。", explicitTopic: "アメリカ", previous: first))
        XCTAssertNil(ContextWindow.priorCitation(for: "アメリカでは土地に川が流れる。", explicitTopic: "", previous: first))
        XCTAssertEqual(ContextWindow.resolvedTopic(explicitTopic: "アメリカ", transcript: "アメリカでは土地に川が流れる。", previous: first), "アメリカ")
    }

    func testInternalEvidenceFallbackUsesLiteralCurrentTranscriptWindow() {
        let transcript = String(repeating: "前置きの発言です。", count: 30)
            + "鎌倉の土地の成り立ちは、川の流れと谷の形から考えるという話です。"
        let excerpt = EvidenceMatcher.relevantExcerpt(for: "鎌倉の土地の成り立ちを川の流れから考える。", from: transcript)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(transcript.contains(excerpt ?? "missing"))
        XCTAssertTrue(excerpt?.contains("鎌倉") == true)
        XCTAssertNil(EvidenceMatcher.relevantExcerpt(for: "アメリカの住宅市場について話した。", from: transcript))
        XCTAssertEqual(EvidenceMatcher.extractiveSummary(from: "雑談だけです。鎌倉の土地の成り立ちは、川の流れと谷の形から考えるという話です。",
                                                        relatedTo: "鎌倉の土地の成り立ちを川から考える。"),
                       "鎌倉の土地の成り立ちは、川の流れと谷の形から考えるという話です。")
        XCTAssertEqual(EvidenceMatcher.extractiveSummary(from: "鎌倉では土地の成り立ちを話しています。そして文化継承としての拠点も持っていました。",
                                                        relatedTo: "文化継承の拠点を持っていた。"),
                       "鎌倉では土地の成り立ちを話しています。そして文化継承としての拠点も持っていました。")
        XCTAssertEqual(EvidenceMatcher.extractiveSummary(from: "鎌倉の谷戸には古い道が通っていて、谷の低い場所を避けて斜面の途中を選んだという説明をしています。道の位置を地形から考えます。",
                                                        relatedTo: "道の位置を地形から考える。"),
                       "鎌倉の谷戸には古い道が通っていて、谷の低い場所を避けて斜面の途中を選んだという説明をしています。道の位置を地形から考えます。")
    }

    func testShortVagueInternalMemoExpandsOnlyFromContinuousCurrentQuote() {
        let transcript = "神社仏画は残り続けた。なぜ残ったのか。それはいろんな役割があったからですね。祈りの場所であり、地域コミュニティの中心であり、文化継承の拠点としても機能しました。"
        let vague = "なぜ残ったのか。それはいろんな役割があったからですね。"
        let expanded = EvidenceMatcher.contextualInternalSummary(from: transcript, evidence: vague,
                                                                  draft: vague, explicitTopic: "神社仏画")
        XCTAssertEqual(expanded, transcript)
        XCTAssertTrue((60...140).contains(expanded?.count ?? 0))
        XCTAssertTrue(transcript.contains(expanded ?? "missing"))
        XCTAssertTrue(SafetyPolicy.anchorsSupported(topic: "", summary: expanded ?? "", evidence: expanded ?? ""))
        XCTAssertNil(EvidenceMatcher.contextualInternalSummary(from: transcript, evidence: vague,
                                                               draft: vague, explicitTopic: "鎌倉"))
        XCTAssertNil(EvidenceMatcher.contextualInternalSummary(from: transcript, evidence: vague,
                                                               draft: "神社仏画は祈りの場所や文化継承の拠点として残り続けた。",
                                                               explicitTopic: "神社仏画"),
                     "主語と関係があるメモは抽出で上書きしない")
    }

    func testPlainModelFallbackParsesUsefulFieldsAndKeepsSelectionConservative() {
        let plain = "参考です。\n要約：鎌倉の土地の成り立ちについて話した。\n明示対象：鎌倉\n継続：いいえ\n"
        let internalResult = LocalModels.parseInternalPlain(plain)
        XCTAssertEqual(internalResult?.summary, "鎌倉の土地の成り立ちについて話した。")
        XCTAssertEqual(internalResult?.explicitTopic, "鎌倉")
        XCTAssertEqual(internalResult?.continues, false)
        XCTAssertEqual(LocalModels.parseInternalPlain("土地の形について話した。")?.summary, "土地の形について話した。")
        let selection = LocalModels.parseSelectionPlain("判定: 使用\n話題: 土地\n要点: 川が土地の形に関わる。\n根拠: その土地には川が流れる。")
        XCTAssertTrue(selection?.use == true)
        XCTAssertEqual(selection?.topicKey, "土地")
        XCTAssertNil(LocalModels.parseSelectionPlain("話題: 土地\n要点: 川の話。"), "明示された使用判定がなければ公開選択にしない")
    }

    func testPlainFallbackAcceptsOnlyLabelledFormattingVariants() {
        let internalText = """
        参考です。
        - **要約：**
        鎌倉の谷戸では斜面の途中に道を通した。
        **明示対象**: 鎌倉
        3. 継続：はい。
        補足説明は不要です。
        """
        let internalResult = LocalModels.parseInternalPlain(internalText)
        XCTAssertEqual(internalResult?.summary, "鎌倉の谷戸では斜面の途中に道を通した。")
        XCTAssertEqual(internalResult?.explicitTopic, "鎌倉")
        XCTAssertEqual(internalResult?.continues, true)
        let selectionText = """
        以下の判定です。
        - **使用判定：** 使用
        2. 話題名: 谷戸の道
        要点:
        谷戸では斜面の途中に道を通した。
        根拠発言: 谷戸では斜面の途中に道を通したと説明しました。
        補足: これは予定情報ではありません。
        """
        let selection = LocalModels.parseSelectionPlain(selectionText)
        XCTAssertTrue(selection?.use == true)
        XCTAssertEqual(selection?.topicKey, "谷戸の道")
        XCTAssertEqual(selection?.explanation, "谷戸では斜面の途中に道を通した。")
        XCTAssertEqual(selection?.evidence, "谷戸では斜面の途中に道を通したと説明しました。")
        XCTAssertEqual(LocalModels.parseInternalPlain(#"{"summary":"鎌倉の谷戸では斜面の途中に道を通した。","explicitTopic":"鎌倉","continuesPreviousTopic":true}"#)?.explicitTopic, "鎌倉")
        XCTAssertTrue(LocalModels.parseSelectionPlain(#"{"use":true,"topicKey":"谷戸の道","explanation":"斜面の途中に道を通した。","evidence":"谷戸では斜面の途中に道を通したと説明しました。"}"#)?.use == true)
        XCTAssertNil(LocalModels.parseSelectionPlain("予定のゲストが説明したようです。\n話題: 谷戸\n要点: 予定には谷戸と書かれています。"))
        XCTAssertNil(LocalModels.parseSelectionPlain("判定: 使用\n判定: 見送り\n話題: 谷戸\n要点: 道の話です。"))
        XCTAssertNil(EvidenceMatcher.excerpt(selection?.evidence ?? "", from: "庭の植物を話しました。"),
                     "解析できても原文にない根拠は公開段へ進めない")
    }

    func testSelectionRejectsInstructionPlaceholdersBeforeEvidenceReview() {
        XCTAssertTrue(LocalModels.isSelectionPlaceholder("短い名前"))
        XCTAssertTrue(LocalModels.isSelectionPlaceholder("（短い話題名）"))
        XCTAssertTrue(LocalModels.isSelectionPlaceholder("今回の発言から分かる内容"))
        XCTAssertFalse(LocalModels.isSelectionPlaceholder("鎌倉の谷戸"))
        let evidence = "鎌倉の谷戸では斜面の途中に道を通したと説明しました。"
        XCTAssertNil(LocalModels.parseSelectionPlain("判定: 使用\n話題: 短い名前\n要点: 鎌倉の谷戸の道を説明した。\n根拠: \(evidence)"))
        XCTAssertNil(LocalModels.parseSelectionPlain("判定: 使用\n話題: 鎌倉の谷戸\n要点: 今回の発言から分かる内容\n根拠: \(evidence)"))
        XCTAssertNil(LocalModels.parseSelectionPlain("判定: 使用\n話題: 鎌倉の谷戸\n要点: 鎌倉の谷戸の道を説明した。\n根拠: 今回の原文の連続した20〜240字"))
        XCTAssertEqual(LocalModels.parseSelectionPlain("判定: 使用\n話題: 鎌倉の谷戸\n要点: 鎌倉の谷戸の道を説明した。\n根拠: \(evidence)")?.topicKey,
                       "鎌倉の谷戸")
    }

    func testUnlabelledInternalFallbackUsesOnlyFirstCompleteSentence() {
        let bare = "鎌倉の谷戸では地形を見て道を通した。次の説明は使わない。\n鎌倉\nいいえ"
        let parsed = LocalModels.parseInternalPlain(bare)
        XCTAssertEqual(parsed?.summary, "鎌倉の谷戸では地形を見て道を通した。")
        XCTAssertEqual(parsed?.explicitTopic, "鎌倉", "先頭文に現れた地名だけを未検証の候補とし、後段で原文照合する")
        XCTAssertEqual(parsed?.continues, false)
        XCTAssertNil(LocalModels.parseInternalPlain("説明します。\n鎌倉の谷戸では地形を見て道を通した。\nいいえ"))
        XCTAssertNil(LocalModels.parseInternalPlain("鎌倉の谷戸では地形を見て道を通した\n鎌倉\nいいえ"),
                     "文が完結しない先頭行は採用しない")
        XCTAssertEqual(LocalModels.parseInternalPlain("鎌倉の谷戸では地形を見て道を通した。\n予定のゲスト\nいいえ")?.explicitTopic, "",
                       "先頭文にない予定情報を対象名として拾わない")
    }

    func testVerifiedInternalMemoCanOnlySeedSelectionFromCurrentTranscript() {
        let transcript = "鎌倉の谷戸では斜面の途中に古い道を通し、谷の低い場所を避けたと説明しています。"
        let candidate = LocalModels.validatedInternalSelection(
            summary: "鎌倉の谷戸では斜面の途中に古い道を通し、谷の低い場所を避けた。",
            evidence: transcript, topic: "鎌倉", transcript: transcript)
        XCTAssertTrue(candidate?.use == true)
        XCTAssertEqual(candidate?.evidence, transcript)
        XCTAssertEqual(candidate?.speakerLabel, "")
        XCTAssertEqual(LocalModels.parseUsefulnessPlain("YES\n説明"), true)
        XCTAssertEqual(LocalModels.parseUsefulnessPlain("NO"), false)
        XCTAssertNil(LocalModels.parseUsefulnessPlain("参考としてYES"))
        XCTAssertNil(LocalModels.parseUsefulnessPlain("YES\nNO"))
        XCTAssertNil(LocalModels.validatedInternalSelection(summary: "ゲストの佐藤さんが道を説明した。",
                                                            evidence: transcript, topic: "鎌倉", transcript: transcript),
                     "予定にしかないゲストを発言へ加えない")
        XCTAssertNil(LocalModels.validatedInternalSelection(summary: "鎌倉の谷戸の道を説明した。",
                                                            evidence: transcript, topic: "浄楽寺", transcript: transcript),
                     "原文にない予定の対象名を使わない")
        XCTAssertNil(LocalModels.validatedInternalSelection(summary: "鎌倉の谷戸の道を説明した。",
                                                            evidence: "浄楽寺の話を聞きました。", topic: "鎌倉", transcript: transcript),
                     "内部引用も今回の原文と照合する")
    }

    func testSpeechOffsetCanExpireBeforeRecordingEnd() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try withStore { store, _ in
            let id = String(repeating: "d", count: 64)
            try store.writeReviewTrace(ReviewTrace(internalSummary: "鎌倉の土地について話した。", internalTopic: "鎌倉",
                                                   internalReason: "ok", gateReason: "no_shareable_topic"), id: id)
            try store.append(LocalRecord(segmentID: id, audioEndedAt: start.addingTimeInterval(180),
                                         speechEndedAt: start, sessionID: "event-a", decision: "skip", reason: "no_shareable_topic"))
            XCTAssertTrue(try store.recentContext(before: start.addingTimeInterval(15 * 60), sessionID: "event-a").isEmpty)
            XCTAssertEqual(try store.recentContext(before: start.addingTimeInterval(14 * 60), sessionID: "event-a").count, 1)
        }
    }

    func testStoredTopicCitationRequiresOriginalTranscript() throws {
        try withStore { store, _ in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let firstID = String(repeating: "e", count: 64)
            let nextID = String(repeating: "f", count: 64)
            let original = "鎌倉の土地の成り立ちを話しています。"
            try store.writeTranscript(original, id: firstID)
            try store.writeReviewTrace(ReviewTrace(internalSummary: "鎌倉の土地について話した。", internalTopic: "鎌倉",
                                                   internalReason: "ok", topicSourceSegmentID: firstID,
                                                   topicSourceEvidence: original, gateReason: "ok"), id: firstID)
            try store.append(LocalRecord(segmentID: firstID, audioEndedAt: start, sessionID: "event-a", decision: "publish", reason: "ok"))
            try store.writeReviewTrace(ReviewTrace(internalSummary: "その土地に川が関わる。", internalTopic: "鎌倉",
                                                   internalReason: "ok", topicSourceSegmentID: firstID,
                                                   topicSourceEvidence: "鎌倉では存在しない説明をした。", gateReason: "no_shareable_topic"), id: nextID)
            try store.append(LocalRecord(segmentID: nextID, audioEndedAt: start.addingTimeInterval(180),
                                         sessionID: "event-a", decision: "skip", reason: "no_shareable_topic"))
            let entries = try store.recentContext(before: start.addingTimeInterval(360), sessionID: "event-a")
            XCTAssertEqual(entries.count, 2)
            XCTAssertNotNil(entries.first?.topicCitation)
            XCTAssertNil(entries.last?.topicCitation, "原文に存在しない前区間引用を再利用しない")
        }
    }

    func testStoredTopicCitationCannotReferenceAnotherSession() throws {
        try withStore { store, _ in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let sourceID = String(repeating: "a", count: 64)
            let currentID = String(repeating: "b", count: 64)
            let excerpt = "鎌倉の土地の成り立ちを話しています。"
            try store.writeTranscript(excerpt, id: sourceID)
            try store.append(LocalRecord(segmentID: sourceID, audioEndedAt: start, sessionID: "event-a",
                                         decision: "skip", reason: "no_shareable_topic"))
            try store.writeReviewTrace(ReviewTrace(internalSummary: "土地について話した。", internalTopic: "鎌倉",
                                                   internalReason: "ok", topicSourceSegmentID: sourceID,
                                                   topicSourceEvidence: excerpt, gateReason: "no_shareable_topic"), id: currentID)
            try store.append(LocalRecord(segmentID: currentID, audioEndedAt: start.addingTimeInterval(60),
                                         sessionID: "event-b", decision: "skip", reason: "no_shareable_topic"))
            let entries = try store.recentContext(before: start.addingTimeInterval(120), sessionID: "event-b")
            XCTAssertEqual(entries.count, 1)
            XCTAssertNil(entries.first?.topicCitation)
        }
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
