import Foundation

/// Resolve a nearly copied model quote back to an actual continuous transcript span.
/// A small spelling difference is allowed, but the returned evidence is always source text.
enum EvidenceMatcher {
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
