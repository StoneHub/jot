import Foundation

/// Settings that live only in this process. A defaults suite would leave a file in ~/Library/Preferences behind every lab run,
/// even after its domain is removed. The typed getters (`bool(forKey:)` and the rest) read through `object(forKey:)`.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}
