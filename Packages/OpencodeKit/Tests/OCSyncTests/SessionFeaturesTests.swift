import Foundation
import Testing
import Clocks
import OCModels
import OCFoundation
import OCNetworking
@testable import OCSync

@MainActor private func featureStore(_ transport: AdminTransport, running: Bool = false) -> ReadStore {
    let client = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, transport: transport)
    let store = ReadStore(serverID: UUID().uuidString, client: { client })
    store.seed(info: SessionInfo(raw: .object(["id": .string("ses_1"), "projectID": .string("prj"), "title": .string("Fix the parser"),
        "location": .object(["directory": .string("/p")]), "time": .object(["created": .integer(1), "updated": .integer(1)])])),
        messages: [
            SessionMessage(raw: .object(["id": .string("msg_1"), "type": .string("user"), "text": .string("first"), "time": .object(["created": .integer(10)])])),
            SessionMessage(raw: .object(["id": .string("msg_2"), "type": .string("user"), "text": .string("second"), "time": .object(["created": .integer(20)])])),
        ])
    if running { store.sessions["ses_1"]?.status = .running(since: 1) }
    return store
}
private func event(_ raw: JSONValue) -> ServerEvent { ServerEvent.decode((try? JSONEncoder().encode(raw)) ?? Data()) }
private func moved(_ directory: String, seq: Int = 5) -> ServerEvent {
    event(.object(["id": .string("evt_move\(seq)"), "type": .string("session.moved"), "created": .integer(100),
        "data": .object(["sessionID": .string("ses_1"), "location": .object(["directory": .string(directory)]), "projectID": .string("prj"), "subpath": .string("")]),
        "durable": .object(["aggregateID": .string("ses_1"), "seq": .integer(Int64(seq)), "version": .integer(1)])]))
}
private func enqueuedMove(_ directory: String, seq: Int = 4) -> ServerEvent {
    event(.object(["id": .string("evt_enq\(seq)"), "type": .string("session.inbox.enqueued"), "created": .integer(90),
        "data": .object(["sessionID": .string("ses_1"), "inboxID": .string("msg_move"), "item": .object(["type": .string("move"), "delivery": .string("queue"),
            "payload": .object(["location": .object(["directory": .string(directory)]), "projectID": .string("prj")])])]),
        "durable": .object(["aggregateID": .string("ses_1"), "seq": .integer(Int64(seq)), "version": .integer(1)])]))
}

@MainActor @Test func moveGoesPendingThenAppliedOnSessionMoved() async throws {
    let transport = AdminTransport(["POST /api/session/ses_1/move": [.init(status: 204)]])
    let store = featureStore(transport, running: true)
    let composer = store.composer(sessionID: "ses_1", directory: "/p")
    try await store.moveSession("ses_1", to: MoveTarget(kind: .worktree, directory: "/wt", branch: "b"), delivery: .queue)
    #expect(transport.body(of: "POST /api/session/ses_1/move") == .object(["directory": .string("/wt"), "delivery": .string("queue")]))
    #expect(store.moveState("ses_1") == .pending(directory: "/wt", delivery: .queue))
    store.apply(enqueuedMove("/wt"))
    #expect(store.moveState("ses_1") == .pending(directory: "/wt", delivery: .queue), "The inbox item keeps the move pending")
    store.apply(event(.object(["id": .string("evt_del"), "type": .string("session.inbox.delivered"), "created": .integer(95),
        "data": .object(["sessionID": .string("ses_1"), "inboxID": .string("msg_move")]),
        "durable": .object(["aggregateID": .string("ses_1"), "seq": .integer(5), "version": .integer(1)])])))
    store.apply(moved("/wt", seq: 6))
    #expect(store.moveState("ses_1") == .applied(directory: "/wt"))
    #expect(store.sessions["ses_1"]?.info.location.directory == "/wt")
    #expect(composer.directory == "/wt", "The draft's composer follows the session")
    #expect(store.composer(sessionID: "ses_1", directory: "/p") === composer, "The draft stays keyed by the session")
    #expect(store.sessions["ses_1"]?.transcript?.order.contains { store.sessions["ses_1"]?.transcript?.messages[$0]?.fields.type == "location-switched" } == true)
    store.dismissMove("ses_1")
    #expect(store.moveState("ses_1") == nil)
}

