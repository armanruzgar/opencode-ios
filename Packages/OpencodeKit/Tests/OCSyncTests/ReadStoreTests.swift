import Foundation
import Observation
import Testing
import OCFoundation
import OCModels
import OCNetworking
import OCPersistence
@testable import OCSync

struct ReadTransport: HTTPTransport {
    var respond: @Sendable (URLRequest) async throws -> JSONValue
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let value = try await respond(request), url = try #require(request.url)
        return .init(data: try JSONEncoder().encode(value), response: try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
    func stream(_ request: URLRequest) -> AsyncThrowingStream<TransportChunk, any Error> { .init { $0.finish() } }
}
func readAPI(_ respond: @escaping @Sendable (URLRequest) async throws -> JSONValue) -> APIClient {
    APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, transport: ReadTransport(respond: respond))
}
func emptyReadAPI() -> APIClient {
    readAPI { request in
        if request.url?.path == "/api/project" { return .array([]) }
        if request.url?.path == "/api/session/active" { return .object(["data": .object([:])]) }
        return .object(["data": .array([]), "cursor": .object([:]), "location": .object(["directory": .string("/p")])])
    }
}
func readInfo(_ id: String = "s", parent: String? = nil) -> SessionInfo {
    .init(raw: .object(["id": .string(id), "parentID": parent.map(JSONValue.string) ?? .null, "location": .object(["directory": .string("/p")]), "time": .object(["created": .integer(0), "updated": .integer(0)])]))
}
func readRow(_ id: String, type: String = "user") -> SessionMessage {
    .init(raw: .object(["id": .string(id), "type": .string(type), "text": .string(id), "content": .array([]), "time": .object(["created": .integer(0)])]))
}
func readEvent(_ type: String, id: String = UUID().uuidString, session: String = "s", seq: Int? = nil, data: [String: JSONValue] = [:], created: Double = 1) throws -> ServerEvent {
    var data = data; data["sessionID"] = .string(session)
    var raw: JSONValue = .object(["id": .string("evt_" + id), "type": .string(type), "created": .double(created), "data": .object(data), "location": .object(["directory": .string("/p")])])
    if let seq { raw.set("durable", .object(["aggregateID": .string(session), "seq": .integer(Int64(seq)), "version": .integer(1)])) }
    return ServerEvent.decode(try JSONEncoder().encode(raw))
}

