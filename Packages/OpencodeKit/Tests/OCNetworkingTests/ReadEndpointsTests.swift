import Foundation
import Testing
import OCFoundation
import OCModels
@testable import OCNetworking

@Test func messageCursorNeverCombinesWithOrder() {
    let newest = ReadEndpoints.messages("s")
    #expect(newest.query.contains { $0.name == "limit" && $0.value == "50" })
    #expect(newest.query.contains { $0.name == "order" && $0.value == "desc" })
    let older = ReadEndpoints.messages("s", cursor: "opaque", type: "assistant")
    #expect(!older.query.contains { $0.name == "order" })
    #expect(older.query.contains { $0.name == "type" && $0.value == "assistant" })
    let start = ReadEndpoints.messages("s", order: .asc)
    #expect(!start.query.contains { $0.name == "cursor" })
    #expect(start.query.contains { $0.name == "order" && $0.value == "asc" })
}
@Test func sessionCursorCarriesOnlyCursorAndLimit() {
    let endpoint = ReadEndpoints.sessions(filter: .init(search: "hello", parentID: "parent", project: "p"), cursor: "opaque")
    #expect(Set(endpoint.query.map(\.name)) == ["cursor", "limit"])
}
@Test func sessionListsFilterArchivedSessionsOnlyWhenAsked() {
    #expect(!ReadEndpoints.sessions().query.contains { $0.name == "archived" })
    #expect(ReadEndpoints.sessions(filter: .init(archived: false)).query.contains { $0.name == "archived" && $0.value == "false" })
    #expect(ReadEndpoints.sessions(filter: .init(archived: true)).query.contains { $0.name == "archived" && $0.value == "true" })
    #expect(Set(ReadEndpoints.sessions(filter: .init(archived: false), cursor: "opaque").query.map(\.name)) == ["cursor", "limit"])
}
@Test func locationInfoIsAnUnwrappedObject() async throws {
    let transport = FakeTransport { _, _ in
        response(body: Data(#"{"directory":"/canonical","project":{"id":"p","directory":"/canonical","canonical":"/root"}}"#.utf8))
    }
    let client = APIClient(baseURL: testURL, transport: transport)
    let location = try await client.send(ReadEndpoints.location("/alias"))
    #expect(location.directory == "/canonical" && location.project?.id == "p")
}
@Test func locatedReadAndView204() async throws {
    let transport = FakeTransport { request, _ in
        if request.httpMethod == "POST" { return response(204, type: "", body: Data()) }
        return response(body: Data(#"{"location":{"directory":"/canonical"},"data":[{"id":"agent","name":"Build","color":"blue"}]}"#.utf8))
    }
    let client = APIClient(baseURL: testURL, transport: transport)
    let result = try await client.send(ReadEndpoints.agents("/alias"))
    #expect(result.location.directory == "/canonical"); #expect(result.data.first?.color == "blue")
    try await client.send(ReadEndpoints.viewed("s", idle: 12))
    #expect(transport.requests.last?.httpMethod == "POST")
}
