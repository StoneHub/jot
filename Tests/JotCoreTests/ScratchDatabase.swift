import Foundation
import SQLCipher
@testable import JotCore

/// Opens a scratch store's encrypted file the way the tests used to open the plaintext one, keyed with the key every scratch store in this process shares.
func sqlite3_open_scratch(_ path: String, _ db: inout OpaquePointer?) -> Int32 {
    let status = sqlite3_open(path, &db)
    guard status == SQLITE_OK else { return status }
    return sqlite3_exec(db, StoreKey.scratch.keyStatement, nil, nil, nil)
}