@MainActor @Test func moveFailureIsKeptWithTheServerMessage() async {
    let transport = AdminTransport(["POST /api/session/ses_1/move": [.init(status: 400, body: .object(["_tag": .string("InvalidRequestError"), "message": .string("Not a directory: /wt")]))]])
    let store = featureStore(transport)
    await #expect(throws: APIError.self) { try await store.moveSession("ses_1", to: MoveTarget(kind: .worktree, directory: "/wt", branch: nil), delivery: .steer) }
    #expect(store.moveState("ses_1") == .failed(directory: "/wt", message: "Not a directory: /wt"))
    #expect(store.sessions["ses_1"]?.info.location.directory == "/p")
}

@MainActor @Test func moveToANewWorktreeCreatesItFirst() async throws {
    let transport = AdminTransport(["POST /api/worktree": [.init(body: .object(["directory": .string("/data/wt/new")]))],
                                    "POST /api/session/ses_1/move": [.init(status: 204)]])
    let store = featureStore(transport)
    try await store.moveSession("ses_1", to: MoveTarget(kind: .newWorktree, directory: "", branch: nil), delivery: .steer)
    #expect(transport.body(of: "POST /api/worktree") == .object(["projectID": .string("prj")]))
    #expect(transport.body(of: "POST /api/session/ses_1/move")?["directory"] == .string("/data/wt/new"))
}

@MainActor @Test func moveTargetsListTheProjectWithoutTheCurrentDirectory() async throws {
    let transport = AdminTransport(["GET /api/worktree": [.init(body: .array([
        .object(["directory": .string("/p")]), .object(["directory": .string("/wt/b"), "strategy": .string("git"), "branch": .string("b")]),
        .object(["directory": .string("/wt/a"), "strategy": .string("git")]),
    ]))]])
    let store = featureStore(transport)
    store.sessions["ses_1"]?.info["location"] = .object(["directory": .string("/wt/a")])
    let targets = try await store.moveTargets("ses_1")
    #expect(targets.map(\.id) == ["new", "/p", "/wt/b"])
    #expect(targets.map(\.kind) == [.newWorktree, .checkout, .worktree])
    #expect(targets[2].title == "b" && targets[1].title == "Project checkout")
}

@MainActor @Test func sideQuestionAnswersWithoutTouchingTheHistory() async {
    let transport = AdminTransport(["POST /api/session/ses_1/generate": [.init(body: .object(["data": .object(["text": .string("**42**")])]))]])
    let store = featureStore(transport)
    let before = store.sessions["ses_1"]?.transcript?.order
    store.askSideQuestion("ses_1", question: "  what is it?  ")
    #expect(store.sideQuestions["ses_1"] == SideQuestion(question: "what is it?", state: .asking))
    await settle { store.sideQuestions["ses_1"]?.state != .asking }
    #expect(store.sideQuestions["ses_1"]?.state == .answered("**42**"))
    let prompt = transport.body(of: "POST /api/session/ses_1/generate")?["prompt"]?.stringValue ?? ""
    #expect(prompt.hasPrefix("The user is asking a quick side question") && prompt.hasSuffix("\n\nwhat is it?"))
    #expect(store.sessions["ses_1"]?.transcript?.order == before)
    #expect(store.outboxEntries.isEmpty, "Nothing is admitted to the session")
    store.dismissSideQuestion("ses_1")
    #expect(store.sideQuestions["ses_1"] == nil)
}

@MainActor @Test func sideQuestionFailureCanBeRetried() async {
    let transport = AdminTransport(["POST /api/session/ses_1/generate": [.init(status: 503, body: .object(["_tag": .string("ServiceUnavailableError"), "message": .string("Generation is unavailable")])),
                                                                          .init(body: .object(["data": .object(["text": .string("ok")])]))]])
    let store = featureStore(transport)
    store.askSideQuestion("ses_1", question: "why")
    await settle { store.sideQuestions["ses_1"]?.state != .asking }
    guard case .failed? = store.sideQuestions["ses_1"]?.state else { Issue.record("Expected a failure"); return }
    store.askSideQuestion("ses_1", question: "why")
    await settle { store.sideQuestions["ses_1"]?.state == .answered("ok") }
    store.askSideQuestion("ses_1", question: "   ")
    #expect(store.sideQuestions["ses_1"]?.question == "why", "An empty question is ignored")
}

