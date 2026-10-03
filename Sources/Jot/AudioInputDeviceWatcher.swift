import Foundation
import CoreAudio
import JotCore

/// Calls back on the main queue whenever the input device list or the macOS default input changes.
final class AudioInputDeviceWatcher {
    private let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    private let listener: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @MainActor () -> Void) {
        listener = { _, _ in MainActor.assumeIsolated(onChange) }
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func stop() {
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
