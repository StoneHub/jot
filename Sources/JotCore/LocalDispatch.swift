import Foundation

/// One decoded socket request. `@unchecked` because its parameters are `JSONSerialization` values.
public struct LocalRequest: @unchecked Sendable {
    public let method: LocalMethod
    public let params: [String: Any]

    public init(method: LocalMethod, params: [String: Any] = [:]) { self.method = method; self.params = params }

    /// Page size and start for the list methods.
    public var limit: Int { params["limit"] as? Int ?? 50 }
    public var offset: Int { params["offset"] as? Int ?? 0 }
}

/// The socket's request and reply framing, apart from what each method does. A reply is
/// `{"ok": true, "result": …}` with sorted keys, or `{"ok": false, "error": "…"}`.
public enum LocalDispatch {
    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// On the main actor, like the service that answers: results are `JSONSerialization` values and never cross actors.
    @MainActor
    public static func handle(_ data: Data, respond: @MainActor (LocalRequest) async throws -> Any) async -> Data {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = request["method"] as? String else { throw Refusal("Invalid request") }
            guard let method = LocalMethod(rawValue: name) else { throw Refusal("Unknown method: \(name)") }
            let result = try await respond(LocalRequest(method: method, params: request["params"] as? [String: Any] ?? [:]))
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])) ?? Data()
        }
    }
}