@MainActor @Test func exportAndStatisticsUseTheirRoutes() async throws {
    let transport = AdminTransport([
        "GET /api/experimental/session/ses_1/export": [.init(body: .object(["data": .object(["info": .object(["id": .string("ses_1"), "title": .string("T")]), "messages": .array([])])]))],
        "GET /api/experimental/session/stats": [.init(body: .object(["data": .object(["sessions": .integer(2), "prompts": .integer(3)])]))],
    ])
    let store = featureStore(transport)
    let transfer = try await store.exportSession("ses_1", sanitize: true)
    #expect(transfer["info"]?["id"] == .string("ses_1"))
    let file = try await store.exportFile("ses_1", format: .markdown, sanitize: false)
    #expect(file.lastPathComponent == "fix-the-parser.md")
    #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("# T\n"))
    let redacted = try await store.exportFile("ses_1", format: .json, sanitize: true)
    #expect(redacted.lastPathComponent == "ses_1.json", "A redacted export is not named after the real title")
    let stats = try await store.stats(StatsRange(.week, now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!), projectID: "prj")
    #expect(stats.sessions == 2 && stats.prompts == 3 && stats.steps == 0)
    let missing = AdminTransport()
    await #expect(throws: UserFacingError.self) { try await featureStore(missing).exportFile("ses_1", format: .json, sanitize: true) }
}

@MainActor @Test func promptHistoryRecallsSessionThenProjectPrompts() {
    let store = featureStore(AdminTransport())
    store.seed(info: SessionInfo(raw: .object(["id": .string("ses_2"), "projectID": .string("prj"), "location": .object(["directory": .string("/p")]),
        "time": .object(["created": .integer(1), "updated": .integer(1)])])), messages: [
        SessionMessage(raw: .object(["id": .string("msg_9"), "type": .string("user"), "text": .string("other project prompt"), "time": .object(["created": .integer(99)])])),
        SessionMessage(raw: .object(["id": .string("msg_8"), "type": .string("user"), "text": .string("first"), "time": .object(["created": .integer(98)])])),
    ])
    store.seed(info: SessionInfo(raw: .object(["id": .string("ses_3"), "projectID": .string("elsewhere"), "location": .object(["directory": .string("/q")]),
        "time": .object(["created": .integer(1), "updated": .integer(1)])])), messages: [
        SessionMessage(raw: .object(["id": .string("msg_7"), "type": .string("user"), "text": .string("unrelated"), "time": .object(["created": .integer(97)])])),
    ])
    #expect(store.promptHistory("ses_1", directory: "/p").map(\.text) == ["second", "first", "other project prompt"])
}

// MARK: Voice

@MainActor private final class FakeRecognizer: SpeechRecognizing {
    var authorization = VoiceAuthorization.granted
    var continuation: AsyncThrowingStream<VoiceTranscript, any Error>.Continuation?
    var starts: [[String]] = []
    var stops = 0
    func authorize() async -> VoiceAuthorization { authorization }
    func start(contextualStrings: [String]) async throws -> AsyncThrowingStream<VoiceTranscript, any Error> {
        starts.append(contextualStrings)
        let (stream, continuation) = AsyncThrowingStream<VoiceTranscript, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }
    func stop() async { stops += 1; continuation?.finish() }
}
@MainActor private final class FakeSpeaker: SpeechSpeaking {
    var spoken: [String] = []
    func speak(_ text: String) async { spoken.append(text) }
    func stopSpeaking() {}
}

@MainActor @Test func voiceDeniedPermissionStopsBeforeListening() async {
    let recognizer = FakeRecognizer(); recognizer.authorization = .denied("Microphone access is off.")
    let voice = VoiceModel(recognizer: recognizer, speaker: FakeSpeaker(), clock: TestClock())
    voice.start(.dictation)
    await settle { voice.state != .starting }
    #expect(voice.state == .denied("Microphone access is off."))
    #expect(recognizer.starts.isEmpty && !voice.active)
    voice.dismissError()
    #expect(voice.state == .idle)
}

@MainActor @Test func dictationShowsPartialAndFinalTextAndReturnsIt() async {
    let recognizer = FakeRecognizer()
    let voice = VoiceModel(recognizer: recognizer, speaker: FakeSpeaker(), clock: TestClock())
    voice.start(.dictation, contextualStrings: ["ReadStore"])
    await settle { voice.state == .listening }
    #expect(recognizer.starts == [["ReadStore"]])
    recognizer.continuation?.yield(.init(text: "open read", isFinal: false))
    await settle { voice.volatile == "open read" }
    #expect(voice.transcript == "open read")
    recognizer.continuation?.yield(.init(text: "open ReadStore", isFinal: true))
    recognizer.continuation?.yield(.init(text: "and", isFinal: false))
    await settle { voice.volatile == "and" }
    #expect(voice.final == "open ReadStore" && voice.transcript == "open ReadStore and")
    #expect(voice.stop() == "open ReadStore and")
    #expect(voice.state == .idle && voice.transcript.isEmpty)
}

