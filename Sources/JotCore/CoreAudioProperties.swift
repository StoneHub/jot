import CoreAudio
import Foundation

/// The few AudioObjectGetPropertyData shapes Jot reads, so callers never hand-roll addresses or ownership.
public enum CoreAudioProperties {
    public static func value<T: ExpressibleByIntegerLiteral>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? value : nil
    }

    public static func array<T: ExpressibleByIntegerLiteral>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var address = address(selector, scope)
        guard var size = dataSize(object, selector, scope: scope), size > 0 else { return [] }
        var result = [T](repeating: 0, count: Int(size) / MemoryLayout<T>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : []
    }

    /// Core Audio returns name and UID strings retained; takeRetainedValue consumes that +1 so nothing leaks.
    public static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var address = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    public static func dataSize(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        return size
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
