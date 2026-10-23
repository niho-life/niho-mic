import Foundation
import CryptoKit
import Darwin

public struct LocalRecord: Codable, Sendable {
    public let segmentID: String
    public let generatedAt: Date
    public let audioEndedAt: Date
    public let speechEndedAt: Date?
    public let sessionID: String?
    public let decision: String
    public let topicKey: String
    public let text: String
    public let reason: String
    public init(segmentID: String, generatedAt: Date = Date(), audioEndedAt: Date, speechEndedAt: Date? = nil, sessionID: String? = nil,
                decision: String, topicKey: String = "", text: String = "", reason: String) {
        self.segmentID = segmentID; self.generatedAt = generatedAt; self.audioEndedAt = audioEndedAt
        self.speechEndedAt = speechEndedAt
        self.sessionID = sessionID
        self.decision = decision; self.topicKey = topicKey; self.text = text; self.reason = reason
    }
}

/// Ephemeral review data. It is kept beside the raw transcript and expires with it.
public struct ReviewTrace: Codable, Sendable {
    public let internalSummary: String?
    public let internalTopic: String?
    public let internalEvidence: String?
    public let internalReason: String?
    public let topicSourceSegmentID: String?
    public let topicSourceEvidence: String?
    public let selectionDecision: String?
    public let selectionReason: String?
    public let selectedTopic: String?
    public let selectionExplanation: String?
    public let selectionEvidence: String?
    public let candidateTopic: String
    public let candidateText: String
    public let normalizedText: String
    public let gateReason: String
    public init(internalSummary: String? = nil, internalTopic: String? = nil, internalEvidence: String? = nil, internalReason: String? = nil,
                topicSourceSegmentID: String? = nil, topicSourceEvidence: String? = nil,
                selectionDecision: String? = nil, selectionReason: String? = nil, selectedTopic: String? = nil, selectionExplanation: String? = nil, selectionEvidence: String? = nil,
                candidateTopic: String = "", candidateText: String = "", normalizedText: String = "", gateReason: String) {
        self.internalSummary = internalSummary; self.internalTopic = internalTopic
        self.internalEvidence = internalEvidence; self.internalReason = internalReason
        self.topicSourceSegmentID = topicSourceSegmentID; self.topicSourceEvidence = topicSourceEvidence
        self.selectionDecision = selectionDecision; self.selectionReason = selectionReason
        self.selectedTopic = selectedTopic; self.selectionExplanation = selectionExplanation
        self.selectionEvidence = selectionEvidence
        self.candidateTopic = candidateTopic; self.candidateText = candidateText
        self.normalizedText = normalizedText; self.gateReason = gateReason
    }
}

