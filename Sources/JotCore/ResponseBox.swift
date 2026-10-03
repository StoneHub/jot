import Foundation
import Darwin

final class ResponseBox: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock(); ready.signal() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
