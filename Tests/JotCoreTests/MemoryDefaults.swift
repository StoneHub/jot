import Foundation

/// Preferences that live only in the test process. A UserDefaults suite leaves a plist in ~/Library/Preferences that the
/// preferences daemon keeps after its domain is removed, so every test run used to add files there.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    init() { super.init(suiteName: nil)! }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}
