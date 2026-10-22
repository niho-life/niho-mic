import Foundation

public enum MicError: String, Error, LocalizedError {
    case invalidArguments, unsupportedPlatform, speechUnavailable, japaneseModelMissing
    case intelligenceUnavailable, japaneseUnsupported, microphoneDenied, inputUnavailable
    case inputChanged, recordingFailed, transcriptionFailed, generationFailed
    case whisperUnavailable, whisperModelMissing
    case geminiUnavailable, geminiRunFailed, geminiPermissionDenied, geminiUnexpectedTool
    case unsafeStorage, storageBusy, invalidAudio, audioTooLong, corruptLog
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "引数が不正です。niho-mic help を確認してください。"
        case .unsupportedPlatform: "macOS 26 以上の Apple Silicon が必要です。"
        case .speechUnavailable: "SpeechTranscriber を利用できません。"
        case .japaneseModelMissing: "日本語音声モデルが未準備です。niho-mic install-speech-model を明示実行してください。"
        case .intelligenceUnavailable: "Mac 内 AI が未準備です。システム設定の Apple Intelligence を有効にし、モデルのダウンロード完了を待って doctor を再実行してください。"
        case .japaneseUnsupported: "Mac 内 AI の日本語対応を確認できません。"
        case .microphoneDenied: "マイクの使用が許可されていません。システム設定のプライバシーとセキュリティで起動元ターミナルを確認してください。"
        case .inputUnavailable: "指定された入力機器が見つからないか、使用できません。inputs を再確認してください。"
        case .inputChanged: "入力機器の切断または入力設定の変更を検出したため、録音を停止しました。"
        case .recordingFailed: "音声の保存に失敗したため、録音を停止しました。"
        case .transcriptionFailed: "文字起こしに失敗しました。音声内容は診断ログへ出力しません。"
        case .whisperUnavailable: "whisper-cli が見つかりません。Homebrew で whisper-cpp をインストールしてください。"
        case .geminiUnavailable: "Antigravity CLI の agy が見つかりません。README の準備手順を確認してください。"
        case .geminiRunFailed: "Gemini CLI の実行に失敗しました。agy models でログインとモデル利用可否を確認してください。"
        case .geminiPermissionDenied: "Gemini CLI が追加の操作権限を要求し、ヘッドレス実行で拒否されました。音声は採用しません。"
        case .geminiUnexpectedTool: "Gemini CLI が指定音声以外の操作を要求しました。音声は採用しません。"
        case .whisperModelMissing: "Whisper の日本語対応モデルが未準備です。README のモデル取得手順を実行してください。"
        case .generationFailed: "Mac 内の要約処理に失敗しました。内容は診断ログへ出力しません。"
        case .unsafeStorage: "専用保存先の安全性または権限を確認できません。"
        case .storageBusy: "別の niho-mic が同じ保存先を使用しています。"
        case .invalidAudio: "音声を読み取れないか、短すぎます。"
        case .audioTooLong: "once は最長 300 秒です。音声を分割して再実行してください。"
        case .corruptLog: "既存ログの整合性を確認できないため、重複防止のため処理を停止しました。"
        }
    }
}

public enum SafetyPolicy {
    // Output guard. The transcript may contain private material; only the selected summary is screened here.
    static let sensitive = ["政治", "選挙", "政党", "宗教", "信仰", "教会", "神様", "病気", "健康", "病院", "医者", "薬", "診断", "妊娠", "障害", "自殺", "うつ病", "家族", "家庭", "妻", "夫", "嫁", "旦那", "息子", "娘", "父", "母", "離婚", "結婚", "恋人", "彼氏", "彼女", "人間関係", "不倫", "喧嘩", "いじめ", "未成年", "子供", "子ども", "小学生", "中学生", "高校生", "赤ちゃん", "お金", "金銭", "借金", "年収", "給料", "給与", "貯金", "口座", "クレジット", "万円", "円", "住所", "電話", "メール", "連絡先", "本名", "秘密", "個人情報", "さん", "くん", "ちゃん", "氏", "先生", "私", "僕", "俺", "わたし", "あなた", "勤務先", "勤め", "住んで", "引っ越", "逮捕", "犯罪", "差別", "性的", "セックス", "自宅", "実家", "誕生日", "歳", "才", "自己紹介", "名前"]

