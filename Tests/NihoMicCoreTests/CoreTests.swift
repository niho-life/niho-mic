import XCTest
import AVFoundation
@testable import NihoMicCore

final class CoreTests: XCTestCase {
    func testSensitiveWholeWindow() {
        for text in ["来週、Aさんが病院へ行く", "政治の話と日陰の植物の育て方", "連絡は sample@example.com です", "電話 090-1234-5678", "神奈川県の三丁目という住所", "家族で旅行に行った話", "未成年者についての話", "今いる人数は三人です", "hello https://example.com", "お金の相談です", "田中さんが鎌倉に住んでいる話"] {
            XCTAssertTrue(SafetyPolicy.isSensitive(text), "synthetic sensitive fixture was accepted")
        }
    }

    func testSafeSyntheticTopics() {
        for text in ["日陰の庭ではシダの葉が美しく育つという植物の話です。", "西御門の谷戸には縄文時代から人が住んでいたらしいという話です。", "木材の乾燥方法や道具の手入れの工夫について話しています。"] {
            XCTAssertNil(SafetyPolicy.transcriptRejection(text))
        }
    }

    func testBlankShortAndUnclear() {
        XCTAssertEqual(SafetyPolicy.transcriptRejection("  \n "), "blank_or_short")
        XCTAssertEqual(SafetyPolicy.transcriptRejection("はい、そうですね"), "blank_or_short")
        XCTAssertEqual(SafetyPolicy.transcriptRejection("この部分は聞き取れず、不明瞭で意味を取れない音声です。"), "unclear")
        XCTAssertEqual(SafetyPolicy.transcriptRejection(String(repeating: "庭", count: 6001)), "too_long_for_local_context")
    }

    func testSummaryNormalizationDoesNotTruncate() {
        let text = "日陰ではシダがよく育つなんだって。"
        XCTAssertEqual(SafetyPolicy.normalizeSummary(" \n" + text + "\n "), text)
        XCTAssertNil(SafetyPolicy.normalizeSummary(String(repeating: "庭", count: 135) + "なんだって。"))
        XCTAssertNotNil(SafetyPolicy.normalizeSummary(String(repeating: "庭", count: 134) + "なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("断定した歴史的事実です。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("庭の話。\n植物なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("庭\u{200B}の植物なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("病気の話なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("[伏せ字]なんだって。"))
        XCTAssertNil(SafetyPolicy.normalizeSummary("A garden story."))
    }

    func testDuplicatesAndNewTopics() {
        let recent = ["日陰でも育てやすいシダの水やりの工夫という話をしていたよ。"]
        XCTAssertTrue(SafetyPolicy.isDuplicate(recent[0], recent: recent))
        XCTAssertTrue(SafetyPolicy.isDuplicate("日陰でも育てやすいシダの水やりの工夫なんだって。", recent: recent))
        XCTAssertFalse(SafetyPolicy.isDuplicate("木材を乾燥させると反りを防げるという話をしていたよ。", recent: recent))
        XCTAssertFalse(SafetyPolicy.isDuplicate("日陰でも育てやすいシダの水やりの工夫に加え、鉢底へ軽石を入れると根腐れを防げるという話をしていたよ。", recent: recent))
        XCTAssertTrue(SafetyPolicy.isDuplicate("　", recent: []))
    }

    func testRetentionBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(Retention.expired(createdAt: now.addingTimeInterval(-Retention.audio + 1), lifetime: Retention.audio, now: now))
        XCTAssertTrue(Retention.expired(createdAt: now.addingTimeInterval(-Retention.audio), lifetime: Retention.audio, now: now))
        XCTAssertFalse(Retention.expired(createdAt: now.addingTimeInterval(-Retention.transcript + 1), lifetime: Retention.transcript, now: now))
        XCTAssertTrue(Retention.expired(createdAt: now.addingTimeInterval(-Retention.transcript), lifetime: Retention.transcript, now: now))
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
            let transcript = store.transcriptDirectory.appendingPathComponent("synthetic.txt")
            try Data("synthetic".utf8).write(to: audio)
            try Data("synthetic".utf8).write(to: transcript)
            try store.expire(now: Date().addingTimeInterval(Retention.audio + 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
            try store.expire(now: Date().addingTimeInterval(Retention.transcript + 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        }
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
            }
        }
    }
}
