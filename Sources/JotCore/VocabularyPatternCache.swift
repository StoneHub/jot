import Foundation

/// NSCache synchronizes accesses internally. Entries are immutable compiled expressions;
/// no mutable cache or configuration escapes this owner after initialization.
final class VocabularyPatternCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSRegularExpression>()

    init() { cache.countLimit = 512 }
    func object(forKey key: NSString) -> NSRegularExpression? { cache.object(forKey: key) }
    func setObject(_ object: NSRegularExpression, forKey key: NSString) { cache.setObject(object, forKey: key) }
}