    public static func isSensitive(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let contextualOnly = Set(["私", "僕", "俺", "わたし", "あなた", "さん", "くん", "ちゃん", "氏", "先生", "円", "母", "父", "妻", "夫", "薬", "歳", "才", "住んで"])
        if (sensitive.filter { !contextualOnly.contains($0) } + ["服薬", "治療", "訪問予定", "来週", "明日", "来ている", "来てる", "今いる", "何人", "人数", "入室", "退室", "到着", "出発", "滞在", "出勤", "退勤"]).contains(where: normalized.contains) { return true }
        let patterns = [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                        #"(?:\+?\d[\d ()-]{6,}\d)"#, #"https?://|www\.|@[\w]+"#,
                        #"\d{2,4}[-ー]\d{1,4}|[一二三四五六七八九十]+丁目|\d+番地"#,
                        #"\d+(?:歳|才|円)|(?:妻|夫|父|母)(?:が|は|の|と)|(?:薬)(?:を飲|を処方)"#,
                        #"(?:私|僕|俺|わたし|彼|彼女|[A-Za-z一-龯ぁ-んァ-ヶ]{1,8}さん)(?:が|は)?[^。！？\nがは]{0,24}住んで"#]
        if patterns.contains(where: { normalized.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { return true }
        return false
    }

    public static func transcriptRejection(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 20 { return "blank_or_short" }
        if trimmed.count > 6000 { return "too_long_for_local_context" }
        if ["聞き取れ", "不明瞭", "判別不能", "ご視聴ありがとうございました", "字幕"].contains(where: trimmed.contains) { return "unclear" }
        let compact = trimmed.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        if compact.range(of: #"(.{4,24})\1{3,}"#, options: .regularExpression) != nil { return "unclear" }
        return nil
    }

    public static func normalizeSummary(_ raw: String) -> String? {
        // Reject runaway structured generation instead of hiding a large malformed tail.
        guard raw.count <= 1000 else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        // A malformed structured response can put extra generation after an already closed text field.
        if let terminator = text.range(of: "。」}") {
            let tail = String(text[terminator.upperBound...])
            guard tail.range(of: #"^(?:[」』}\]>\s]|<ctrl[0-9]+>)*$"#, options: .regularExpression) != nil else { return nil }
            text = String(text[..<terminator.lowerBound]) + "。"
        }
        // FoundationModels sometimes appends an empty structured-output terminator after the final punctuation.
        if let period = text.lastIndex(of: "。"), period != text.index(before: text.endIndex) {
            let tail = String(text[text.index(after: period)...])
            if tail.range(of: #"^(?:[」』}\]>\s]|<ctrl[0-9]+>)*$"#, options: .regularExpression) != nil {
                text = String(text[...period])
            }
        }
        guard !text.isEmpty, text.count <= 140,
              !text.contains("\n"), !text.contains("\r"),
              (1...2).contains(text.filter({ $0 == "。" }).count),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }),
              text.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil,
              ["なんだって。", "んだって。", "という話をしていたよ。", "と話していたよ。", "という話だ。", "ようだ。", "らしい。", "みたいだよ。", "よ。"].contains(where: text.hasSuffix),
              !isSensitive(text),
              !["SKIP", "見送り", "不明", "話という話", "話題だったよ", "```", "<", ">", "{", "}", "■", "＊", "***", "[伏"].contains(where: text.contains)
        else { return nil }
        return text
    }

    public static func summaryRejectionReason(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "no_clear_topic" }
        if isSensitive(text) { return "sensitive_output" }
        if ["話という話", "話題だった", "何かについて", "[伏", "SKIP", "見送り"].contains(where: text.contains) { return "vague_summary" }
        return "invalid_summary_format"
    }

    public static func fingerprint(_ text: String) -> String {
        var value = text
        for suffix in ["という話をしていたよ。", "と話していたよ。", "という話だ。", "なんだって。", "んだって。", "ようだ。", "らしい。", "みたいだよ。", "よ。"] where value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        return String(value.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public static func isDuplicate(_ candidate: String, recent: [String]) -> Bool {
        let normalized = fingerprint(candidate)
        guard !normalized.isEmpty else { return true }
        func grams(_ value: String) -> Set<String> {
            let chars = Array(value)
            guard chars.count > 1 else { return Set([value]) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let lhs = grams(normalized)
        return recent.contains { previous in
            let rhsText = fingerprint(previous)
            if normalized == rhsText { return true }
            let rhs = grams(rhsText)
            let shared = Double(lhs.intersection(rhs).count)
            let lengthRatio = Double(min(lhs.count, rhs.count)) / Double(max(1, max(lhs.count, rhs.count)))
            return shared / Double(max(1, lhs.union(rhs).count)) >= 0.75 ||
                (lengthRatio >= 0.80 && shared / Double(max(1, min(lhs.count, rhs.count))) >= 0.70)
        }
    }
}

public enum Retention {
    public static let audio: TimeInterval = 72 * 3600
    public static let transcript: TimeInterval = 168 * 3600
    public static func expired(createdAt: Date, lifetime: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= lifetime
    }
}
