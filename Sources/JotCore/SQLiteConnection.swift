import Foundation
import SQLite3

/// One connection to Jot's database file and the statement helpers TranscriptStore, SpeakerPassStore and PeopleStore share. WAL mode lets several connections use the file at once. Each connection serializes its own use through `locked`.
final class SQLiteConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens or creates the file, readable by this user only.
    init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open transcript database"
            sqlite3_close(db)
            throw StoreError.database(message)
        }
        handle = db
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// Safe to call twice; every later statement fails.
    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    /// One write transaction, rolled back when the body throws. Caller holds the lock.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func error() -> StoreError { .database(String(cString: sqlite3_errmsg(handle))) }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func finish(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    /// The first column of a one-row query, such as a PRAGMA or a COUNT.
    func integer(_ sql: String) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Rows the last statement changed.
    var changes: Int32 { sqlite3_changes(handle) }

    func bind(_ value: String?, to index: Int32, in stmt: OpaquePointer) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, transient) } else { sqlite3_bind_null(stmt, index) }
    }

    func bind(_ blob: Data, to index: Int32, in stmt: OpaquePointer) {
        blob.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(blob.count), transient) }
    }

    func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: bytes)
    }

    func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        sqlite3_column_blob(stmt, index).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, index))) } ?? Data()
    }
}
