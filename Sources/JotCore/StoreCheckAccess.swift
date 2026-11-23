import Foundation
import SQLCipher

/// Raw statements against a store's database for the recovery checks: a trigger that makes a delete fail, a table
/// renamed away. Each call opens a connection of its own with the store's key and closes it again.
public enum StoreCheckAccess {
    public static func execute(_ sql: String, in directory: URL, key: StoreKey) throws {
        let db = try SQLiteConnection(url: directory.appendingPathComponent("transcripts.sqlite3"), key: key)
        defer { db.close() }
        try db.locked { try db.execute(sql) }
    }
}
