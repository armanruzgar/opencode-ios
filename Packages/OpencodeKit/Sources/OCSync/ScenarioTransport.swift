import Foundation
import OCFoundation
import OCModels
import OCNetworking

/// A recorded opencode server, played back in process. The demo uses it in place of the network: it answers
/// the routes the app reads from `Resources/Demo/demo.json` (recorded by `Tools/demo/record.mjs`) and streams
/// the recorded events. A request for any other host goes to `fallback`, which by default fails, so the demo
/// cannot reach a server even by mistake.
public final class ScenarioTransport: HTTPTransport, Sendable {
    public static let host = "demo.opencode.invalid"
    public static var baseURL: URL { URL(string: "https://\(host)")! }
    private let server: ScenarioServer
    private let fallback: (any HTTPTransport)?

    public init(scenario: DemoScenario, pacing: Duration = .milliseconds(1), fallback: (any HTTPTransport)? = nil) {
        server = ScenarioServer(scenario: scenario, pacing: pacing); self.fallback = fallback
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.host == Self.host else {
            guard let fallback else { throw URLError(.notConnectedToInternet) }
            return try await fallback.send(request)
        }
        return try await server.respond(to: request)
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<TransportChunk, any Error> {
        guard request.url?.host == Self.host else {
            if let fallback { return fallback.stream(request) }
            return AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
        }
        let server = server
        // The recording is finite, so nothing is dropped even when the app reads more slowly than it is played.
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await server.subscribe(UUID(), request: request, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// The recorded data. Values stay raw JSON, as the server sent them.
public struct DemoScenario: Sendable {
    public struct Snapshot: Sendable {
        public let session: JSONValue
        public let messages: [JSONValue]
        public let inbox: [JSONValue]
        public let permissions: [JSONValue]
        public let forms: [JSONValue]
    }
    public enum Kind: String, Sendable { case done, live, permission, form }
    public struct Session: Sendable {
        public let id: String
        public let parentID: String?
        public let kind: Kind
        /// The state the demo opens with: the start of a live session, the moment a request waits, or the end.
        public let opening: Snapshot
        public let final: Snapshot
        /// The pending permission or form request.
        public let request: JSONValue?
        /// Events after `opening`, played when a live session is opened or a request is answered.
        public let events: [JSONValue]
        public let diff: JSONValue
    }
    public let directory: String
    public let routes: [String: JSONValue]
    public let files: [String: (contentType: String, text: String)]
    public let sessions: [Session]

    /// The bundled demo.
    public static func bundled() throws -> DemoScenario {
        // `.process` flattens the Demo folder into the bundle root.
        guard let url = Bundle.module.url(forResource: "demo", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        return try DemoScenario(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        directory = raw["directory"]?.stringValue ?? "/"
        routes = raw["routes"]?.objectValue ?? [:]
        var files: [String: (String, String)] = [:]
        for (path, file) in raw["files"]?.objectValue ?? [:] {
            files[path] = (file["contentType"]?.stringValue ?? "text/plain", file["text"]?.stringValue ?? "")
        }
        self.files = files
        func snapshot(_ value: JSONValue?) -> Snapshot {
            .init(session: value?["session"] ?? .object([:]), messages: value?["messages"]?.arrayValue ?? [], inbox: value?["inbox"]?.arrayValue ?? [],
                  permissions: value?["permissions"]?.arrayValue ?? [], forms: value?["forms"]?.arrayValue ?? [])
        }
        var sessions: [Session] = []
        for item in raw["sessions"]?.arrayValue ?? [] {
            guard let id = item["id"]?.stringValue, let kind = item["kind"]?.stringValue.flatMap(Kind.init) else { continue }
            let opening = kind == .done ? item["final"] : kind == .live ? item["initial"] : item["pending"]
            let offset = opening?["eventOffset"]?.wireInt ?? 0
            let events = (item["events"]?.arrayValue ?? []).filter { ($0["offset"]?.wireInt ?? 0) >= offset }.compactMap { $0["event"] }
            sessions.append(.init(id: id, parentID: nil, kind: kind, opening: snapshot(opening), final: snapshot(item["final"]),
                                  request: item["request"], events: kind == .done ? [] : events, diff: item["diff"] ?? .array([])))
            for child in item["children"]?.arrayValue ?? [] {
                guard let childID = child["id"]?.stringValue else { continue }
                let state = snapshot(child["final"])
                sessions.append(.init(id: childID, parentID: id, kind: .done, opening: state, final: state, request: nil, events: [], diff: .array([])))
            }
        }
        self.sessions = sessions
    }
}

actor ScenarioServer {
    private enum Phase { case opening, streaming, final }
    private let scenario: DemoScenario
    private let pacing: Duration
    private var phases: [String: Phase] = [:]
    private var subscribers: [UUID: AsyncThrowingStream<TransportChunk, any Error>.Continuation] = [:]
    private var replays: [String: Task<Void, Never>] = [:]

    init(scenario: DemoScenario, pacing: Duration) { self.scenario = scenario; self.pacing = pacing }

    // MARK: Events

    func subscribe(_ id: UUID, request: URLRequest, continuation: AsyncThrowingStream<TransportChunk, any Error>.Continuation) {
        guard request.url?.path == "/api/event", let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else {
            continuation.finish(throwing: URLError(.badServerResponse)); return
        }
        subscribers[id] = continuation
        startHeartbeat()
        continuation.yield(.response(response))
        continuation.yield(.bytes(Self.frame(.object(["id": .string("evt_demo_connected_\(id.uuidString.prefix(8))"), "type": .string("server.connected"), "data": .object([:])]))))
    }
    private var listening: Bool { !subscribers.isEmpty }
    private var heartbeat: Task<Void, Never>?
    /// A comment every 15 seconds keeps the stream alive between events, as a live server's heartbeat does; the
    /// app treats 45 seconds of silence as a stalled connection.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, await self.beat() else { return }
            }
        }
    }
    private func beat() -> Bool {
        broadcast(Data(": heartbeat\n\n".utf8))
        if subscribers.isEmpty { heartbeat = nil; return false }
        return true
    }
    /// Streams the app closed are dropped at the next event.
    private func broadcast(_ data: Data) {
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(.bytes(data)) { subscribers.removeValue(forKey: id) }
        }
    }
    static func frame(_ event: JSONValue) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return Data("data: ".utf8) + ((try? encoder.encode(event)) ?? Data("{}".utf8)) + Data("\n\n".utf8)
    }

    /// Plays a session's recorded events with their recorded rhythm, then serves its final state.
    private func replay(_ id: String) {
        guard let session = session(id), phase(id) == .opening, !session.events.isEmpty else { return }
        phases[id] = .streaming
        let events = session.events, pacing = pacing
        replays[id] = Task { [weak self] in
            // The reply starts once the app has the page it asked for, and its event stream is connected (at most
            // 10 seconds): events sent earlier would be lost or applied before the page.
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0..<200 {
                guard let self, !Task.isCancelled else { return }
                if await self.listening { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            var previous: Double?
            for event in events {
                let created = event["created"]?.doubleValue
                if let created, let previous {
                    // Recorded gaps, kept between 15 ms and 400 ms so streaming reads naturally.
                    let gap = min(400, max(15, created - previous))
                    try? await Task.sleep(for: pacing * Int(gap))
                }
                previous = created ?? previous
                guard !Task.isCancelled else { return }
                await self?.broadcast(Self.frame(event))
            }
            await self?.finish(id)
        }
    }
    private func finish(_ id: String) { phases[id] = .final; replays[id] = nil }
    /// A read during a replay jumps to the end, so the app never sees a state older than the events it has.
    private func settle(_ id: String) {
        guard phase(id) == .streaming else { return }
        replays[id]?.cancel(); finish(id)
        // The run's end, so the app stops showing the session as working.
        if let last = session(id)?.events.last, last["type"]?.stringValue?.hasPrefix("session.execution.") == true { broadcast(Self.frame(last)) }
    }

    // MARK: Routes

    func respond(to request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let path = components.percentEncodedPath
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if parts.starts(with: ["api", "fs", "read"]) { return file(parts.dropFirst(3).joined(separator: "/"), url: url) }
        guard let (status, body) = route(method, parts: Array(parts), query: query) else {
            return json(url, status: 404, .object(["_tag": .string("NotFound"), "message": .string("Not available in the demo")]))
        }
        return json(url, status: status, body)
    }

    private func route(_ method: String, parts: [String], query: [String: String]) -> (Int, JSONValue)? {
        let key = "/" + parts.joined(separator: "/")
        switch (method, parts.count >= 3 && parts[1] == "session" ? Array(parts.dropFirst(2)) : []) {
        case ("GET", ["active"]):
            let running = scenario.sessions.filter { $0.kind == .live && phase($0.id) != .final }
            return (200, .object(["data": .object(Dictionary(uniqueKeysWithValues: running.map { ($0.id, JSONValue.object(["type": .string("running")])) }))]))
        case ("GET", let rest) where rest.count == 1:
            return state(rest[0]).map { (200, .object(["data": $0.session])) }
        case ("GET", let rest) where rest.count == 2 && rest[1] == "message":
            // Opening a live session starts its reply; a later read (a resync) ends the replay at the final state.
            if scenario.sessions.first(where: { $0.id == rest[0] })?.kind == .live && phase(rest[0]) == .opening { replay(rest[0]) } else { settle(rest[0]) }
            guard let messages = state(rest[0])?.messages else { return nil }
            let limit = Int(query["limit"] ?? "") ?? 50
            let ordered = query["order"] == "asc" ? messages : messages.reversed()
            // A cursor is the offset of the next page, newest first, as the server pages history.
            let start = query["cursor"].flatMap { Int($0.dropFirst()) } ?? 0
            let slice = Array(ordered.dropFirst(start).prefix(limit))
            return (200, page(slice, next: start + slice.count < ordered.count ? "o\(start + slice.count)" : nil))
        case ("GET", let rest) where rest.count == 2 && ["inbox", "permission", "form"].contains(rest[1]):
            // The app reads these alongside the message page when it opens a session, so they must not end the
            // replay that page started. Once the session has moved on, its request has been answered.
            guard let state = requests(rest[0]) else { return nil }
            return (200, .object(["data": .array(rest[1] == "inbox" ? state.inbox : rest[1] == "permission" ? state.permissions : state.forms)]))
        case ("GET", let rest) where rest.count == 3 && ["permission", "form"].contains(rest[1]):
            guard let session = session(rest[0]), phase(rest[0]) == .opening, let request = session.request, request["id"]?.stringValue == rest[2] else { return nil }
            return (200, .object(["data": request]))
        case ("POST", let rest) where rest.count == 4 && ["permission", "form"].contains(rest[1]) && rest[3] == "reply":
            guard let session = session(rest[0]), phase(rest[0]) == .opening, session.request?["id"]?.stringValue == rest[2] else {
                return (404, .object(["_tag": .string("NotFound"), "message": .string("The request is no longer pending")]))
            }
            replay(rest[0])
            return (204, .null)
        case ("GET", let rest) where rest.count == 2 && rest[1] == "diff":
            return session(rest[0]).map { (200, .object(["data": phase($0.id) == .final || $0.kind == .done ? $0.diff : .array([])])) }
        case ("POST", let rest) where rest.count == 2 && rest[1] == "view":
            return (204, .null)
        default: break
        }
        switch (method, key) {
        case ("GET", "/api/session"):
            let parent = query["parentID"].flatMap { $0 == "null" ? nil : $0 }
            let search = query["search"]?.lowercased() ?? ""
            let infos = scenario.sessions.filter { $0.parentID == parent }.compactMap { state($0.id)?.session }
                .filter { search.isEmpty || ($0["title"]?.stringValue ?? "").lowercased().contains(search) }
            let updated: (JSONValue) -> Double = { $0["time"]?["updated"]?.doubleValue ?? 0 }
            return (200, page(infos.sorted { updated($0) > updated($1) }))
        case ("GET", "/api/permission/request"), ("GET", "/api/form"):
            let field = key == "/api/form" ? \DemoScenario.Snapshot.forms : \DemoScenario.Snapshot.permissions
            let pending = scenario.sessions.compactMap { requests($0.id)?[keyPath: field] }.flatMap(\.self)
            return (200, located(.array(pending)))
        case ("GET", "/api/fs/find"):
            let needle = query["query"]?.lowercased() ?? ""
            let entries = scenario.routes.filter { $0.key.hasPrefix("GET /api/fs/list") }.flatMap { $0.value["data"]?.arrayValue ?? [] }
            let found = entries.filter { needle.isEmpty || ($0["path"]?.stringValue ?? "").lowercased().contains(needle) }
            return (200, located(.array(Array(found.prefix(Int(query["limit"] ?? "") ?? 50)))))
        case ("GET", "/api/vcs/diff"):
            return scenario.routes["GET /api/vcs/diff?mode=\(query["mode"] ?? "working")"].map { (200, $0) }
        case ("GET", "/api/fs/list"):
            return scenario.routes["GET /api/fs/list?path=\(query["path"] ?? "")"].map { (200, $0) }
        case ("GET", _):
            return scenario.routes["GET " + key].map { (200, $0) }
        default:
            return (403, .object(["_tag": .string("DemoReadOnly"), "message": .string(localized("The demo can't change anything. Add your own server to send prompts."))]))
        }
    }

    private func session(_ id: String) -> DemoScenario.Session? { scenario.sessions.first { $0.id == id } }
    private func phase(_ id: String) -> Phase { phases[id] ?? .opening }
    private func state(_ id: String) -> DemoScenario.Snapshot? {
        guard let session = session(id) else { return nil }
        return phase(id) == .final ? session.final : session.opening
    }
    /// Pending inbox items and requests: those of the opening state until a reply or an open starts the replay.
    private func requests(_ id: String) -> DemoScenario.Snapshot? {
        guard let session = session(id) else { return nil }
        return phase(id) == .opening ? session.opening : session.final
    }
    private func page(_ items: [JSONValue], next: String? = nil) -> JSONValue {
        .object(["data": .array(items), "cursor": .object(next.map { ["next": .string($0)] } ?? [:])])
    }
    private func located(_ data: JSONValue) -> JSONValue { .object(["location": .object(["directory": .string(scenario.directory)]), "data": data]) }
    private func json(_ url: URL, status: Int, _ body: JSONValue) -> HTTPResponse {
        let data = status == 204 ? Data() : ((try? JSONEncoder().encode(body)) ?? Data())
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Date": Self.date()])!
        return HTTPResponse(data: data, response: response)
    }
    private func file(_ path: String, url: URL) -> HTTPResponse {
        guard let file = scenario.files[path] else { return json(url, status: 404, .object(["_tag": .string("NotFound")])) }
        let data = Data(file.text.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": file.contentType, "Content-Length": String(data.count), "ETag": "\"demo-\(data.count)\""])!
        return HTTPResponse(data: data, response: response)
    }
    private static func date() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}
