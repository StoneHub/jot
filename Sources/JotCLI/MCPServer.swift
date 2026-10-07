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
        var pending = Data()
        while true {
            // read(upToCount:) can wait to fill a buffer on pipes; POSIX read returns available bytes.
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if frame.count > 1_048_576 { try emit(error(id: NSNull(), code: -32600, message: "Request exceeds 1 MiB limit")); continue }
                if frame.isEmpty { continue }
                try process(frame)
            }
            guard pending.count <= 1_048_576 else { throw CLIError.usage("MCP request exceeds 1 MiB limit") }
        }
        if !pending.isEmpty { FileHandle.standardError.write(Data("jot mcp: discarded incomplete final frame\n".utf8)) }
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
                ["name": tool.name, "description": tool.description, "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required, "additionalProperties": false], "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": tool.method == "people.forget", "openWorldHint": tool.method == "models.prepare"]]
            }
            try emit(result(id: id, value: ["tools": list]))
        case "tools/call":
            guard let name = params["name"] as? String, let tool = MCPTool.catalog.first(where: { $0.name == name }) else { try emit(error(id: id, code: -32602, message: "Unknown tool")); return }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                try tool.validate(arguments: arguments)
                let response = try self.request(tool.method, arguments)
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
