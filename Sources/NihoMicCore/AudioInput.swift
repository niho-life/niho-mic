import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

public struct InputDevice {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

public enum AudioInputs {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var property = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { throw MicError.inputUnavailable }
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr, let value else { throw MicError.inputUnavailable }
        return value.takeUnretainedValue() as String
    }
    public static func list() throws -> [InputDevice] {
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { throw MicError.inputUnavailable }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &devices) == noErr else { throw MicError.inputUnavailable }
        return try devices.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            return InputDevice(id: id, uid: try string(id, kAudioDevicePropertyDeviceUID), name: try string(id, kAudioObjectPropertyName))
        }
    }
    public static func selected(_ uid: String) throws -> InputDevice {
        guard let device = try list().first(where: { $0.uid == uid }), try uint(device.id, kAudioDevicePropertyDeviceIsAlive) == 1 else { throw MicError.inputUnavailable }
        return device
    }
    public static func defaultInput() throws -> AudioDeviceID { try uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) }
}

/// A continuous tap rotates files under a lock, so analysis does not stop the microphone.
public final class WindowRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let mutex = NSLock()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var failed = false
    private var frameCount: AVAudioFramePosition = 0
    private var accepting = false
    private var tapped = false
    private let directory: URL
    private let selected: InputDevice
    private let initialDefault: AudioDeviceID
    private var format: AVAudioFormat?
    private var inputInvalidated = false
    private var configurationObserver: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "life.niho.mic.input-watch")

    public init(uid: String, directory: URL) throws {
        selected = try AudioInputs.selected(uid)
        initialDefault = try AudioInputs.defaultInput()
        self.directory = directory
    }

    public func start() async throws {
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        guard permitted else { throw MicError.microphoneDenied }
        guard let unit = engine.inputNode.audioUnit else { throw MicError.inputUnavailable }
        var id = selected.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw MicError.inputUnavailable }
        try verify()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.inputUnavailable }
        self.format = format
        _ = try rotate()
        mutex.withLock { accepting = true }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.mutex.lock(); defer { self.mutex.unlock() }
            guard self.accepting, !self.failed else { return }
            do { try self.file?.write(from: buffer); self.frameCount += AVAudioFramePosition(buffer.frameLength) }
            catch { self.failed = true; self.accepting = false }
        }
        tapped = true
        do { engine.prepare(); try engine.start(); try watchInput(); try verify() }
        catch { _ = stop(); throw MicError.recordingFailed }
    }

    public func verify() throws {
        if mutex.withLock({ inputInvalidated }) { throw MicError.inputChanged }
        guard routeMatches(), (!tapped || engine.isRunning) else { fail(); throw MicError.inputChanged }
        mutex.lock(); let error = failed; mutex.unlock()
        if error { throw MicError.recordingFailed }
    }

    private func routeMatches() -> Bool {
        guard (try? AudioInputs.selected(selected.uid).id) == selected.id,
              (try? AudioInputs.defaultInput()) == initialDefault,
              let unit = engine.inputNode.audioUnit else { return false }
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &id, &size) == noErr && id == selected.id
    }

    private func fail() { mutex.lock(); accepting = false; mutex.unlock() }

    private func invalidateInput() {
        // CoreAudio may announce a configuration refresh without changing devices.
        // Query only CoreAudio here; AVAudioEngine is checked on the recorder loop.
        guard (try? AudioInputs.selected(selected.uid).id) != selected.id ||
              (try? AudioInputs.defaultInput()) != initialDefault else { return }
        mutex.withLock { inputInvalidated = true; accepting = false }
    }

    private func watchInput() throws {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.invalidateInput() }
        inputListener = listener
        var property = AudioInputs.address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, listenerQueue, listener) == noErr else { throw MicError.inputUnavailable }
        property = AudioInputs.address(kAudioDevicePropertyDeviceIsAlive)
        guard AudioObjectAddPropertyListenerBlock(selected.id, &property, listenerQueue, listener) == noErr else { throw MicError.inputUnavailable }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.invalidateInput() }
    }

    @discardableResult public func rotate() throws -> URL? {
        guard let format else { throw MicError.recordingFailed }
        let url = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".caf")
        let next = try AVAudioFile(forWriting: url, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        mutex.lock(); defer { mutex.unlock() }
        let previous = fileURL
        file = next; fileURL = url; frameCount = 0
        return previous
    }

    public func stop() -> URL? {
        mutex.lock(); accepting = false; mutex.unlock()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        if let listener = inputListener {
            var property = AudioInputs.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, listenerQueue, listener)
            property = AudioInputs.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(selected.id, &property, listenerQueue, listener)
            inputListener = nil
        }
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        mutex.lock(); defer { mutex.unlock() }
        file = nil
        let last = fileURL; fileURL = nil
        return last
    }
}

public final class StopFlag: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = false
    public init() {}
    public func stop() { mutex.lock(); value = true; mutex.unlock() }
    public var stopped: Bool { mutex.lock(); defer { mutex.unlock() }; return value }
}

public final class PendingCounter: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = 0
    public init() {}
    public var count: Int { mutex.withLock { value } }
    public func increment() { mutex.withLock { value += 1 } }
    public func decrement() { mutex.withLock { value -= 1 } }
}
