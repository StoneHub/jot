import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import JotCore

/// Audio callback owns resampling; only a bounded 8-second RAM queue crosses to the controller.
/// What the service needs from a microphone, so checks can feed synthetic audio and failures without Core Audio.
protocol MicrophoneSource: AnyObject {
    var running: Bool { get }
    var bufferedSampleCount: Int { get }
    func setInput(uid: String?) throws
    func setInputForNextStart(uid: String?)
    func shouldIgnoreConfigurationChange() -> Bool
    func start() throws
    func stop()
    func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float)
}

final class MicrophoneCapture: MicrophoneSource, @unchecked Sendable {
    private let lock = NSLock()
    private var engine = AVAudioEngine()
    private let callbacks = DispatchGroup()
    private var pending: [Float] = []
    private var tapInstalled = false
    private var dropped = 0
    private var lastAudio = Date.distantPast
    private var rms: Float = 0
    private var selectedInputUID: String?
    private var configurationChangeFilter = AudioConfigurationChangeFilter()
    private static let queueLimit = AudioClock.samples(seconds: 8)
    var running: Bool { engine.isRunning }

    func setInput(uid: String?) throws {
        guard !engine.isRunning else { throw JotError.message("Pause capture before changing the microphone.") }
        selectedInputUID = uid
    }

    /// Device arrivals and removals can land while the engine runs; the running engine is left alone and start() opens this device next time.
    func setInputForNextStart(uid: String?) {
        selectedInputUID = uid
    }

    func shouldIgnoreConfigurationChange() -> Bool {
        configurationChangeFilter.shouldIgnore(at: ProcessInfo.processInfo.systemUptime)
    }

    func start() throws {
        guard !engine.isRunning else { return }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false; callbacks.wait() }
        // A fresh input node follows the current system default when no explicit device is selected.
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let selectedInputUID {
            guard let selectedDevice = AudioInputDevice.deviceID(for: selectedInputUID) else {
                throw JotError.message("The selected microphone is no longer available. Choose System Default.")
            }
            guard let unit = input.audioUnit else { throw JotError.message("No usable microphone input.") }
            var device = selectedDevice
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr else {
                configurationChangeFilter.cancelExpectedChange()
                throw JotError.message("Jot could not select the chosen microphone.")
            }
        }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioClock.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw JotError.message("No usable microphone input. Check the macOS input device.")
        }
        lock.lock(); pending.removeAll(); dropped = 0; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            self.callbacks.enter()
            defer { self.callbacks.leave() }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Double(AudioClock.sampleRate) / source.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            self.accept(samples)
        }
        tapInstalled = true
        do { engine.prepare(); try engine.start() }
        catch { input.removeTap(onBus: 0); tapInstalled = false; configurationChangeFilter.cancelExpectedChange(); throw error }
        // The controller handles our own selection notification only after this returns, so the ignore window starts once the engine is up, not before a slow USB device finishes starting.
        if selectedInputUID != nil { configurationChangeFilter.expectSelectionChange(at: ProcessInfo.processInfo.systemUptime) }
    }

    private func accept(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        lastAudio = Date()
        rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        pending.append(contentsOf: samples)
        if pending.count > Self.queueLimit { let excess = pending.count - Self.queueLimit; pending.removeFirst(excess); dropped += excess }
    }

    var bufferedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }; return pending.count
    }

    func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, dropped, lastAudio, rms)
        pending = []; dropped = 0
        return result
    }

    func discardBufferedAudio() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(keepingCapacity: false); dropped = 0; rms = 0
    }

    func stop() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        callbacks.wait()
    }
}
