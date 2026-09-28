import Foundation
import CoreAudio
import JotCore

/// One input device as Core Audio reports it; the id is the persistent device UID.
struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    var automaticCandidate = true

    static func available() -> [Self] {
        deviceIDs().compactMap { id in
            guard hasInputStreams(id), let uid = CoreAudioProperties.string(id, kAudioDevicePropertyDeviceUID),
                  let name = CoreAudioProperties.string(id, kAudioObjectPropertyName) else { return nil }
            let transport: UInt32? = CoreAudioProperties.value(id, kAudioDevicePropertyTransportType)
            return Self(id: uid, name: name, automaticCandidate: transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultUID() -> String? {
        guard let id: AudioObjectID = CoreAudioProperties.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return CoreAudioProperties.string(id, kAudioDevicePropertyDeviceUID)
    }

    static func defaultName() -> String? {
        guard let id: AudioObjectID = CoreAudioProperties.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return CoreAudioProperties.string(id, kAudioObjectPropertyName)
    }

    static func deviceID(for uid: String) -> AudioObjectID? {
        deviceIDs().first { CoreAudioProperties.string($0, kAudioDevicePropertyDeviceUID) == uid && hasInputStreams($0) }
    }

    private static func deviceIDs() -> [AudioObjectID] {
        CoreAudioProperties.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        (CoreAudioProperties.dataSize(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput) ?? 0) > 0
    }
}

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