/// One process owns this store. A completed JSONL record is the durable deduplication receipt.
public final class PrivateStore {
    public let root: URL
    public let audioDirectory: URL
    public let transcriptDirectory: URL
    public let geminiScratchDirectory: URL
    private let logs: URL
    private var lockFD: Int32 = -1
    private let manager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL? = nil) throws {
        let base = try root ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("life.niho.mic", isDirectory: true)
        self.root = base
        audioDirectory = base.appendingPathComponent("audio", isDirectory: true)
        transcriptDirectory = base.appendingPathComponent("transcripts", isDirectory: true)
        geminiScratchDirectory = base.appendingPathComponent("gemini-scratch", isDirectory: true)
        logs = base.appendingPathComponent("logs", isDirectory: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        for directory in [base, audioDirectory, transcriptDirectory, geminiScratchDirectory, logs] {
            if manager.fileExists(atPath: directory.path) {
                let attributes = try manager.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw MicError.unsafeStorage }
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let lockURL = base.appendingPathComponent(".lock")
        lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw MicError.unsafeStorage }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); lockFD = -1; throw MicError.storageBusy }
        // No earlier process can still own this store. Remove interrupted CLI workspaces.
        for url in try manager.contentsOfDirectory(at: geminiScratchDirectory, includingPropertiesForKeys: nil) {
            try secure(url)
            try manager.removeItem(at: url)
        }
        try expire()
    }

    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }

    public func secure(_ url: URL) throws {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw MicError.unsafeStorage }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func expire(now: Date = Date()) throws {
        for (directory, lifetime) in [(audioDirectory, Retention.audio), (geminiScratchDirectory, Retention.audio), (transcriptDirectory, Retention.transcript)] {
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]) {
                try secure(url)
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard let date = attributes[.creationDate] as? Date ?? attributes[.modificationDate] as? Date else { throw MicError.unsafeStorage }
                if Retention.expired(createdAt: date, lifetime: lifetime, now: now) { try manager.removeItem(at: url) }
            }
        }
    }

    public func records() throws -> [LocalRecord] {
        var result: [LocalRecord] = []
        for url in try manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try secure(url)
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 0x0A) {
                guard let record = try? decoder.decode(LocalRecord.self, from: Data(line)),
                      ["publish", "skip"].contains(record.decision),
                      record.segmentID.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw MicError.corruptLog }
                result.append(record)
            }
        }
        return result
    }

    public func append(_ record: LocalRecord) throws {
        guard try !records().contains(where: { $0.segmentID == record.segmentID }) else { return }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        let url = logs.appendingPathComponent(formatter.string(from: record.generatedAt) + ".jsonl")
        var data = Data()
        if manager.fileExists(atPath: url.path) { try secure(url); data = try Data(contentsOf: url) }
        data.append(try encoder.encode(record)); data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try secure(url)
    }

    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func archive(_ source: URL, id: String, createdAt: Date = Date()) throws -> URL {
        let destination = audioDirectory.appendingPathComponent(id + ".caf")
        if !manager.fileExists(atPath: destination.path) {
            try manager.copyItem(at: source, to: destination)
            // Imported file timestamps must not extend retention on a later retry.
            try manager.setAttributes([.creationDate: createdAt, .modificationDate: createdAt], ofItemAtPath: destination.path)
        }
        try secure(destination)
        return destination
    }

    public func removeTemporaryAudio(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == audioDirectory.standardizedFileURL else { throw MicError.unsafeStorage }
        try secure(url)
        try manager.removeItem(at: url)
    }

    public func writeTranscript(_ text: String, id: String) throws {
        let url = transcriptDirectory.appendingPathComponent(id + ".txt")
        // A retry must not restart the retention clock.
        if !manager.fileExists(atPath: url.path) { try Data(text.utf8).write(to: url, options: .atomic) }
        try secure(url)
    }

    public func transcript(id: String) throws -> String? {
        let url = transcriptDirectory.appendingPathComponent(id + ".txt")
        guard manager.fileExists(atPath: url.path) else { return nil }
        try secure(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeReviewTrace(_ trace: ReviewTrace, id: String) throws {
        let url = transcriptDirectory.appendingPathComponent(id + ".review.json")
        // A retry must not restart the seven-day retention clock.
        if !manager.fileExists(atPath: url.path) { try encoder.encode(trace).write(to: url, options: .atomic) }
        try secure(url)
    }

    public func reviewTrace(id: String) throws -> ReviewTrace? {
        let url = transcriptDirectory.appendingPathComponent(id + ".review.json")
        guard manager.fileExists(atPath: url.path) else { return nil }
        try secure(url)
        return try decoder.decode(ReviewTrace.self, from: Data(contentsOf: url))
    }

    public func recentContext(before endedAt: Date, sessionID: String?, excluding id: String? = nil) throws -> [ContextEntry] {
        guard let sessionID else { return [] }
        let records = try records().filter { $0.sessionID == sessionID }
        let sessionSegmentIDs = Set(records.map(\.segmentID))
        let speechTimes = records.compactMap { record -> Date? in
            guard record.segmentID != id else { return nil }
            if let speech = record.speechEndedAt { return speech }
            if ["audio_too_short", "no_speech", "insufficient_speech", "low_speech_confidence"].contains(record.reason) { return nil }
            return record.audioEndedAt
        }
        guard let start = ContextWindow.continuityStart(speechTimes: speechTimes, at: endedAt) else { return [] }
        var entries: [ContextEntry] = []
        for record in records where record.segmentID != id
            && (record.speechEndedAt ?? record.audioEndedAt) <= endedAt
            && (record.speechEndedAt ?? record.audioEndedAt) >= start {
            guard let trace = try reviewTrace(id: record.segmentID),
                  let summary = trace.internalSummary, !summary.isEmpty,
                  let topic = trace.internalTopic, !topic.isEmpty else { continue }
            let citation: TopicCitation?
            if let sourceID = trace.topicSourceSegmentID, let source = trace.topicSourceEvidence,
               sourceID.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
               sessionSegmentIDs.contains(sourceID),
               source.contains(topic), source.count <= 240,
               let original = try transcript(id: sourceID), original.contains(source) {
                citation = TopicCitation(segmentID: sourceID, topic: topic, excerpt: source)
            } else { citation = nil }
            entries.append(ContextEntry(segmentID: record.segmentID, endedAt: record.speechEndedAt ?? record.audioEndedAt,
                                        topic: topic, summary: summary, topicCitation: citation))
        }
        return ContextWindow.recent(entries, at: endedAt, speechTimes: speechTimes)
    }

    public func pendingAudio() throws -> [URL] {
        let completed = Set(try records().map(\.segmentID))
        return try manager.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "caf" && !completed.contains($0.deletingPathExtension().lastPathComponent)
        }
    }

    public func deleteLogs() throws {
        for url in try manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil) where url.pathExtension == "jsonl" {
            try secure(url); try manager.removeItem(at: url)
        }
    }
}
