import Foundation
import Darwin

public enum ProcessingStage: String, Sendable {
    case idle, audioCheck, transcribing, summarizing
}

/// Small, private heartbeat. The monitor reads it without taking the recording store's lock.
public struct RecordingStatus: Codable, Sendable {
    public let pid: Int32
    public let sessionID: String
    public let inputUID: String
    public let startedAt: Date
    public var updatedAt: Date
    public var segmentStartedAt: Date
    public let segmentSeconds: Double
    public var recording = false
    public var captureMode: String?
    public var stage = "idle"
    public var processingSegmentID: String?
    public var pendingSegments = 0

    public var isCurrentProcess: Bool {
        let age = Date().timeIntervalSince(updatedAt)
        return pid > 0 && (0..<8).contains(age) && kill(pid, 0) == 0
    }
    public var isLive: Bool { recording && isCurrentProcess }

    public init(pid: Int32, sessionID: String, inputUID: String, segmentSeconds: Double, now: Date = Date()) {
        self.pid = pid; self.sessionID = sessionID; self.inputUID = inputUID
        self.startedAt = now; self.updatedAt = now; self.segmentStartedAt = now
        self.segmentSeconds = segmentSeconds
        self.captureMode = "standby"
    }
}

public final class RecordingStatusWriter: @unchecked Sendable {
    private let store: PrivateStore
    private let url: URL
    private let lock = NSLock()
    private var status: RecordingStatus
    private var failure: Error?

    public init(store: PrivateStore, status: RecordingStatus) throws {
        self.store = store
        self.url = store.root.appendingPathComponent("recording-status.json")
        self.status = status
        try persist()
    }

    public func update(_ change: (inout RecordingStatus) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&status)
        status.updatedAt = Date()
        do { try persist() } catch { failure = error }
    }

    public func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
    }

    private func persist() throws {
        if FileManager.default.fileExists(atPath: url.path) { try store.secure(url) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(status).write(to: url, options: .atomic)
        try store.secure(url)
    }
}

public struct MonitorItem {
    public let record: LocalRecord
    public let transcript: String?
    public let trace: ReviewTrace?
}

public struct MonitorSnapshot {
    public let status: RecordingStatus?
    public let items: [MonitorItem]
    public let processingTranscript: String?

    /// Read-only; never acquires the writer lock or extends data retention.
    public static func load(root: URL? = nil, latest: Int = 3) throws -> MonitorSnapshot {
        let manager = FileManager.default
        let base = try root ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: false)
            .appendingPathComponent("life.niho.mic", isDirectory: true)
        guard manager.fileExists(atPath: base.path) else { return MonitorSnapshot(status: nil, items: [], processingTranscript: nil) }
        try verifyDirectory(base)
        let logs = base.appendingPathComponent("logs", isDirectory: true)
        let transcripts = base.appendingPathComponent("transcripts", isDirectory: true)
        try verifyDirectory(logs); try verifyDirectory(transcripts)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let status: RecordingStatus? = try read(base.appendingPathComponent("recording-status.json"), limit: 16_384)
            .flatMap { try decoder.decode(RecordingStatus.self, from: $0) }
        var records: [LocalRecord] = []
        for url in try manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try read(url, limit: 16_000_000) ?? Data()
            for line in data.split(separator: 0x0A) {
                guard let record = try? decoder.decode(LocalRecord.self, from: Data(line)),
                      ["publish", "skip"].contains(record.decision),
                      record.segmentID.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
                else { throw MicError.corruptLog }
                records.append(record)
            }
        }
        let selected = status?.isCurrentProcess == true ? records.filter { $0.sessionID == status?.sessionID } : records
        let items = try selected.suffix(max(1, min(latest, 50))).map { record in
            let transcript = try read(transcripts.appendingPathComponent(record.segmentID + ".txt"), limit: 64_000)
                .flatMap { String(data: $0, encoding: .utf8) }
            let trace = try read(transcripts.appendingPathComponent(record.segmentID + ".review.json"), limit: 64_000)
                .flatMap { try decoder.decode(ReviewTrace.self, from: $0) }
            return MonitorItem(record: record, transcript: transcript, trace: trace)
        }
        let currentID = status?.isCurrentProcess == true ? status?.processingSegmentID : nil
        let processingTranscript = try currentID.flatMap { id -> String? in
            guard id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
            return try read(transcripts.appendingPathComponent(id + ".txt"), limit: 64_000)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return MonitorSnapshot(status: status, items: items, processingTranscript: processingTranscript)
    }

    private static func verifyDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
        else { throw MicError.unsafeStorage }
    }

    private static func read(_ url: URL, limit: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= limit
        else { throw MicError.unsafeStorage }
        return try Data(contentsOf: url)
    }
}
