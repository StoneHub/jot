import CoreAudio
import Foundation

/// A short-lived mute lease on the built-in speaker device, never the system volume.
@MainActor
public final class DictationSpeakerMute {
    private var device: AudioObjectID?
    private var timer: Timer?

    public init() {}

    public func begin() {
        guard device == nil,
              let output = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              read(output, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn,
              isSpeaker(output), read(output, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) == 0,
              setMute(output, 1) else { return }
        device = output
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let device = self.device else { return }
                if self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) != device {
                    self.end()
                } else if self.read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) != 1 {
                    // The user changed the mute state. Relinquish ownership.
                    self.device = nil
                    self.timer?.invalidate(); self.timer = nil
                }
            }
        }
    }

    public func end() {
        timer?.invalidate(); timer = nil
        guard let device else { return }
        self.device = nil
        if read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) == 1 {
            _ = setMute(device, 0)
        }
    }

    private func isSpeaker(_ device: AudioObjectID) -> Bool {
        // Apple's built-in driver identifies the internal speaker source as 'ispk'.
        // Check this first: some built-in streams report USB terminal codes instead
        // of Core Audio's generic 'spkr' constant. A headphone source must not match.
        if let source = read(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) {
            return source == 0x6973706B
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return false }
        return streams.contains { read($0, kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeSpeaker }
    }

    private func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func setMute(_ device: AudioObjectID, _ value: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
