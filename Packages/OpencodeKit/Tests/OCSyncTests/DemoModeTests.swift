import Foundation
import Testing
import OCFoundation
import OCModels
import OCNetworking
@testable import OCSync

/// A transport that fails every request and remembers it: the demo must never reach it.
final class FailingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?] = []
    var requests: [URL?] { lock.withLock { urls } }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { urls.append(request.url) }
        throw URLError(.notConnectedToInternet)
    }
    func stream(_ request: URLRequest) -> AsyncThrowingStream<TransportChunk, any Error> {
        lock.withLock { urls.append(request.url) }
        return AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}

/// Event types seen on a stream, readable from the main actor while the reading task appends.
private final class ReceivedTypes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var types: [String] { lock.withLock { values } }
    func append(_ type: String) { lock.withLock { values.append(type) } }
}

@MainActor
private func eventually(_ what: @autoclosure () -> String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("Timed out waiting for \(what())"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor @Suite(.serialized) struct DemoModeTests {
    let scenario: DemoScenario

    init() throws { scenario = try DemoScenario.bundled() }

    private func raw(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> Endpoint<JSONValue> {
        Endpoint(method: method, path: path, query: query, scope: .location(directory: scenario.directory), body: body) { data, _ in
            try JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    private func session(_ kind: DemoScenario.Kind) throws -> DemoScenario.Session {
        try #require(scenario.sessions.first { $0.kind == kind && $0.parentID == nil })
    }

    @Test func theBundledDemoHasEveryKindOfSession() throws {
        let kinds = Set(scenario.sessions.map(\.kind))
        #expect(kinds == [.done, .live, .permission, .form])
        #expect(try !session(.permission).opening.permissions.isEmpty)
        #expect(try !session(.form).opening.forms.isEmpty)
        #expect(try session(.permission).final.permissions.isEmpty)
        #expect(scenario.directory == "/Users/Shared/trailhead")
        #expect(!scenario.files.isEmpty)
    }

    @Test func aDemoSessionApprovesAReviewsAndNeverOpensTheNetwork() async throws {
        let network = FailingTransport()
        let registry = try await DemoMode.registry(scenario: scenario, pacing: .zero, fallback: network)
        let store = try #require(registry.servers.first)
        #expect(store.record.name == DemoMode.serverName)
        await registry.setScenePhase(.active)
        try await eventually("the session list") { store.readPath.sessions.count >= 4 }

        // A live session streams its recorded reply when opened.
        let live = try session(.live)
        try await store.readPath.open(live.id)
        let replyCount = { store.readPath.sessions[live.id]?.transcript?.order.count ?? 0 }
        // The whole reply arrives from the stream alone: the prompt, each step and the idle row, with no refresh.
        try await eventually("the live reply, \(replyCount()) messages") { replyCount() >= 2 }
        try await eventually("the live session to finish") { store.readPath.sessions[live.id]?.status.isRunning == false && replyCount() == live.final.messages.count }

        // The permission session waits; approving it plays the rest.
        let permission = try session(.permission)
        try await store.readPath.open(permission.id)
        try await eventually("the pending permission") { !(store.readPath.permissions[permission.id] ?? []).isEmpty }
        let request = try #require(store.readPath.permissions[permission.id]?.first)
        try await store.readPath.replyPermission(request, decision: .once, authenticated: true)
        try await eventually("the approved permission to clear") { (store.readPath.permissions[permission.id] ?? []).isEmpty }

        // The working-tree diff and the file list come from the recording.
        let makeClient = try #require(store.readPath.client)
        let client = try await makeClient()
        let diff = try await client.send(raw(.get, "/api/vcs/diff", query: [URLQueryItem(name: "mode", value: "working")]))
        #expect(diff["data"]?.arrayValue?.isEmpty == false)

        // Writes the recording cannot answer are refused rather than sent anywhere.
        await #expect(throws: APIError.self) {
            _ = try await client.send(raw(.post, "/api/session", body: Data(#"{"title":"x"}"#.utf8)))
        }
        await registry.shutdown()
        #expect(network.requests.isEmpty, "the demo reached \(network.requests)")
    }

    /// The app opens a session with the message page and its inbox and request reads in flight together, in no
    /// fixed order. Only a later page read may end the replay, or the live session is left showing an empty page.
    @Test func readsAlongsideTheOpeningPageKeepTheReplay() async throws {
        let transport = ScenarioTransport(scenario: scenario, pacing: .zero)
        let live = try session(.live)
        func get(_ path: String) async throws -> JSONValue {
            let response = try await transport.send(URLRequest(url: URL(string: path, relativeTo: ScenarioTransport.baseURL)!))
            return try JSONDecoder().decode(JSONValue.self, from: response.data)
        }
        let received = ReceivedTypes()
        let reading = Task {
            for try await chunk in transport.stream(URLRequest(url: URL(string: "/api/event", relativeTo: ScenarioTransport.baseURL)!)) {
                guard case .bytes(let data) = chunk else { continue }
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
                    let event = try JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(6).utf8))
                    received.append(event["type"]?.stringValue ?? "")
                }
            }
        }
        defer { reading.cancel() }
        try await eventually("the stream to connect") { received.types.contains("server.connected") }

        let opening = try await get("/api/session/\(live.id)/message?limit=50")
        #expect(opening["data"]?.arrayValue?.isEmpty == true, "the live session starts empty and streams its reply")
        async let inbox = get("/api/session/\(live.id)/inbox")
        async let permissions = get("/api/session/\(live.id)/permission")
        async let forms = get("/api/session/\(live.id)/form")
        let pending = try await [inbox, permissions, forms].map { $0["data"]?.arrayValue?.count }
        #expect(pending == [0, 0, 0])

        try await eventually("the replayed reply") { received.types.contains("session.execution.succeeded") }
        let deltas = live.events.filter { $0["type"]?.stringValue == "session.text.delta" }.count
        #expect(received.types.filter { $0 == "session.text.delta" }.count == deltas, "every recorded event was streamed")
        let final = try await get("/api/session/\(live.id)/message?limit=50")
        #expect(final["data"]?.arrayValue?.count == live.final.messages.count)
    }

    @Test func anotherHostGoesToTheFallbackNotTheRecording() async throws {
        let network = FailingTransport()
        let transport = ScenarioTransport(scenario: scenario, fallback: network)
        await #expect(throws: URLError.self) { _ = try await transport.send(URLRequest(url: URL(string: "https://example.invalid/api/info")!)) }
        #expect(network.requests.count == 1)
        let offline = ScenarioTransport(scenario: scenario)
        await #expect(throws: URLError.self) { _ = try await offline.send(URLRequest(url: URL(string: "https://example.invalid/api/info")!)) }
    }

    @Test func eachDemoStartsFromTheRecording() async throws {
        let first = try await DemoMode.registry(scenario: scenario, pacing: .zero, fallback: FailingTransport())
        let permission = try session(.permission)
        let store = try #require(first.servers.first)
        await first.setScenePhase(.active)
        try await store.readPath.open(permission.id)
        try await eventually("the pending permission") { !(store.readPath.permissions[permission.id] ?? []).isEmpty }
        let request = try #require(store.readPath.permissions[permission.id]?.first)
        try await store.readPath.replyPermission(request, decision: .once, authenticated: true)
        try await eventually("the approval") { (store.readPath.permissions[permission.id] ?? []).isEmpty }
        await first.shutdown()

        let second = try await DemoMode.registry(scenario: scenario, pacing: .zero, fallback: FailingTransport())
        let again = try #require(second.servers.first)
        await second.setScenePhase(.active)
        try await again.readPath.open(permission.id)
        try await eventually("the permission to wait again") { !(again.readPath.permissions[permission.id] ?? []).isEmpty }
        await second.shutdown()
    }
}
