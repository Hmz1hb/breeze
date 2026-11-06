import CleanupAssistant
import CoreFoundation
import Darwin
import Foundation
import StorageCore

// A deliberately small, dependency-free MCP stdio server. It can read the
// opt-in snapshot and write proposals; it has no scanner or cleanup entry point.
private struct RPCError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

private struct MCPServer {
    private var initialized = false
    private let store = AssistantStore()

    private func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private func tool(_ name: String, _ description: String, _ input: [String: Any], readOnly: Bool = true) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": input,
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": false,
                         "idempotentHint": readOnly, "openWorldHint": false]]
    }

    private var tools: [[String: Any]] {
        let ids: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 8, "uniqueItems": true]
        return [
            tool("cleanup_summary", "Start here. Scan totals and cleanup opportunities grouped by kind, including devices, runtimes, installers and verified duplicates. No disk rescan.", schema()),
            tool("list_items", "Page through cleanup metadata, largest first. Defaults to opportunities including review/personal/permanent tradeoffs, not just rebuildable files. Details via inspect_items.", schema([
                "snapshotID": ["type": "string"],
                "scope": ["type": "string", "enum": ["opportunities", "suggested", "all"], "default": "opportunities"],
                "category": ["type": "string", "description": "Exact category name from summary."],
                "query": ["type": "string", "maxLength": 200],
                "offset": ["type": "integer", "minimum": 0, "default": 0],
                "limit": ["type": "integer", "minimum": 1, "maximum": 40, "default": 15]
            ], required: ["snapshotID"])),
            tool("inspect_items", "Bounded details for up to 8 IDs: dates, ownership, purpose, recovery and paths. Follow remainingIDs if present. Missing dates mean unknown.", schema([
                "snapshotID": ["type": "string"], "ids": ids
            ], required: ["snapshotID", "ids"])),
            tool("propose_cleanup", "Send a reasoned proposal to Breeze for human review. Does not select or remove files. Never execute filesystem commands to clean up.", schema([
                "snapshotID": ["type": "string"],
                "summary": ["type": "string", "minLength": 1, "maxLength": 1200],
                "items": ["type": "array", "minItems": 1, "maxItems": 200, "items": schema([
                    "id": ["type": "string"], "reason": ["type": "string", "minLength": 1, "maxLength": 600]
                ], required: ["id", "reason"])]
            ], required: ["snapshotID", "summary", "items"]), readOnly: false)
        ]
    }

    mutating func receive(_ data: Data) -> [String: Any]? {
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return self.error(nil, code: -32700, message: "Invalid JSON.") }
        guard let request = decoded as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return error(nil, code: -32600, message: "Expected a JSON-RPC 2.0 request.")
        }
        // Notifications and client responses have no response of their own.
        guard let id = request["id"] else { return nil }
        guard id is String || ((id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false) else {
            return error(nil, code: -32600, message: "Request ID must be a string or number.")
        }
        do {
            if let params = request["params"], !(params is [String: Any]) {
                throw RPCError(code: -32602, message: "Params must be an object.")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch method {
            case "initialize":
                guard params["protocolVersion"] is String else { throw RPCError(code: -32602, message: "Missing protocolVersion.") }
                initialized = true
                result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": ["listChanged": false]],
                          "serverInfo": ["name": "Breeze cleanup", "version": "1.0.0"],
                          "instructions": AssistantSnapshot.guidance]
            case "ping": result = [:]
            case "tools/list":
                try requireInitialized()
                result = ["tools": tools]
            case "tools/call":
                try requireInitialized()
                guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }),
                      params["arguments"] == nil || params["arguments"] is [String: Any] else {
                    throw RPCError(code: -32602, message: "Unknown tool or invalid arguments.")
                }
                do {
                    let arguments = params["arguments"] as? [String: Any] ?? [:]
                    let value = try call(name, arguments: arguments)
                    // One text representation avoids duplicating large results in client context.
                    let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    result = ["content": [["type": "text", "text": String(decoding: json, as: UTF8.self)]], "isError": false]
                } catch {
                    result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                }
            default: throw RPCError(code: -32601, message: "Method not supported: \(method)")
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let failure as RPCError {
            return error(id, code: failure.code, message: failure.message)
        } catch {
            return self.error(id, code: -32603, message: "Could not process this request.")
        }
    }

    private func requireInitialized() throws {
        guard initialized else { throw RPCError(code: -32002, message: "Initialize the MCP session first.") }
    }

    private func error(_ id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: AssistantStore.encoder().encode(value), options: [.fragmentsAllowed])
    }

    private func integer(_ args: [String: Any], key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
            throw RPCError(code: -32602, message: "\(key) must be an integer in \(range).")
        }
        return number.intValue
    }

    private func call(_ name: String, arguments args: [String: Any]) throws -> [String: Any] {
        let snapshot = try store.snapshot()
        if let expected = ProcessInfo.processInfo.environment["BREEZE_ASSISTANT_SNAPSHOT_ID"], snapshot.id != expected {
            throw RPCError(code: -32602, message: "This assistant session's scan was replaced or cancelled. Start a new analysis in Breeze.")
        }
        if name != "cleanup_summary" {
            guard args["snapshotID"] as? String == snapshot.id else {
                throw RPCError(code: -32602, message: "The scan changed. Call cleanup_summary and use its snapshotID.")
            }
        }
        switch name {
        case "cleanup_summary":
            let grouped = Dictionary(grouping: snapshot.entries, by: \.category)
            let categories: [[String: Any]] = grouped.keys.sorted().map { category -> [String: Any] in
                let items = grouped[category] ?? []
                let bytes = items.reduce(Int64(0)) { $0 + $1.estimatedBytes }
                let suggestedBytes = items.filter(\.suggested).reduce(Int64(0)) { $0 + $1.estimatedBytes }
                let opportunityCount = items.filter { $0.opportunity != nil && $0.canReview }.count
                return ["category": category, "items": items.count, "estimatedBytes": bytes,
                        "suggestedBytes": suggestedBytes, "opportunityCount": opportunityCount]
            }
            let opportunities: [[String: Any]] = try CleanupOpportunity.allCases.compactMap { kind in
                let items = snapshot.entries.filter { $0.opportunity == kind && $0.canReview }
                    .sorted { $0.estimatedBytes == $1.estimatedBytes ? $0.id < $1.id : $0.estimatedBytes > $1.estimatedBytes }
                guard !items.isEmpty else { return nil }
                return ["kind": kind.rawValue, "items": items.count,
                        "estimatedBytes": items.reduce(Int64(0)) { $0 + $1.estimatedBytes },
                        "largest": try encoded(Array(items.prefix(3).map(\.brief)))]
            }
            return ["snapshotID": snapshot.id, "scannedAt": try encoded(snapshot.scannedAt),
                    "expiresAt": try encoded(snapshot.expiresAt), "itemCount": snapshot.entries.count,
                    "estimatedBytes": snapshot.entries.reduce(Int64(0)) { $0 + $1.estimatedBytes },
                    "categories": categories, "opportunities": opportunities, "hasPermissionIssues": snapshot.hasPermissionIssues,
                    "scanNotes": Array(snapshot.scanNotes.prefix(5)),
                    "additionalScanNotes": max(0, snapshot.scanNotes.count - 5) + snapshot.additionalScanNoteCount,
                    "largestSuggested": try encoded(Array(snapshot.entries.filter(\.suggested).prefix(8).map(\.brief))),
                    "guidance": AssistantSnapshot.guidance]
        case "list_items":
            let scope = args["scope"] as? String ?? "opportunities"
            guard ["opportunities", "suggested", "all"].contains(scope), args["scope"] == nil || args["scope"] is String,
                  args["query"] == nil || args["query"] is String,
                  args["category"] == nil || args["category"] is String else {
                throw RPCError(code: -32602, message: "Use scope opportunities/suggested/all, and string category/query filters.")
            }
            let query = args["query"] as? String ?? ""
            guard query.count <= 200 else { throw RPCError(code: -32602, message: "Query is too long.") }
            let category = args["category"] as? String
            if let category, !snapshot.entries.contains(where: { $0.category == category }) {
                throw RPCError(code: -32602, message: "Use an exact category from cleanup_summary.")
            }
            let offset = try integer(args, key: "offset", fallback: 0, range: 0...snapshot.entries.count)
            let limit = try integer(args, key: "limit", fallback: 15, range: 1...40)
            let matches = snapshot.entries.filter {
                (scope == "all" || (scope == "suggested" && $0.suggested) ||
                    (scope == "opportunities" && $0.opportunity != nil && $0.canReview)) &&
                (category == nil || $0.category == category) &&
                (query.isEmpty || "\($0.title) \($0.owner ?? "") \($0.locations.map(\.path).joined(separator: " "))".localizedStandardContains(query))
            }
            guard offset <= matches.count else { throw RPCError(code: -32602, message: "Offset exceeds the filtered item count.") }
            let page = Array(matches.dropFirst(offset).prefix(limit))
            let next = offset + page.count
            return ["snapshotID": snapshot.id, "total": matches.count, "items": try encoded(page.map(\.brief)),
                    "nextOffset": next < matches.count ? next as Any : NSNull()]
        case "inspect_items":
            guard let ids = args["ids"] as? [String], !ids.isEmpty, ids.count <= 8, Set(ids).count == ids.count else {
                throw RPCError(code: -32602, message: "Inspect 1–8 unique item IDs at a time.")
            }
            let entries = snapshot.entries.filter { ids.contains($0.id) }
            guard entries.count == ids.count else { throw RPCError(code: -32602, message: "Unknown item ID. Read the current scan again.") }
            var details: [[String: Any]] = []
            var returnedIDs: Set<String> = []
            for entry in entries {
                guard var detail = try encoded(entry) as? [String: Any] else { continue }
                // Keep a single unusually large record useful without filling the context window.
                if try JSONSerialization.data(withJSONObject: detail).count > 12_000 {
                    let locations = detail["locations"] as? [[String: Any]] ?? []
                    let sections = detail["context"] as? [[String: Any]] ?? []
                    detail["locations"] = Array(locations.prefix(3))
                    detail["context"] = Array(sections.prefix(2))
                    detail["additionalLocationCount"] = entry.additionalLocationCount + max(0, locations.count - 3)
                    detail["detailsClipped"] = true
                    detail["note"] = "Some paths/context omitted to conserve tokens. Review all locations in Breeze."
                }
                let candidate = details + [detail]
                if !details.isEmpty, try JSONSerialization.data(withJSONObject: candidate).count > 20_000 { break }
                details = candidate
                returnedIDs.insert(entry.id)
            }
            return ["snapshotID": snapshot.id, "items": details,
                    "remainingIDs": ids.filter { !returnedIDs.contains($0) }]
        case "propose_cleanup":
            let data = try JSONSerialization.data(withJSONObject: args)
            struct Input: Decodable {
                let snapshotID: String
                let summary: String
                let items: [AssistantProposalItem]
            }
            let input = try AssistantStore.decoder().decode(Input.self, from: data)
            let proposal = AssistantProposal(snapshotID: input.snapshotID,
                summary: AssistantSnapshot.text(input.summary, limit: 1200),
                items: input.items.map { AssistantProposalItem(id: $0.id, reason: AssistantSnapshot.text($0.reason, limit: 600)) })
            try proposal.validate(against: snapshot)
            try store.propose(proposal)
            return ["proposalID": proposal.id, "items": proposal.items.count,
                    "status": "Awaiting human review in Breeze → Cleanup & apps. Nothing selected or removed."]
        default: throw RPCError(code: -32602, message: "Unknown tool.")
        }
    }
}

private func send(_ response: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func readInputChunk() throws -> Data? {
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        // A pipe read returns as soon as bytes are available. FileHandle's
        // count-based read can wait to fill the buffer on macOS, deadlocking
        // initialization while the MCP client waits for our first response.
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
        }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 { return nil }
        let code = errno
        if code == EINTR { continue }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

if CommandLine.arguments.contains("--help") {
    print("BreezeMCP: local MCP stdio server. Enable sharing in Breeze → Storage → Cleanup & apps → AI assistant. No API key required. This server cannot remove files.")
} else {
    var server = MCPServer()
    var pending = Data()
    var running = true
    do {
        while running, let chunk = try readInputChunk() {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard line.count <= 256 * 1024 else { running = false; break }
                if !line.isEmpty, let response = server.receive(line) { try send(response) }
            }
            if pending.count > 256 * 1024 { running = false }
        }
    } catch {
        // stdout is reserved for JSON-RPC. EOF and broken pipes terminate cleanly.
        try? FileHandle.standardError.write(contentsOf: Data("Breeze MCP connection closed: \(error.localizedDescription)\n".utf8))
    }
}