@MainActor @Test func handsFreeSendsAfterAPauseUnlessCancelled() async {
    let recognizer = FakeRecognizer(), speaker = FakeSpeaker(), clock = TestClock()
    let voice = VoiceModel(recognizer: recognizer, speaker: speaker, clock: clock, pause: .seconds(2), countdown: 3)
    var sent: [String] = []
    voice.send = { text in sent.append(text); return "The reply." }
    voice.start(.handsFree)
    await settle { voice.state == .listening }
    recognizer.continuation?.yield(.init(text: "run the tests", isFinal: true))
    await settle { voice.final == "run the tests" }
    await clock.advance(by: .seconds(2))
    await settle { voice.state == .countdown(3) }
    voice.cancelCountdown()
    #expect(voice.state == .listening)
    await clock.advance(by: .seconds(5))
    #expect(sent.isEmpty, "A cancelled countdown never sends")
    #expect(voice.transcript == "run the tests", "The transcript stays visible")
    recognizer.continuation?.yield(.init(text: "please", isFinal: true))
    await settle { voice.final == "run the tests please" }
    await clock.advance(by: .seconds(2))
    await settle { voice.state == .countdown(3) }
    await clock.advance(by: .seconds(1)); await settle { voice.state == .countdown(2) }
    await clock.advance(by: .seconds(1)); await settle { voice.state == .countdown(1) }
    await clock.advance(by: .seconds(1))
    await settle { sent == ["run the tests please"] }
    await settle { speaker.spoken == ["The reply."] }
    await settle { voice.state == .listening && recognizer.starts.count == 2 }
    #expect(voice.transcript.isEmpty, "The next turn starts empty")
    voice.stop()
    #expect(voice.state == .idle)
}

@MainActor @Test func handsFreeWithoutSpeechNeverCountsDown() async {
    let recognizer = FakeRecognizer(), clock = TestClock()
    let voice = VoiceModel(recognizer: recognizer, speaker: FakeSpeaker(), clock: clock)
    var sent = 0
    voice.send = { _ in sent += 1; return nil }
    voice.start(.handsFree)
    await settle { voice.state == .listening }
    recognizer.continuation?.yield(.init(text: "  ", isFinal: false))
    await settle { voice.volatile == "  " }
    await clock.advance(by: .seconds(30))
    #expect(voice.state == .listening && sent == 0)
    voice.stop()
}

@MainActor @Test func voiceRecognizerFailureIsShown() async {
    struct Broken: Error, LocalizedError { var errorDescription: String? { "no model" } }
    let recognizer = FakeRecognizer()
    let voice = VoiceModel(recognizer: recognizer, speaker: FakeSpeaker(), clock: TestClock())
    voice.start(.dictation)
    await settle { voice.state == .listening }
    recognizer.continuation?.finish(throwing: Broken())
    await settle { voice.state != .listening }
    #expect(voice.state == .failed("Voice input stopped: no model"))
}

@MainActor @Test func busyTimeIsProjectedOnlyForServersThatReportIt() {
    let started = event(.object(["id": .string("evt_start1"), "type": .string("session.execution.started"), "created": .integer(500),
        "data": .object(["sessionID": .string("ses_1")]), "durable": .object(["aggregateID": .string("ses_1"), "seq": .integer(3), "version": .integer(1)])]))
    let old = featureStore(AdminTransport())
    old.apply(started)
    #expect(old.sessions["ses_1"]?.info.raw["time"]?["busy"] == nil, "2.0.32 session info has no busy time")
    #expect(old.sessions["ses_1"]?.turnStartedAt == 500)
    let current = featureStore(AdminTransport())
    current.projectsBusyTime = true
    current.apply(started)
    #expect(current.sessions["ses_1"]?.info.raw["time"]?["busy"]?.wireNumber == 500, "2.2.2 sets busy to the turn's start")
    #expect(ServerInfo(version: "2.2.2").reportsBusyTime && !ServerInfo(version: "2.2.1").reportsBusyTime && !ServerInfo(version: "2.0.32").reportsBusyTime)
}
