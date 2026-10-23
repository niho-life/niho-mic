import Foundation

/// Resolve a nearly copied model quote back to an actual continuous transcript span.
/// A small spelling difference is allowed, but the returned evidence is always source text.
enum EvidenceMatcher {
    /// Drop a private or unintelligible trailing sentence without joining disjoint evidence.
    /// A private first sentence cannot be repaired by silently moving to a different topic.
    static func shareablePrefix(_ excerpt: String) -> String? {
        var end = excerpt.startIndex
        var sentenceStart = excerpt.startIndex
        for index in excerpt.indices where "。！？\n".contains(excerpt[index]) {
            let next = excerpt.index(after: index)
            let sentence = String(excerpt[sentenceStart..<next])
            if SafetyPolicy.isSensitive(sentence) || SafetyPolicy.containsUnclearSpeech(sentence) { break }
            end = next
            sentenceStart = next
        }
        if end == excerpt.startIndex {
            guard !SafetyPolicy.isSensitive(excerpt), SafetyPolicy.transcriptRejection(excerpt) == nil else { return nil }
            return excerpt
        }
        let prefix = String(excerpt[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count >= 20 ? prefix : nil
    }

    /// Drop an unrelated lead-in only when the selected topic itself occurs later in the
    /// same verified excerpt. The returned text remains one continuous original span.
    static func focusedExcerpt(_ excerpt: String, topic: String) -> String {
        let cue = topic.components(separatedBy: "の").first ?? topic
        guard (3...20).contains(cue.count), let range = excerpt.range(of: cue) else { return excerpt }
        var suffix = String(excerpt[range.lowerBound...])
        if let repeated = suffix.range(of: cue + "は"),
           suffix.distance(from: suffix.startIndex, to: repeated.lowerBound) < 30 {
            suffix = String(suffix[repeated.lowerBound...])
        }
        guard suffix.count >= 60, let safe = shareablePrefix(suffix), safe.count >= 60 else { return excerpt }
        if let firstPeriod = safe.firstIndex(of: "。") {
            let firstClaim = String(safe[...firstPeriod])
            if (60...180).contains(firstClaim.count) { return firstClaim }
        }
        return safe
    }

    static func priorHeading(_ topic: String, before excerpt: String, in transcript: String) -> String? {
        guard !topic.isEmpty, !excerpt.contains(topic),
              let source = transcript.range(of: excerpt),
              let heading = transcript.range(of: topic, options: .backwards,
                                             range: transcript.startIndex..<source.lowerBound),
              transcript.distance(from: heading.upperBound, to: source.lowerBound) <= 500 else { return nil }
        return topic
    }

    static func literalSubject(in evidence: String) -> String? {
        guard let boundary = evidence.range(of: #"(?:について|というのは|では|は)"#, options: .regularExpression) else { return nil }
        let subject = String(evidence[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(subject.count), !SafetyPolicy.isSensitive(subject),
              subject.range(of: #"[一-龯々ァ-ヶA-Za-z0-9]"#, options: .regularExpression) != nil,
              !subject.contains("。"), !subject.contains("、"),
              !["それ", "その", "この", "あの", "そして", "また"].contains(where: subject.hasPrefix) else { return nil }
        return subject
    }

    /// Use only a complete current claim, without padding or unrelated neighboring anecdotes.
    /// This is a candidate, not a grounding bypass; it still needs semantic and safety review.
    static func extractivePost(from evidence: String, topic: String) -> String? {
        guard let prefix = shareablePrefix(evidence),
              let end = prefix.firstIndex(of: "。") else { return nil }
        let claim = String(prefix[..<end]).replacingOccurrences(of: "\n", with: "")
        guard !topic.isEmpty, SafetyPolicy.anchorsSupported(topic: topic, summary: "", evidence: claim),
              let subject = literalSubject(in: claim) else { return nil }
        if ["よね", "ですね", "なんですけど"].contains(where: claim.hasSuffix) {
            let quote = "「" + claim + "」と話していたよ。"
            if (80...140).contains(quote.count) { return SafetyPolicy.normalizeSummary(quote) }
        }
        var candidate = claim + "という話をしていたよ。"
        if candidate.count < 80 {
            candidate = subject + "について話しているよ。" + candidate
        }
        guard (80...140).contains(candidate.count) else { return nil }
        return SafetyPolicy.normalizeSummary(candidate)
    }

    /// A quoted fallback adds only the fixed hearsay suffix to one exact, complete
    /// current-transcript sentence. It makes no semantic inference about that sentence.
    static func isVerbatimPost(_ post: String, evidence: String, topic: String) -> Bool {
        let suffix = "」と話していたよ。"
        guard post.hasPrefix("「"), post.hasSuffix(suffix),
              let prefix = shareablePrefix(evidence), let end = prefix.firstIndex(of: "。"),
              !SafetyPolicy.isSensitive(post), !SafetyPolicy.containsUnclearSpeech(post),
              SafetyPolicy.normalizeSummary(post) == post else { return false }
        let quoted = String(post.dropFirst().dropLast(suffix.count))
        let original = String(prefix[..<end]).replacingOccurrences(of: "\n", with: "")
        return quoted == original &&
            SafetyPolicy.anchorsSupported(topic: topic, summary: post, evidence: evidence)
    }

    /// A grounded fallback when the model's copied excerpt is malformed. This only picks
    /// a literal current-transcript window; downstream anchor and semantic checks still apply.
    static func relevantExcerpt(for summary: String, from transcript: String) -> String? {
        let pattern = #"[一-龯]{2,}|[ァ-ヶー]{3,}|[a-zA-Z]{3,}|[0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern), transcript.count <= 6000 else { return nil }
        let tokens = regex.matches(in: summary, range: NSRange(summary.startIndex..., in: summary))
            .compactMap { Range($0.range, in: summary).map { String(summary[$0]) } }
        var best: (score: Int, excerpt: String)?
        for token in tokens {
            guard let range = transcript.range(of: token) else { continue }
            let before = min(120, transcript.distance(from: transcript.startIndex, to: range.lowerBound))
            let lower = transcript.index(range.lowerBound, offsetBy: -before)
            let prior = transcript[lower..<range.lowerBound]
            let start = prior.lastIndex(where: { "。！？\n".contains($0) }).map { transcript.index(after: $0) } ?? lower
            let end = transcript.index(start, offsetBy: min(240, transcript.distance(from: start, to: transcript.endIndex)))
            let excerpt = String(transcript[start..<end])
            let score = tokens.filter(excerpt.contains).count
            if excerpt.count >= 20 && score > (best?.score ?? 0) { best = (score, excerpt) }
        }
        return best?.excerpt
    }

    static func extractiveSummary(from excerpt: String, relatedTo draft: String) -> String? {
        let sentences = excerpt.split(whereSeparator: { "。！？\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let regex = try? NSRegularExpression(pattern: #"[一-龯]{2,}|[ァ-ヶー]{3,}|[a-zA-Z]{3,}|[0-9]+"#) else { return nil }
        let tokens = regex.matches(in: draft, range: NSRange(draft.startIndex..., in: draft))
            .compactMap { Range($0.range, in: draft).map { String(draft[$0]) } }
        guard !tokens.isEmpty else { return nil }
        let weakStart = ["そして", "それ", "その", "この", "あの", "また", "しかし", "だから", "そこ", "こちら"]
        let ranked = sentences.enumerated().compactMap { index, sentence -> (Int, String, Int)? in
            guard (8...139).contains(sentence.count) else { return nil }
            let overlap = tokens.filter(sentence.contains).count
            guard overlap > 0 else { return nil }
            let weak = weakStart.contains(where: sentence.hasPrefix)
            if (weak || sentence.count < 20), index > 0 {
                let joined = sentences[index - 1] + "。" + sentence + "。"
                if joined.count <= 140 { return (index, joined, overlap + 1) }
            }
            return (index, sentence + "。", overlap - (weak || sentence.count < 20 ? 2 : 0))
        }.sorted { $0.2 > $1.2 }
        guard let best = ranked.first, best.2 > 0 else { return nil }
        if best.1.count < 60, best.1 == sentences[best.0] + "。" {
            for neighbor in [best.0 - 1, best.0 + 1] where sentences.indices.contains(neighbor) {
                let joined = neighbor < best.0
                    ? sentences[neighbor] + "。" + sentences[best.0] + "。"
                    : sentences[best.0] + "。" + sentences[neighbor] + "。"
                if (60...140).contains(joined.count) { return joined }
            }
        }
        return best.1
    }

    /// Repair a short memo with no clear subject by copying one continuous, nearby span.
    /// The current transcript must itself name the subject near the model's evidence.
    static func contextualInternalSummary(from transcript: String, evidence: String, draft: String,
                                          explicitTopic: String) -> String? {
        let topic = explicitTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let weakStart = ["それ", "その", "この", "あの", "そして", "なぜ", "だから", "いろんな", "様々"]
        guard draft.count < 60, !topic.isEmpty, topic.count <= 40,
              (!draft.contains(topic) || weakStart.contains(where: draft.hasPrefix)),
              !SafetyPolicy.isSensitive(topic), !SafetyPolicy.isSensitive(evidence),
              let evidenceRange = transcript.range(of: evidence), transcript.count <= 6000 else { return nil }
        let before = min(120, transcript.distance(from: transcript.startIndex, to: evidenceRange.lowerBound))
        let searchStart = transcript.index(evidenceRange.lowerBound, offsetBy: -before)
        let topicAtEvidenceStart = transcript[evidenceRange.lowerBound...].hasPrefix(topic)
            ? evidenceRange.lowerBound..<transcript.index(evidenceRange.lowerBound, offsetBy: topic.count) : nil
        let topicRange = topicAtEvidenceStart
            ?? transcript.range(of: topic, options: .backwards, range: searchStart..<evidenceRange.lowerBound)
        guard let topicRange,
              transcript.distance(from: topicRange.lowerBound, to: evidenceRange.lowerBound) <= 120 else { return nil }
        let start = topicRange.lowerBound
        let maxEnd = transcript.index(start, offsetBy: min(140, transcript.distance(from: start, to: transcript.endIndex)))
        let anchorEnd = transcript.index(evidenceRange.lowerBound,
                                         offsetBy: min(12, transcript.distance(from: evidenceRange.lowerBound, to: evidenceRange.upperBound)))
        guard anchorEnd <= maxEnd else { return nil }
        var best: String?
        var cursor = start
        while cursor < maxEnd {
            cursor = transcript.index(after: cursor)
            guard "。！？\n".contains(transcript[transcript.index(before: cursor)]), cursor >= anchorEnd else { continue }
            let candidate = String(transcript[start..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (60...140).contains(candidate.count) { best = candidate }
        }
        return best
    }

    static func excerpt(_ quote: String, from transcript: String) -> String? {
        guard (20...240).contains(quote.count) else { return nil }
        if let exact = transcript.range(of: quote) { return completed(transcript, range: exact) }

        let query = characters(quote)
        guard query.values.count >= 16 else { return nil }
        let source = characters(transcript)
        let n = source.values.count, m = query.values.count
        guard n >= m / 2, n <= 6000 else { return nil }

        // Approximate substring matching: the empty query may start at any source position.
        var previous = Array(repeating: 0, count: n + 1)
        var starts = Array(0...n)
        for i in 1...m {
            var current = Array(repeating: 0, count: n + 1)
            var nextStarts = Array(repeating: 0, count: n + 1)
            current[0] = i
            for j in 1...n {
                var best = previous[j - 1] + (query.values[i - 1] == source.values[j - 1] ? 0 : 1)
                var start = starts[j - 1]
                if current[j - 1] + 1 < best { best = current[j - 1] + 1; start = nextStarts[j - 1] }
                if previous[j] + 1 < best { best = previous[j] + 1; start = starts[j] }
                current[j] = best
                nextStarts[j] = start
            }
            previous = current
            starts = nextStarts
        }

        var bestEnd = 0, bestCost = Int.max
        for end in 1...n {
            let span = end - starts[end]
            guard span >= m * 3 / 4, span <= m * 5 / 4 else { continue }
            if previous[end] < bestCost { bestCost = previous[end]; bestEnd = end }
        }
        guard bestEnd > 0, Double(bestCost) / Double(m) <= 0.12 else { return nil }
        let start = source.offsets[starts[bestEnd]]
        let end = transcript.index(after: source.offsets[bestEnd - 1])
        return completed(transcript, range: start..<end)
    }

    private static func completed(_ transcript: String, range: Range<String.Index>) -> String {
        let start = range.lowerBound
        var end = range.upperBound
        let excerpt = String(transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper's line breaks often split a clause immediately after a particle.
        // Include the following line so the selected evidence contains its predicate.
        if ["が", "は", "を", "に", "で", "と", "ので", "けど", "というのが"].contains(where: excerpt.hasSuffix),
           end < transcript.endIndex {
            var next = end
            while next < transcript.endIndex, transcript[next].isWhitespace { next = transcript.index(after: next) }
            if next < transcript.endIndex {
                var boundary = next
                while boundary < transcript.endIndex, transcript[boundary] != "\n", transcript[boundary] != "。" {
                    boundary = transcript.index(after: boundary)
                }
                if boundary < transcript.endIndex, transcript[boundary] == "。" { boundary = transcript.index(after: boundary) }
                if transcript[start..<boundary].count <= 240 { end = boundary }
            }
        }
        return String(transcript[start..<end])
    }

    private static func characters(_ text: String) -> (values: [Character], offsets: [String.Index]) {
        var values: [Character] = [], offsets: [String.Index] = []
        for index in text.indices {
            let normalized = String(text[index]).precomposedStringWithCompatibilityMapping.lowercased()
            for character in normalized where character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                values.append(character)
                offsets.append(index)
            }
        }
        return (values, offsets)
    }
}
