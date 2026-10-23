import XCTest
import FoundationModels
@testable import NihoMicCore

/// All transcripts in this file are synthetic, with no live-session material.
final class SummaryPipelineTests: XCTestCase {
    private let roles = "神社仏閣は祈りの場、地域コミュニティの中心、人生の節目の受け皿、文化継承の拠点、学問を分け合う教育や福祉の場でもあった。"

    func testOneFieldBodyAndLegacyEnvelopesProduceTheSameCandidate() async throws {
        let body = try XCTUnwrap(EvidenceMatcher.extractivePost(from: roles, topic: "神社仏閣"))
        XCTAssertNil(LocalModels.parseDraft(body), "旧2行パーサーは正しい本文だけの応答を落としていた")
        let json = String(data: try JSONSerialization.data(withJSONObject: ["text": body]), encoding: .utf8)!
        for envelope in [body, "本文: " + body, "「" + body + "」", json,
                         "話題: 寺社の役割\n本文: " + body] {
            var plainCalls = 0
            let result = try await LocalModels.generatePostBody(structured: { envelope }, plain: {
                plainCalls += 1
                return "失敗"
            })
            XCTAssertEqual(result, body)
            XCTAssertEqual(plainCalls, 0)
            XCTAssertEqual(SafetyPolicy.normalizeSummary(result), body)
        }
        let quotedSubject = "「神社仏閣」は学問を分け合う場だったんだって。"
        XCTAssertEqual(LocalModels.parsePostBody(quotedSubject), quotedSubject, "文中の引用符を外装として削らない")
        XCTAssertNil(LocalModels.parsePostBody("話題: 寺社\n本文: " + body + "\n補足: 別の説明"))
        XCTAssertNil(LocalModels.parsePostBody(#"{"text":"本文","extra":"別の事実"}"#))
    }

    func testBodyParsingFailureRetriesPlainWithoutChangingTheSelectedTopic() async throws {
        let body = try XCTUnwrap(EvidenceMatcher.extractivePost(from: roles, topic: "神社仏閣"))
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "synthetic parsing failure")
        let errors: [Error] = [LanguageModelSession.GenerationError.decodingFailure(context),
                               NSError(domain: "FoundationModels.ParsingError", code: 1)]
        for error in errors {
            var plainCalls = 0
            let recovered = try await LocalModels.generatePostBody(structured: { throw error }, plain: {
                plainCalls += 1
                return body
            })
            XCTAssertEqual(recovered, body)
            XCTAssertEqual(plainCalls, 1)
        }
        let recoveredLegacy = try await LocalModels.generatePostBody(structured: { "" }, plain: {
            "話題: 原文にない場所\n本文: " + body
        })
        XCTAssertEqual(recoveredLegacy, body, "旧形式の生成話題名を選択済みtopicKeyへ上書きしない")
    }

    func testBodyFormatRecoveryDoesNotRelaxContentGatesOrRetryRefusals() async throws {
        let noHearsay = "神社仏閣は祈りの場であり、地域で学問を分け合う場として使われた。"
        let result = try await LocalModels.generatePostBody(structured: { noHearsay }, plain: { "unused" })
        XCTAssertEqual(result, noHearsay, "形式復旧で主張や伝聞を自動補完しない")
        XCTAssertEqual(SafetyPolicy.normalizeSummary(result), noHearsay,
                       "文末の形式で落とさず、後段の根拠・安全審査へ渡す")
        let invented = "青葉寺では神社仏閣について12種類の役割を説明したんだって。"
        let parsed = try await LocalModels.generatePostBody(structured: { invented }, plain: { "unused" })
        XCTAssertFalse(SafetyPolicy.anchorsSupported(topic: "神社仏閣", summary: parsed, evidence: roles))
        var plainCalls = 0
        do {
            _ = try await LocalModels.generatePostBody(structured: {
                throw LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "synthetic refusal"))
            }, plain: {
                plainCalls += 1
                return invented
            })
            XCTFail("モデル拒否は採用経路へ戻さない")
        } catch { XCTAssertTrue(LocalModels.isGenerationRefusal(error)) }
        XCTAssertEqual(plainCalls, 0)
        let custom = "出力は話題と本文の2行。柔らかい口調で、文化継承の説明を優先する。"
        for plain in [true, false] {
            XCTAssertTrue(LocalModels.postBodyInstructions(custom, plain: plain).hasPrefix(custom), "編集済みpromptの内容指示を保持する")
        }
    }

    func testQuoteOnlySelectionRequiresExactCurrentSpeechAndLiteralSubject() throws {
        let result = try XCTUnwrap(LocalModels.selectionFromQuote("「" + roles + "」", transcript: roles))
        XCTAssertTrue(result.use)
        XCTAssertEqual(result.topicKey, "神社仏閣")
        XCTAssertEqual(result.evidence, roles)
        XCTAssertEqual(result.speakerLabel, "")
        XCTAssertNil(LocalModels.selectionFromQuote("予定の佐藤さんは、神社仏閣で学問を分け合う教育の場を紹介しています。", transcript: roles))
        XCTAssertNil(LocalModels.selectionFromQuote(roles.replacingOccurrences(of: "神社仏閣", with: "桜寺"), transcript: roles))
        XCTAssertNil(LocalModels.selectionFromQuote("NO", transcript: roles))
        XCTAssertNil(LocalModels.selectionFromQuote("それは祈りの場であり、地域コミュニティの中心でもあったという説明です。",
                                                  transcript: "それは祈りの場であり、地域コミュニティの中心でもあったという説明です。"))
    }

    func testPrivateTrailingAnecdoteIsExcludedWithoutStitchingEvidence() throws {
        let privateTail = "友人の子供が家族と学校へ通っています。"
        let nextTopic = "桜寺では庭にシダを植える話をしました。"
        let mixed = roles + privateTail + nextTopic
        XCTAssertEqual(EvidenceMatcher.shareablePrefix(mixed), roles)
        let selection = try XCTUnwrap(LocalModels.selectionFromQuote(mixed, transcript: mixed))
        XCTAssertEqual(selection.evidence, roles)
        XCTAssertNil(EvidenceMatcher.shareablePrefix(privateTail + roles))
        XCTAssertEqual(EvidenceMatcher.shareablePrefix(roles + "この先は聞き取れず不明瞭です。"), roles)
    }

    func testSelectionAcceptsUseSynonymButChecksTheQuoteSeparately() throws {
        let transcript = "神社仏閣は地域で学問を分け合い、病院のような役割も担っていた。"
        let selected = try XCTUnwrap(LocalModels.parseSelectionPlain("判定: 活用\n話題: 神社仏閣\n要点: 地域で学問を分け合う\n根拠: " + transcript))
        XCTAssertTrue(selected.use)
        XCTAssertEqual(selected.evidence, transcript)
        XCTAssertNotNil(LocalModels.validatedInternalSelection(summary: transcript, evidence: transcript,
                                                                topic: "神社仏閣", transcript: transcript),
                        "病院という歴史的な語が原文にあるだけで、公開候補を作る前に捨てない")
        XCTAssertNil(LocalModels.validatedInternalSelection(summary: transcript, evidence: transcript,
                                                             topic: "神社仏閣", transcript: "別の発言だけ"))
    }

    func testFocusedEvidenceDropsUnrelatedLeadInWithoutStitching() throws {
        let lead = "紙の書類が日本語なので難しい。"
        let claim = "価格交渉は最初に大きく申し出てから落としどころを探る場合があり、日本では大きく交渉すると売り主に失礼と受け止められることがある。"
        let excerpt = lead + claim
        XCTAssertEqual(EvidenceMatcher.focusedExcerpt(excerpt, topic: "価格交渉の進め方"), claim)
        XCTAssertEqual(EvidenceMatcher.focusedExcerpt(excerpt, topic: "寺社の役割"), excerpt)

        let repeated = "価格交渉なんですけど、価格交渉は外国籍の方がまず最初に一旦大きく交渉し、相手と相談してそこから落としどころを詰めるのが大体のやり方で、日本の場合は大きくはやらないんですよね。後の発言は不明瞭です。"
        let focused = EvidenceMatcher.focusedExcerpt(repeated, topic: "価格交渉の進め方")
        XCTAssertTrue(focused.hasPrefix("価格交渉は外国籍の方"), focused)
        XCTAssertFalse(focused.contains("後の発言"), focused)
        let direct = try XCTUnwrap(EvidenceMatcher.extractivePost(from: focused, topic: "価格交渉"))
        XCTAssertTrue(direct.hasPrefix("「価格交渉は"))
        XCTAssertTrue(direct.hasSuffix("」と話していたよ。"))
        XCTAssertNotNil(EvidenceMatcher.extractivePost(from: focused, topic: "価格交渉の進め方"))
        XCTAssertTrue(EvidenceMatcher.isVerbatimPost(direct, evidence: focused, topic: "価格交渉"))
        XCTAssertFalse(EvidenceMatcher.isVerbatimPost(direct.replacingOccurrences(of: "日本の場合", with: "鎌倉の場合"),
                                                       evidence: focused, topic: "価格交渉"))
        XCTAssertFalse(EvidenceMatcher.isVerbatimPost(direct, evidence: claim, topic: "価格交渉"))
    }

    func testOnlyNearbyEarlierHeadingCanNameTheCurrentExcerpt() {
        let excerpt = "祈りの場であり、文化継承や学問を分け合う役割もあった。"
        let heading = "神社仏閣の役割"
        XCTAssertEqual(EvidenceMatcher.priorHeading(heading, before: excerpt,
            in: heading + "について説明する。" + excerpt), heading)
        XCTAssertNil(EvidenceMatcher.priorHeading(heading, before: excerpt,
            in: excerpt + "次に" + heading + "へ話題を変える。"))
        XCTAssertNil(EvidenceMatcher.priorHeading(heading, before: excerpt,
            in: heading + String(repeating: "庭の話。", count: 150) + excerpt))
    }

    func testExtractiveRolesPostHasUsefulDetailsAndContractLength() throws {
        let post = try XCTUnwrap(EvidenceMatcher.extractivePost(from: roles + "友人の子供の話です。", topic: "神社仏閣"))
        XCTAssertTrue((80...140).contains(post.count))
        XCTAssertTrue((1...2).contains(post.filter { $0 == "。" }.count))
        for detail in ["祈りの場", "地域コミュニティ", "人生の節目", "文化継承", "教育や福祉"] {
            XCTAssertTrue(post.contains(detail))
        }
        XCTAssertFalse(SafetyPolicy.isSensitive(post))
        XCTAssertEqual(SafetyPolicy.normalizeSummary(post), post)
        XCTAssertTrue(SafetyPolicy.anchorsSupported(topic: "神社仏閣", summary: post, evidence: roles))
        XCTAssertNil(EvidenceMatcher.extractivePost(from: "神社仏閣は祈りの場だった。", topic: "神社仏閣"), "短すぎる内容を一般論で水増ししない")
        XCTAssertNil(EvidenceMatcher.extractivePost(from: roles, topic: "鎌倉"))
    }

    func testOrdinaryParaphrasesStillRequireIndependentSemanticApproval() async {
        let evidence = "神社仏閣は学問を分け合う場であり、困った時には地域で助け合う場でもあった。"
        let summary = "神社仏閣には教育や福祉の役割もあったんだって。"
        XCTAssertTrue(SafetyPolicy.anchorsSupported(topic: "神社仏閣", summary: summary, evidence: evidence))
        var calls = 0
        let approved = await LocalModels.reviewGrounding(topic: "神社仏閣", summary: summary, evidence: evidence) {
            calls += 1
            return true
        }
        XCTAssertTrue(approved)
        let rejected = await LocalModels.reviewGrounding(topic: "神社仏閣", summary: summary, evidence: evidence) {
            calls += 1
            return false
        }
        XCTAssertFalse(rejected)
        XCTAssertEqual(calls, 2, "一般語の許可だけで意味審査を省略しない")
        XCTAssertFalse(SafetyPolicy.anchorsSupported(topic: "教育", summary: summary, evidence: "神社仏閣は庭の手入れをする場だった。"))

        let priceEvidence = "価格交渉は外国籍の方って一旦は大きく価格交渉をして、そこから落としどころを詰めていくのが大体のやり方で、日本の場合は大きくはやらない。"
        let priceDraft = "外国籍の方は一度大きく値下げを提示して落としどころを詰めるのが一般的ですが、日本では大きく値下げをしないという違いがあるんだって。"
        XCTAssertTrue(SafetyPolicy.anchorsSupported(topic: "価格交渉", summary: priceDraft, evidence: priceEvidence),
                      "不足語: \(SafetyPolicy.unsupportedAnchors(topic: "価格交渉", summary: priceDraft, evidence: priceEvidence))")
        let priceRejected = await LocalModels.reviewGrounding(topic: "価格交渉", summary: priceDraft,
                                                              evidence: priceEvidence) { false }
        XCTAssertFalse(priceRejected, "言い換えの許可だけでは投稿できない")
    }

    func testInventedAnchorsNeverReachSemanticApproval() async {
        for summary in ["桜寺は教育の場なんだって。", "神社仏閣には12種類の役割があったんだって。", "神社仏閣には十二種類の役割があったんだって。", "佐藤さんが神社仏閣を説明したんだって。"] {
            var reviewed = false
            let result = await LocalModels.reviewGrounding(topic: "神社仏閣", summary: summary, evidence: roles) {
                reviewed = true
                return true
            }
            XCTAssertFalse(result)
            XCTAssertFalse(reviewed)
        }
    }

    func testSameWordsDoNotBypassSemanticRejectionForCausalityOrASRNoise() async {
        for candidate in ["神社仏閣は文化継承のために祈りの場になったんだって。", "神社仏閣はムンっとする場なんだって。"] {
            let evidence = roles + "そこはムンっとする場です。"
            let approved = await LocalModels.reviewGrounding(topic: "神社仏閣", summary: candidate, evidence: evidence) { false }
            XCTAssertFalse(approved, "語の一致は因果や意味の正しさを証明しない")
        }
    }

    func testOutputSafetyRetriesOnlyErrorsAndRequiresAnExactDecision() async {
        var plainCalls = 0
        let structuredNo = await LocalModels.reviewOutputSafety(structured: { false }, plain: {
            plainCalls += 1
            return "YES"
        })
        XCTAssertEqual(structuredNo, false)
        XCTAssertEqual(plainCalls, 0, "安全審査で拒否された案を再試行しない")
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "synthetic refusal")
        let refusalErrors: [LanguageModelSession.GenerationError] = [
            .guardrailViolation(context), .refusal(.init(transcriptEntries: []), context)
        ]
        for error in refusalErrors {
            let refused = await LocalModels.reviewOutputSafety(structured: { throw error }, plain: {
                plainCalls += 1
                return "YES"
            })
            XCTAssertEqual(refused, false)
        }
        XCTAssertEqual(plainCalls, 0, "生成エラーに見えるモデルの拒否も上書きしない")
        for (raw, expected) in [("YES", true), ("NO", false)] {
            let result = await LocalModels.reviewOutputSafety(structured: { throw MicError.generationFailed }, plain: { raw })
            XCTAssertEqual(result, expected)
        }
        for raw in ["YES\nNO", "YES、安全です", "判断できません", "safe: true", "", "yes"] {
            let result = await LocalModels.reviewOutputSafety(structured: { throw MicError.generationFailed }, plain: { raw })
            XCTAssertNil(result)
        }
        let failed = await LocalModels.reviewOutputSafety(structured: { throw MicError.generationFailed }, plain: { throw MicError.generationFailed })
        XCTAssertNil(failed)
    }

    func testMixedReportingTailsCollapseWithoutRemovingDistinctSentences() {
        for tail in ["と話していたよ。なんだって。", "なんだって。と話していたよ。", "という話をしていたよ。なんだって。",
                     "ようだ。と話していたよ。"] {
            let result = SafetyPolicy.normalizeSummary("神社仏閣は学問を分け合う場だ" + tail)
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.filter { $0 == "。" }.count, 1)
        }
        let distinct = "神社仏閣は祈りの場なんだって。学問を分け合う場でもあったんだって。"
        XCTAssertEqual(SafetyPolicy.normalizeSummary(distinct), distinct)
    }
}
