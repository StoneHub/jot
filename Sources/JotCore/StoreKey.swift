import Foundation

/// The 32 bytes that unlock the transcript database. The app keeps its key in the login keychain (`StoreKeyStore`).
/// Scratch stores (tests, `jot lab`, the recovery checks) use `scratch`, made once per process, so their files are
/// unreadable once that process ends. Never pass `scratch` for `JotPaths.directory`.
public struct StoreKey: Sendable, Equatable {
    public static let byteCount = 32
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw StoreError.invalid("A history key is \(Self.byteCount) bytes, not \(bytes.count)") }
        self.bytes = bytes
    }

    /// A key as Settings shows it: 64 hexadecimal digits, with any spaces or dashes between groups ignored.
    public init(hex: String) throws {
        let digits = hex.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == Self.byteCount * 2, digits.allSatisfy(\.isHexDigit) else {
            throw StoreError.invalid("A history key is \(Self.byteCount * 2) hexadecimal digits")
        }
        var bytes = Data(capacity: Self.byteCount)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        try self.init(bytes: bytes)
    }

    public static func random() -> StoreKey {
        try! StoreKey(bytes: Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// One key for the life of this process, for stores whose directory is discarded afterwards.
    public static let scratch = random()

    /// The key for a person to copy: 64 digits in groups of four.
    public var hex: String {
        let digits = rawHex
        return stride(from: 0, to: digits.count, by: 4).map { start in
            let lower = digits.index(digits.startIndex, offsetBy: start)
            return String(digits[lower..<digits.index(lower, offsetBy: 4)])
        }.joined(separator: " ")
    }

    var rawHex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// SQLCipher takes `x'…'` as raw key material, so opening derives nothing and takes no measurable time.
    var rawLiteral: String { "x'\(rawHex)'" }
    /// The first statement on every connection. A pragma value is a token, so the double quotes are fine here where an expression could not have them.
    var keyStatement: String { "PRAGMA key = \"\(rawLiteral)\"" }
}