@Test @MainActor func duplicateSequenceAndAuthoritativeEnd() throws {
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo(), messages: [readRow("m", type: "assistant")])
    let start = try readEvent("session.text.started", seq: 5, data: ["assistantMessageID": .string("m"), "ordinal": .integer(0)])
    store.apply(start); store.apply(start)
    let delta = try readEvent("session.text.delta", data: ["assistantMessageID": .string("m"), "ordinal": .integer(0), "delta": .string("partial")])
    store.apply(delta); store.apply(delta)
    let item = try #require(store.sessions["s"]?.transcript?.messages["m"]?.item(.text(0)))
    #expect(item.text == "partial")
    store.apply(try readEvent("session.text.ended", seq: 7, data: ["assistantMessageID": .string("m"), "ordinal": .integer(0), "text": .string("whole")]))
    #expect(item.text == "whole"); #expect(!item.joinedMidStream)
    store.apply(try readEvent("session.text.started", seq: 5, data: ["assistantMessageID": .string("m"), "ordinal": .integer(0)]))
    #expect(item.text == "whole")
    store.apply(try readEvent("session.text.delta", data: ["assistantMessageID": .string("missing"), "delta": .string("drop")]))
    #expect(store.sessions["s"]?.transcript?.order == ["m"])
}
@Test @MainActor func midstreamAndPositionBasedRevert() throws {
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo(), messages: [readRow("z"), readRow("a", type: "assistant"), readRow("b")])
    store.apply(try readEvent("session.reasoning.delta", data: ["assistantMessageID": .string("a"), "ordinal": .integer(0), "delta": .string("tail")]))
    #expect(store.sessions["s"]?.transcript?.messages["a"]?.items.first?.joinedMidStream == true)
    let t = try #require(store.sessions["s"]?.transcript)
    #expect(t.visibleOrder(revert: "a", pending: []) == ["z"])
    store.apply(try readEvent("session.revert.committed", seq: 9, data: ["to": .string("a")]))
    #expect(t.order == ["z"])
}
@Test @MainActor func reasoningNativeMetadataSurvivesStreaming() throws {
    let store = ReadStore(serverID: "server")
    store.seed(info: readInfo(), messages: [readRow("a", type: "assistant")])
    let legacy: JSONValue = .object(["signature": .string("legacy")])
    let native: JSONValue = .object(["reasoningField": .string("reasoning_content")])
    let start = try readEvent("session.reasoning.started", data: [
        "assistantMessageID": .string("a"), "ordinal": .integer(0), "state": legacy, "native": native,
    ])
    if case .sessionReasoningStarted(_, let payload) = start { #expect(payload.native == native) }
    else { Issue.record("Expected a reasoning start") }
    store.apply(start)
    store.apply(try readEvent("session.reasoning.delta", data: ["assistantMessageID": .string("a"), "ordinal": .integer(0), "delta": .string("Let me think.")]))
    let item = try #require(store.sessions["s"]?.transcript?.messages["a"]?.item(.reasoning(0)))
    #expect(item.fields["native"] == native)
    store.apply(try readEvent("session.reasoning.ended", data: ["assistantMessageID": .string("a"), "ordinal": .integer(0), "text": .string("Let me think."), "native": .null]))
    #expect(item.fields["native"] == native)
    #expect(item.fields["state"] == legacy)
    let completed: JSONValue = .object(["reasoningField": .string("reasoning_content"), "signature": .string("complete")])
    let end = try readEvent("session.reasoning.ended", data: ["assistantMessageID": .string("a"), "ordinal": .integer(0), "text": .string("Let me think."), "native": completed])
    if case .sessionReasoningEnded(_, let payload) = end { #expect(payload.native == completed) }
    else { Issue.record("Expected a reasoning end") }
    store.apply(end)
    let snapshot = try #require(store.sessions["s"]?.transcript?.snapshot.first)
    #expect(snapshot.raw["content"]?.arrayValue?.first?["native"] == completed)
    #expect(snapshot.raw["content"]?.arrayValue?.first?["state"] == legacy)
}
@Test @MainActor func nativeProviderStateIsKeptOnTextToolsStepsAndCompaction() throws {
    // opencode 2.1.0 renamed `state`, `providerState` and `resultState` to `native` and dropped compaction's `recent`.
    let store = ReadStore(serverID: "server")
    store.seed(info: readInfo(), messages: [readRow("a", type: "assistant")])
    let called: JSONValue = .object(["call": .string("one")]), result: JSONValue = .object(["result": .string("two")])
    let tokens: JSONValue = .object(["input": .integer(1), "output": .integer(1), "reasoning": .integer(0), "cache": .object(["read": .integer(0), "write": .integer(0)])])
    store.apply(try readEvent("session.step.started", data: ["assistantMessageID": .string("a"), "agent": .string("build"), "model": .object([:])]))
    store.apply(try readEvent("session.text.started", data: ["assistantMessageID": .string("a"), "ordinal": .integer(0)]))
    store.apply(try readEvent("session.text.ended", data: ["assistantMessageID": .string("a"), "ordinal": .integer(0), "text": .string("Hi"), "native": called]))
    store.apply(try readEvent("session.tool.input.started", data: ["assistantMessageID": .string("a"), "id": .string("t"), "name": .string("read")]))
    store.apply(try readEvent("session.tool.called", data: ["assistantMessageID": .string("a"), "id": .string("t"), "input": .object([:]), "executed": .bool(true), "native": called]))
    store.apply(try readEvent("session.tool.success", data: ["assistantMessageID": .string("a"), "id": .string("t"), "executed": .bool(true),
        "content": .array([.object(["type": .string("text"), "text": .string("ok")])]), "native": result]))
    store.apply(try readEvent("session.step.ended", data: ["assistantMessageID": .string("a"), "finish": .string("stop"), "cost": .integer(0), "tokens": tokens, "native": result]))
    let row = try #require(store.sessions["s"]?.transcript?.snapshot.first)
    let content = row.raw["content"]?.arrayValue ?? []
    #expect(row.raw["native"] == result)
    #expect(content.first { $0["type"] == .string("text") }?["native"] == called)
    #expect(content.first { $0["type"] == .string("tool") }?["native"] == .object(["call": .string("one"), "result": .string("two")]), "Merged, like the server")
    store.apply(try readEvent("session.compaction.started", data: ["reason": .string("manual")]))
    #expect(store.sessions["s"]?.transcript?.snapshot.last?.raw["recent"] == nil)
    store.apply(try readEvent("session.compaction.ended", data: ["reason": .string("manual"), "text": .string("Summary"), "native": called]))
    let compaction = try #require(store.sessions["s"]?.transcript?.snapshot.last)
    #expect(compaction.raw["status"] == .string("completed") && compaction.raw["native"] == called && compaction.raw["recent"] == nil)
}
@Test @MainActor func archiveEventsSetAndClearTheArchiveTime() throws {
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo(), messages: [])
    store.apply(try readEvent("session.archived", seq: 1, created: 50))
    #expect(store.sessions["s"]?.info.time.archived == 50 && store.sessions["s"]?.info.time.updated == 50)
    store.apply(try readEvent("session.unarchived", seq: 2, created: 60))
    #expect(store.sessions["s"]?.info.raw["time"]?["archived"] == nil && store.sessions["s"]?.info.time.updated == 60)
}
@Test @MainActor func childAttentionWalksParents() throws {
    let store = ReadStore(serverID: "server")
    store.seed(info: readInfo("root")); store.seed(info: readInfo("child", parent: "root")); store.seed(info: readInfo("grandchild", parent: "child"))
    store.apply(try readEvent("permission.asked", session: "grandchild", data: ["id": .string("per"), "action": .string("edit"), "resources": .array([])]))
    #expect(store.sessions["root"]?.attention == 1); #expect(store.sessions["child"]?.attention == 1)
    store.apply(try readEvent("permission.replied", session: "grandchild", data: ["requestID": .string("per"), "reply": .string("once")]))
    #expect(store.sessions["root"]?.attention == 0)
}
@Test @MainActor func cacheFirstAndTranscriptLRU() async throws {
    let writer = try PersistenceWriter(), cache = CacheStore(writer: writer)
    for i in 0..<7 {
        let id = String(i)
        await cache.save(.init(serverID: "server", sessions: [readInfo(id)], transcripts: [id: .init(messages: [readRow(id)])]))
    }
    try await cache.flush()
    let store = ReadStore(serverID: "server", cache: cache)
    try await store.loadCache()
    #expect(store.cacheLoaded); #expect(store.sessions.count == 7)
    for i in 0..<7 { try await store.open(String(i)) }
    #expect(store.sessions.values.filter { $0.transcript != nil }.count == 6)
    #expect(store.sessions["0"]?.transcript == nil)
    try await store.open("0")
    #expect(store.sessions["0"]?.transcript?.order == ["0"])
    await store.stop()
}
@Test @MainActor func deltaMicrobenchmarkAndObservationScope() throws {
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo(), messages: [readRow("m", type: "assistant")])
    for n in 0..<2 { store.apply(try readEvent("session.text.started", seq: n, data: ["assistantMessageID": .string("m"), "ordinal": .integer(Int64(n))])) }
    let message = try #require(store.sessions["s"]?.transcript?.messages["m"]), second = try #require(message.item(.text(1)))
    withObservationTracking { _ = message.items; _ = second.text } onChange: { Issue.record("A delta invalidated another item or its parent") }
    let events = try (0..<1000).map { _ in try readEvent("session.text.delta", data: ["assistantMessageID": .string("m"), "ordinal": .integer(0), "delta": .string("x")]) }
    let start = ContinuousClock.now
    for event in events { store.apply(event) }
    let elapsed = start.duration(to: .now)
    print("Delta apply: \(elapsed / 1000) per item (1000 main-actor deltas)")
    #expect(elapsed < .milliseconds(500), "1000 main-actor deltas must average under 0.5 ms; measured \(elapsed)")
    #expect(message.item(.text(0))?.text.count == 1000)
}

@Test @MainActor func persistenceDoesNotWritePerDeltaAndFlushesAtTurnEnd() async throws {
    let time = SyncTime(), writer = try PersistenceWriter(), cache = CacheStore(writer: writer)
    let store = ReadStore(serverID: "server", cache: cache, clock: time.clock)
    store.seed(info: readInfo(), messages: [readRow("m", type: "assistant")])
    for _ in 0..<100 {
        store.apply(try readEvent("session.text.delta", data: ["assistantMessageID": .string("m"), "ordinal": .integer(0), "delta": .string("x")]))
    }
    #expect(await writer.writeCount == 0)
    store.apply(try readEvent("session.execution.succeeded", seq: 1))
    store.seed(info: readInfo("other"), messages: [readRow("other-row", type: "assistant")])
    store.apply(try readEvent("session.text.delta", session: "other", data: ["assistantMessageID": .string("other-row"), "ordinal": .integer(0), "delta": .string("still running")]))
    await settle { await writer.writeCount == 1 }
    #expect(try await cache.transcript(serverID: "server", sessionID: "s")?.messages.first?.content.first?.fields.text.count == 100)
    await store.stop()
}
