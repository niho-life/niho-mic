import Foundation

public struct TranscriptionResult: Sendable {
    public let text: String
    public let reason: String?
    public let agreement: Double?

    public init(text: String, reason: String? = nil, agreement: Double? = nil) {
        self.text = text
        self.reason = reason
        self.agreement = agreement
    }
}

/// Compare two independent local recognizers before the transcript can become a post.
/// This is a conservative filter, not an estimate of word error rate.
public enum VerifiedASR {
    public static func transcribe(_ input: URL, store: PrivateStore) async throws -> TranscriptionResult {
        let whisper = try await WhisperASR.transcribe(input, store: store)
        if let reason = SafetyPolicy.transcriptRejection(whisper) {
            return TranscriptionResult(text: whisper, reason: reason)
        }
        let apple = try await LocalModels.transcribe(input)
        return compareForSummary(whisper: whisper, apple: apple)
    }

    public static func compareForSummary(whisper: String, apple: String) -> TranscriptionResult {
        let comparison = compare(primary: whisper, second: apple)
        guard comparison.reason == nil,
              SafetyPolicy.transcriptRejection(apple) == nil,
              !whisper.contains("。"), apple.contains("。"),
              normalized(apple).count >= normalized(whisper).count * 3 / 5 else { return comparison }
        // Whisper remains the independent check. Apple's sentence boundaries make the
        // agreed speech usable by the topic and exact-quote stages.
        return TranscriptionResult(text: apple, agreement: comparison.agreement)
    }

    public static func compare(primary: String, second: String) -> TranscriptionResult {
        if let reason = SafetyPolicy.transcriptRejection(primary) {
            return TranscriptionResult(text: primary, reason: reason)
        }
        let first = normalized(primary), other = normalized(second)
        guard first.count >= 40, other.count >= 20 else {
            return TranscriptionResult(text: primary, reason: "asr_second_opinion_short", agreement: 0)
        }
        let a = trigrams(first), b = trigrams(other)
        guard !a.isEmpty, !b.isEmpty else {
            return TranscriptionResult(text: primary, reason: "asr_second_opinion_short", agreement: 0)
        }
        let overlap = Double(a.intersection(b).count) / Double(a.union(b).count)
        return TranscriptionResult(text: primary, reason: overlap < 0.30 ? "asr_disagreement" : nil, agreement: overlap)
    }

    private static func normalized(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCompatibilityMapping.lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func trigrams(_ text: [Character]) -> Set<String> {
        guard text.count >= 3 else { return [] }
        return Set((0...(text.count - 3)).map { String(text[$0...($0 + 2)]) })
    }
}
