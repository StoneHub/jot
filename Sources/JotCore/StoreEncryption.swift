import Foundation
import SQLCipher

/// Turns the plaintext database earlier builds wrote (formats 7 and 8) into an encrypted one in the same place, once.
/// SQLCipher's export copies every table with its rowids, every index and trigger, and the feed's AUTOINCREMENT
/// counter, so cursors agents hold stay valid. The format is carried over unchanged and `TranscriptStore` then
/// applies its usual 7 → 8 step and commits format 9. Nothing is deleted until the encrypted copy has been counted.
enum StoreEncryption {
    static let plaintextHeader = Data("SQLite format 3\0".utf8)
    static let workSuffix = ".encrypting"

    /// True when the file starts with SQLite's plaintext header. An encrypted file, an empty file and garbage do not.
    static func isPlaintext(_ url: URL) throws -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw StoreError.database("Could not read the transcript database") }
        defer { try? handle.close() }
        return try handle.read(upToCount: plaintextHeader.count) == plaintextHeader
    }

    /// Refuses a format no build of this line wrote, over a read-only connection, before anything is written.
    static func encrypt(_ url: URL, key: StoreKey) throws {
        let version: Int64
        do {
            let inspection = try SQLiteConnection(url: url, key: nil, readOnly: true)
            defer { inspection.close() }
            version = try inspection.integer("PRAGMA user_version")
            let empty = try inspection.integer("SELECT COUNT(*) FROM sqlite_master") == 0
            guard empty || TranscriptStore.plaintextFormats.contains(version) else { throw TranscriptStore.unsupported(version) }
        }
        let work = URL(fileURLWithPath: url.path + workSuffix)
        removeDatabaseFiles(at: work)
        let expected: [String: Int64]
        do {
            // Writable: an attached database takes the connection's own access, and the export writes to it.
            let source = try SQLiteConnection(url: url, key: nil)
            defer { source.close() }
            expected = try source.locked { try tableCounts(source) }
            // The key is bound, not quoted: SQLCipher reads `x'…'` from the value itself, and this build rejects double-quoted literals in expressions.
            let attach = try source.prepare("ATTACH DATABASE ? AS encrypted KEY ?")
            defer { sqlite3_finalize(attach) }
            source.bind(work.path, to: 1, in: attach); source.bind(key.rawLiteral, to: 2, in: attach)
            try source.finish(attach)
            try source.execute("SELECT sqlcipher_export('encrypted')")
            try source.execute("PRAGMA encrypted.user_version = \(version)")
            try source.execute("DETACH DATABASE encrypted")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: work.path)
        do {
            let check = try SQLiteConnection(url: work, key: key, readOnly: true)
            defer { check.close() }
            let copied = try check.locked { try tableCounts(check) }
            guard copied == expected, try check.integer("PRAGMA user_version") == version else {
                removeDatabaseFiles(at: work)
                throw StoreError.database("The encrypted copy of saved history did not match the original, so the original was kept.")
            }
        }
        // The plaintext file's journal belongs to the file being replaced; its content was read above.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: work, backupItemName: nil, options: [])
        for suffix in ["-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// Rows per table, from the schema. Caller holds the lock.
    static func tableCounts(_ db: SQLiteConnection) throws -> [String: Int64] {
        let stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let name = db.column(stmt, 0) else { throw db.error() }
            names.append(name)
        }
        var counts: [String: Int64] = [:]
        for name in names { counts[name] = try db.integer("SELECT COUNT(*) FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"") }
        return counts
    }

    static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
