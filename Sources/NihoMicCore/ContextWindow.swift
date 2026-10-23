import Foundation

/// A private, short-lived memory of intelligible speech, independent of publication.
public struct ContextEntry: Sendable, Equatable {
    public let segmentID: String
    public let endedAt: Date
    public let topic: String
    public let summary: String
    public let topicCitation: TopicCitation?

    public init(segmentID: String, endedAt: Date, topic: String, summary: String, topicCitation: TopicCitation? = nil) {
        self.segmentID = segmentID; self.endedAt = endedAt
        self.topic = topic; self.summary = summary; self.topicCitation = topicCitation
    }
}

public struct TopicCitation: Sendable, Equatable {
    public let segmentID: String
    public let topic: String
    public let excerpt: String
    public init(segmentID: String, topic: String, excerpt: String) {
        self.segmentID = segmentID; self.topic = topic; self.excerpt = excerpt
    }
}

public enum ContextWindow {
    public static let lifetime: TimeInterval = 15 * 60

    /// Any qualifying speech keeps the conversation alive, even if its internal summary failed.
    /// The current segment is also a speech event. A 15-minute speech gap resets the memory.
    public static func continuityStart(speechTimes: [Date], at currentSpeechAt: Date) -> Date? {
        let ordered = (speechTimes.filter { $0 <= currentSpeechAt } + [currentSpeechAt]).sorted()
        guard ordered.count > 1 else { return nil }
        var start = ordered[0]
        for index in 1..<ordered.count where ordered[index].timeIntervalSince(ordered[index - 1]) >= lifetime {
            start = ordered[index]
        }
        return start < currentSpeechAt || ordered.dropLast().contains(currentSpeechAt) ? start : nil
    }

    public static func recent(_ entries: [ContextEntry], at audioEndedAt: Date,
                              speechTimes: [Date]? = nil, limit: Int = 3) -> [ContextEntry] {
        guard let start = continuityStart(speechTimes: speechTimes ?? entries.map(\.endedAt), at: audioEndedAt) else { return [] }
        let ordered = entries.filter {
            $0.endedAt >= start && $0.endedAt <= audioEndedAt && !$0.summary.isEmpty && !$0.topic.isEmpty
                && !SafetyPolicy.isSensitive($0.summary) && !SafetyPolicy.isSensitive($0.topic)
        }
            .sorted { $0.endedAt < $1.endedAt }
        return Array(ordered.suffix(limit))
    }

    /// The current excerpt must establish a new named topic. Otherwise an older label may
    /// disambiguate pronouns, but it never becomes evidence for a claim about this segment.
    public static func resolvedTopic(explicitTopic: String, transcript: String, previous: ContextEntry?) -> String {
        let explicit = explicitTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty, transcript.contains(explicit) { return explicit }
        return previous?.topic ?? ""
    }

    public static func citation(explicitTopic: String, transcript: String, segmentID: String,
                                previous: ContextEntry?) -> TopicCitation? {
        let explicit = explicitTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty, let range = transcript.range(of: explicit), !SafetyPolicy.isSensitive(explicit) {
            let start = transcript.index(range.lowerBound, offsetBy: -min(30, transcript.distance(from: transcript.startIndex, to: range.lowerBound)))
            let end = transcript.index(range.upperBound, offsetBy: min(90, transcript.distance(from: range.upperBound, to: transcript.endIndex)))
            let excerpt = String(transcript[start..<end])
            guard excerpt.contains(explicit) else { return nil }
            return TopicCitation(segmentID: segmentID, topic: explicit, excerpt: excerpt)
        }
        return previous?.topicCitation
    }

    public static func priorCitation(for selectedEvidence: String, explicitTopic: String,
                                     previous: ContextEntry?) -> TopicCitation? {
        guard explicitTopic.isEmpty, let previous, let citation = previous.topicCitation,
              previous.topic == citation.topic, citation.excerpt.contains(citation.topic),
              !SafetyPolicy.isSensitive(citation.topic), !SafetyPolicy.isSensitive(citation.excerpt) else { return nil }
        // A newly named katakana subject in this excerpt defeats an inherited place even
        // when the model forgot to fill explicitTopic. This may conservatively drop context.
        let pattern = #"[ァ-ヶー]{3,}(?=では|は|の|に|で)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: selectedEvidence, range: NSRange(selectedEvidence.startIndex..., in: selectedEvidence)) {
                guard let range = Range(match.range, in: selectedEvidence) else { return nil }
                if !citation.excerpt.contains(selectedEvidence[range]) { return nil }
            }
        }
        return citation
    }

    public static func unsupportedAnchors(topic: String, summary: String, currentEvidence: String,
                                          priorCitation: TopicCitation?) -> [String] {
        let priorName = priorCitation?.excerpt.contains(priorCitation?.topic ?? "") == true ? priorCitation?.topic : nil
        return SafetyPolicy.unsupportedAnchors(topic: topic, summary: summary, evidence: currentEvidence)
            .filter { $0 != priorName }
    }
}
