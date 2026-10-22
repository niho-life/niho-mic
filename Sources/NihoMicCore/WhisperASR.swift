import Foundation

public enum ASREngine: String, Sendable {
    case apple
    case whisper
}

public enum WhisperASR {
    public static func modelURL(root: URL) -> URL {
        root.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
    }

    public static func executableURL() -> URL? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("whisper-cli") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func requireReady(store: PrivateStore) throws {
        guard executableURL() != nil else { throw MicError.whisperUnavailable }
        let model = modelURL(root: store.root)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: model.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == 574_041_195 else { throw MicError.whisperModelMissing }
        try store.secure(model)
    }

    public static func transcribe(_ input: URL, store: PrivateStore) async throws -> String {
        try requireReady(store: store)
        guard let executable = executableURL() else { throw MicError.whisperUnavailable }
        let token = UUID().uuidString.lowercased()
        let wave = store.audioDirectory.appendingPathComponent("whisper-\(token).wav")
        let outputBase = store.transcriptDirectory.appendingPathComponent("whisper-\(token)")
        let output = outputBase.appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: wave)
            try? FileManager.default.removeItem(at: output)
        }
        // whisper-cli accepts 16 kHz mono PCM WAV. Keep conversion and raw output in the private store.
        try await run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, wave.path])
        try store.secure(wave)
        try await run(executable, ["-m", modelURL(root: store.root).path, "-l", "ja", "-otxt", "-of", outputBase.path, wave.path])
        try store.secure(output)
        guard let text = try? String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MicError.transcriptionFailed
        }
        return text
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw MicError.transcriptionFailed }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: MicError.transcriptionFailed)
                }
            }
        }
    }
}
