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
        let streams: [AudioObjectID] = CoreAudioProperties.array(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        return streams.contains { read($0, kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeSpeaker }
    }

    private func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        CoreAudioProperties.value(object, selector, scope: scope)
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
