import Foundation
import Testing
import OCFoundation
@testable import OCModels

private var fixtureFiles: [URL] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    guard let files = FileManager.default.enumerator(at: root.appending(path: "Fixtures/v2"), includingPropertiesForKeys: nil) else { return [] }
    return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "sse" || ($0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "rest") || ($0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "snapshots") }
}
@Test(arguments: fixtureFiles)
func fullRecordedWireDecoding(file: URL) throws {
    if file.pathExtension == "sse" {
        for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") where line.hasPrefix("data:") {
            let data = Data(line.dropFirst(5).utf8), original = ServerEvent.decode(data)
            try checkEventPayload(original)
            #expect(!original.isFallback, "\(file.lastPathComponent) \(original.header?.type ?? "invalid")")
            var raw = try JSONDecoder().decode(JSONValue.self, from: data)
            raw.set("future", .object(["new": .bool(true)])); raw.set("futureNull", .null)
            let mutated = ServerEvent.decode(try JSONEncoder().encode(raw))
            #expect(original == mutated)
            let nested = ServerEvent.decode(try JSONEncoder().encode(mutate(raw)))
            #expect(!nested.isFallback)
            #expect(removeMutation(nested.payload) == original.payload.omittingNullFields)
            let nonfinite = ServerEvent.decode(try JSONEncoder().encode(mutate(raw, numbers: true)))
            #expect(!nonfinite.isFallback)
            raw.set("type", .string("future.unknown"))
            if case .unknown = ServerEvent.decode(try JSONEncoder().encode(raw)) {} else { Issue.record("Expected an unknown fallback") }
        }
        return
    }
    let raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    if file.deletingLastPathComponent().lastPathComponent == "snapshots" {
        for snapshot in raw.arrayValue ?? [] {
            try checkMutations(snapshot["session"] ?? .object([:]), as: SessionInfo.self)
            for row in snapshot["messages"]?.arrayValue ?? [] { try checkMutations(row, as: SessionMessage.self, validate: validateMessage) }
            for item in snapshot["inbox"]?.arrayValue ?? [] { try checkMutations(item, as: InboxItem.self, validate: validateInbox) }
            for item in snapshot["permissions"]?.arrayValue ?? [] { try checkMutations(item, as: PermissionRequest.self) }
            for item in snapshot["forms"]?.arrayValue ?? [] { try checkMutations(item, as: FormInfo.self, validate: validateForm) }
        }
        return
    }
    for exchange in raw.arrayValue ?? [] {
        guard exchange["response"]?["bodyFormat"]?.stringValue == "json",
              let body = exchange["response"]?["body"],
              let status = exchange["response"]?["status"]?.integerValue, (200..<300).contains(status) else { continue }
        let path = (exchange["request"]?["path"]?.stringValue ?? "").split(separator: "?").first.map(String.init) ?? ""
        let data = body["data"] ?? body
        let rows = data.arrayValue ?? [data]
        if path.contains("/message") {
            for raw in rows { try checkMutations(raw, as: SessionMessage.self, validate: validateMessage) }
        } else if path.hasSuffix("/inbox") {
            for raw in rows { try checkMutations(raw, as: InboxItem.self, validate: validateInbox) }
        } else if path.contains("/permission"), !path.hasSuffix("/reply") {
            for raw in rows { try checkMutations(raw, as: PermissionRequest.self) }
        } else if path.contains("/form"), !path.hasSuffix("/reply") {
            for raw in rows { try checkMutations(raw, as: FormInfo.self, validate: validateForm) }
        } else if path.hasSuffix("/diff") {
            for raw in rows { try checkMutations(raw, as: FileDiff.self) }
        } else if path.hasPrefix("/api/shell/"), path.hasSuffix("/output") {
            try checkMutations(data, as: ShellOutput.self)
        } else if path == "/api/project" {
            for raw in rows { try checkMutations(raw, as: Project.self) }
        } else if path == "/api/location" { try checkMutations(data, as: Location.self)
        } else if path == "/api/agent" {
            for raw in rows { try checkMutations(raw, as: AgentInfo.self) }
        } else if path == "/api/model" || path == "/api/model/default", !data.isNull {
            for raw in rows { try checkMutations(raw, as: ModelInfo.self) }
        } else if path == "/api/provider" {
            for raw in rows { try checkMutations(raw, as: ProviderInfo.self) }
        } else {
            for raw in rows where raw["projectID"] != nil { try checkMutations(raw, as: SessionInfo.self) }
        }
    }
}
private func checkEventPayload(_ event: ServerEvent) throws {
    let p = event.payload
    switch event.header?.type {
    case "session.inbox.enqueued":
        if let item = p["item"] { try checkMutations(item, as: InboxItem.self, validate: validateInbox) }
    case "form.created":
        if let form = p["form"] { try checkMutations(form, as: FormInfo.self, validate: validateForm) }
    case "permission.asked": try checkMutations(p, as: PermissionRequest.self)
    case "session.tool.success", "session.tool.failed":
        for content in p["content"]?.arrayValue ?? [] { try checkMutations(content, as: ToolContent.self) { #expect(!$0.isFallback) } }
    default: break
    }
}
private func mutate(_ raw: JSONValue, numbers: Bool = false) -> JSONValue { mutateWire(raw, numbers: numbers) }
private func removeMutation(_ raw: JSONValue) -> JSONValue { stripMutation(raw) }

@Test func unknownMalformedAndNonfiniteValuesArePreserved() throws {
    let raw = JSONValue.array([.object(["type": .string("future"), "id": .string("1")]), .integer(42),
                              .object(["type": .string("user"), "id": .string("2"), "text": .string("still here")])])
    let rows = try raw.decoded([SessionMessage].self)
    #expect(rows.count == 3); #expect(rows[0].isFallback); #expect(rows[1].isFallback); #expect(rows[2].id == "2")
    let session = try JSONValue.object(["id": .string("ses"), "cost": .string("NaN"), "parentID": .null,
                                      "time": .object(["created": .string("Infinity")])]).decoded(SessionInfo.self)
    #expect(session.cost.isNaN); #expect(session.time.created.isInfinite); #expect(session.parentID == nil)
    let encoded = try JSONEncoder().encode(session)
    #expect(!(String(decoding: encoded, as: UTF8.self).contains("null")))
    let malformed = ServerEvent.decode(Data(#"{"id":"evt_bad","type":"session.text.delta","data":{"delta":42}}"#.utf8))
    #expect(malformed.isFallback)
    let next = ServerEvent.decode(Data(#"{"id":"evt_next","type":"server.connected","data":{}}"#.utf8))
    #expect(!next.isFallback)
    let future = ServerEvent.decode(Data(#"{"id":"evt_future","type":"future.event","data":[1,2]}"#.utf8))
    if case .unknown = future {} else { Issue.record("An unknown payload shape remains an unknown event") }
    let mcp = try JSONValue.array([.object(["status": .string("future")]), .integer(42), .object(["status": .string("connected")])]).decoded([MCPStatus].self)
    if case .unknown = mcp[0] {} else { Issue.record("Unknown MCP status") }
    if case .undecodable = mcp[1] {} else { Issue.record("Malformed MCP status") }
    if case .connected = mcp[2] {} else { Issue.record("MCP decoding did not continue") }
}
@Test func eventsAddedAfter2_0Decode() {
    // Recorded scenarios do not produce these: archiving came in 2.1.0, terminal renames and artifacts in 2.2.4.
    let archived = ServerEvent.decode(Data(#"{"id":"evt_a","type":"session.archived","created":5,"durable":{"aggregateID":"ses_1","seq":3,"version":1},"data":{"sessionID":"ses_1"}}"#.utf8))
    if case .sessionArchived(let header, let payload) = archived { #expect(payload.sessionID == "ses_1" && header.created == 5) }
    else { Issue.record("session.archived") }
    if case .sessionUnarchived(_, let payload) = ServerEvent.decode(Data(#"{"id":"evt_u","type":"session.unarchived","data":{"sessionID":"ses_1"}}"#.utf8)) {
        #expect(payload.sessionID == "ses_1")
    } else { Issue.record("session.unarchived") }
    let terminal = ServerEvent.decode(Data(#"{"id":"evt_t","type":"persistent-pty.updated","data":{"sessionID":"ses_1","terminal":{"id":"pty_1","userTitle":"Server"}}}"#.utf8))
    if case .persistentPtyUpdated(_, let payload) = terminal { #expect(payload.terminal["userTitle"] == .string("Server")) }
    else { Issue.record("persistent-pty.updated") }
    if case .artifactUpdated = ServerEvent.decode(Data(#"{"id":"evt_r","type":"artifact.updated","data":{}}"#.utf8)) {} else { Issue.record("artifact.updated") }
    #expect(ServerEvent.decode(Data(#"{"id":"evt_x","type":"session.archived","data":{}}"#.utf8)).isFallback, "A session event still needs its session")
}
@Test func toolInputsAcceptModelOutputAndLegacyNames() {
    let raw = JSONValue.object(["command": .string("pwd"), "timeout": .string("500"), "future": .bool(true)])
    let shell = ShellInput(raw: raw)
    #expect(shell.timeout == 500); #expect(shell.raw == raw)
    if case .shell = ToolInputView(name: "bash", raw: raw) {} else { Issue.record("V1 bash alias") }
    if case .subagent = ToolInputView(name: "task", raw: .object([:])) {} else { Issue.record("V1 task alias") }
}
