import Foundation
import Darwin
import JotCore

/// MCP stdio transport uses newline-delimited JSON; stdout contains protocol frames only.
struct MCPServer {
    var request: (String, [String: Any]) throws -> Data = { method, params in
        try LocalServiceClient().request(method: method, params: params)
    }
    var writeFrame: (Data) throws -> Void = { FileHandle.standardOutput.write($0) }
    private static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    func run() throws {
        var lines = LineReader()
        while true {
            // read(upToCount:) can wait to fill a buffer on pipes; POSIX read returns available bytes.
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            for line in lines.append(bytes.prefix(count)) {
                switch line {
                case .oversized: try emit(error(id: NSNull(), code: -32600, message: "Request exceeds 1 MiB limit"))
                case .frame(let frame): try process(frame)
                }
            }
        }
        if lines.hasPartialLine { FileHandle.standardError.write(Data("jot mcp: discarded incomplete final frame\n".utf8)) }
    }

    /// Splits stdin into newline-delimited frames. A line over the limit is dropped as it arrives rather than buffered, and reported once its newline comes, so one oversized request is refused without ending the session.
    struct LineReader {
        enum Line: Equatable { case frame(Data), oversized }
        static let limit = 1_048_576
        private var pending = Data()
        private var discarding = false

        var hasPartialLine: Bool { discarding || !pending.isEmpty }

        mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> [Line] where Bytes.Element == UInt8 {
            pending.append(contentsOf: bytes)
            var lines: [Line] = []
            while let newline = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if discarding || frame.count > Self.limit { lines.append(.oversized) }
                else if !frame.isEmpty { lines.append(.frame(frame)) }
                discarding = false
            }
            if pending.count > Self.limit { pending.removeAll(); discarding = true }
            return lines
        }
    }

    func process(_ data: Data) throws {
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data) }
        catch { try emit(self.error(id: NSNull(), code: -32700, message: "Parse error")); return }
        guard let request = decoded as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            try emit(error(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request")); return
        }
        guard let id = request["id"] else { return } // notifications have no response
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            try emit(result(id: id, value: ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "jot", "version": JotVersion.current], "instructions": MCPInstructions.text]))
        case "ping": try emit(result(id: id, value: [:]))
        case "tools/list":
            let list: [[String: Any]] = MCPTool.catalog.map { tool in
                ["name": tool.name, "description": tool.description, "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required, "additionalProperties": false], "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": [LocalMethod.peopleForget, .vocabularyRemove].contains(tool.method), "openWorldHint": [LocalMethod.modelsPrepare, .sessionsNotes].contains(tool.method)]]
            }
            try emit(result(id: id, value: ["tools": list]))
        case "tools/call":
            guard let name = params["name"] as? String, let tool = MCPTool.catalog.first(where: { $0.name == name }) else { try emit(error(id: id, code: -32602, message: "Unknown tool")); return }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                try tool.validate(arguments: arguments)
                let response = try self.request(tool.method.rawValue, arguments)
                let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                try emit(result(id: id, value: ["content": [["type": "text", "text": String(decoding: response, as: UTF8.self)]], "isError": object?["ok"] as? Bool == false]))
            } catch {
                try emit(result(id: id, value: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]))
            }
        default: try emit(error(id: id, code: -32601, message: "Method not found"))
        }
    }

    private func result(id: Any, value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
    private func error(id: Any, code: Int, message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
    private func emit(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10)
        try writeFrame(data)
    }
}
