import Foundation
import Clocks
import Testing
import OCFoundation
import OCModels
import OCNetworking
@testable import OCSync

private actor Pages {
    var pages: [[SessionMessage]]
    var queries: [[URLQueryItem]] = []
    init(_ pages: [[SessionMessage]]) { self.pages = pages }
    func response(_ request: URLRequest) throws -> JSONValue {
        queries.append(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
        let rows = pages.removeFirst()
        return .object(["data": .array(rows.reversed().map(\.raw)), "cursor": .object(pages.isEmpty ? [:] : ["next": .string("page-\(queries.count)")])])
    }
}
@Test @MainActor func gapSplicesOverlapAndDisconnectedRevert() async throws {
    let pages = Pages([[readRow("d"), readRow("e")], [readRow("b"), readRow("c")], [readRow("a")]])
    let api = readAPI { try await pages.response($0) }
    let store = ReadStore(serverID: "server")
    let transcript = TranscriptModel(messages: [readRow("a"), readRow("b"), readRow("doomed")], olderCursor: "cached-older")
    let splice = try await store.fetchSplice("s", transcript: transcript, api: api, limit: 2)
    #expect(splice.rows.map(\.id) == ["a", "b", "c", "d", "e"])
    #expect(splice.cursor == "cached-older")
    let queries = await pages.queries
    #expect(queries.count == 2)
    #expect(!queries[1].contains { $0.name == "order" })
}
@Test @MainActor func gapResetsAfterFourOlderPages() async throws {
    let pages = Pages((0..<7).map { [readRow(String($0))] })
    let api = readAPI { try await pages.response($0) }
    let store = ReadStore(serverID: "server")
    let transcript = TranscriptModel(messages: [readRow("old")])
    let splice = try await store.fetchSplice("s", transcript: transcript, api: api, limit: 1)
    #expect(splice.rows.map(\.id) == ["0"]); #expect(splice.cursor == "page-1")
    #expect(await pages.queries.count == 5)
}
@Test @MainActor func initialOpenFetchesOnlyTheNewestPage() async throws {
    let pages = Pages([[readRow("newest")], [readRow("older")]])
    let store = ReadStore(serverID: "server")
    let splice = try await store.fetchSplice("s", transcript: TranscriptModel(), api: readAPI { try await pages.response($0) }, limit: 1)
    #expect(splice.rows.map(\.id) == ["newest"] && splice.cursor == "page-1")
    #expect(await pages.queries.count == 1)
}
@Test @MainActor func snapshotFetchKeepsLiveRowsAndDeletionMarkers() async throws {
    let store = ReadStore(serverID: "server")
    store.seed(info: readInfo(), messages: [readRow("m", type: "assistant")])
    let staleInbox: JSONValue = .object(["id": .string("queued"), "sessionID": .string("s"), "type": .string("user"), "delivery": .string("queue"), "payload": .object(["text": .string("obsolete")])])
    let api = readAPI { request in
        let path = request.url?.path ?? ""
        if path.hasSuffix("/message") {
            try await MainActor.run {
                store.apply(try readEvent("session.text.ended", seq: 10, data: ["assistantMessageID": .string("m"), "ordinal": .integer(0), "text": .string("live")]))
                store.apply(try readEvent("session.inbox.cancelled", seq: 11, data: ["inboxID": .string("queued")]))
                store.apply(try readEvent("session.renamed", seq: 12, data: ["title": .string("live title")]))
                store.apply(try readEvent("permission.replied", data: ["requestID": .string("per"), "reply": .string("once")]))
                store.apply(try readEvent("form.cancelled", data: ["id": .string("form")]))
            }
            return .object(["data": .array([readRow("m", type: "assistant").raw]), "cursor": .object([:])])
        }
        if path.hasSuffix("/inbox") { return .object(["data": .array([staleInbox])]) }
        if path.hasSuffix("/permission") { return .object(["data": .array([.object(["id": .string("per"), "sessionID": .string("s")])])]) }
        if path.hasSuffix("/form") { return .object(["data": .array([.object(["id": .string("form"), "sessionID": .string("s")])])]) }
        return .object(["data": readInfo().raw])
    }
    store.client = { api }
    try await store.refreshSession("s")
    #expect(store.sessions["s"]?.info.title == "live title")
    #expect(store.sessions["s"]?.transcript?.messages["m"]?.items.first?.text == "live")
    #expect(store.sessions["s"]?.pending.isEmpty == true)
    #expect(store.permissions["s"]?.isEmpty == true); #expect(store.forms[.session("s")]?.isEmpty == true)
    #expect(store.sessions["s"]?.lastSeq == nil)
    await store.stop()
}
private actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
@Test @MainActor func backwardsAndUnknownDurableEventsDebounceRefetch() async throws {
    let time = SyncTime(), counter = Counter(), store = ReadStore(serverID: "server", clock: time.clock)
    store.seed(info: readInfo(), messages: [])
    store.client = { readAPI { request in
        if request.url?.path == "/api/session/s" { _ = await counter.next(); return .object(["data": readInfo().raw]) }
        return .object(["data": .array([]), "cursor": .object([:])])
    } }
    store.apply(try readEvent("session.renamed", seq: 20, data: ["title": .string("new")]))
    store.apply(try readEvent("session.renamed", seq: 19, data: ["title": .string("old")]))
    store.apply(try readEvent("session.future", seq: 21))
    #expect(store.sessions["s"]?.info.title == "new")
    #expect(await counter.value == 0)
    await time.test.advance(by: .milliseconds(500))
    await settle { await counter.value == 1 }
    await store.stop()
}
@Test @MainActor func activeFetchOverlayAndBacklogResync() async throws {
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo())
    let api = readAPI { request in
        if request.url?.path == "/api/session/active" {
            try await MainActor.run { store.apply(try readEvent("session.execution.succeeded", seq: 2)) }
            return .object(["data": .object(["s": .object(["type": .string("running")])])])
        }
        if request.url?.path == "/api/project" { return .array([]) }
        return .object(["data": .array([readInfo().raw]), "cursor": .object([:])])
    }
    store.client = { api }
    try await store.resync(reason: .backlogOverflow)
    #expect(store.running.isEmpty); #expect(store.sessions["s"]?.status == .idle)
    #expect(store.sessions["s"]?.info.outcome == "succeeded")
    await store.stop()
}
@Test @MainActor func resyncDropsRequestsAnsweredWhileDisconnected() async throws {
    // Neither running nor open: before the fix, resync never refetched this session's location requests.
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo())
    store.apply(try readEvent("permission.asked", data: ["id": .string("per"), "action": .string("bash")]))
    store.apply(try readEvent("form.created", data: ["form": .object(["id": .string("form"), "sessionID": .string("s")])]))
    // A location's global form, which the badge counts too.
    store.apply(try readEvent("form.created", session: "global", data: ["form": .object(["id": .string("global-form"), "sessionID": .string("global")])]))
    let global = FormOwner.global(location: Location(directory: "/p").key)
    #expect(store.permissions["s"]?.map(\.id) == ["per"]); #expect(store.forms[.session("s")]?.map(\.id) == ["form"])
    #expect(store.forms[global]?.map(\.id) == ["global-form"])
    store.client = { readAPI { request in
        switch request.url?.path {
        case "/api/session/active": return .object(["data": .object([:])])
        case "/api/project": return .array([])
        case "/api/permission/request", "/api/form": return .object(["location": .object(["directory": .string("/p")]), "data": .array([])])
        default: return .object(["data": .array([readInfo().raw]), "cursor": .object([:])])
        }
    } }
    try await store.resync(reason: .backlogOverflow)
    #expect(store.permissions["s"]?.isEmpty == true)
    #expect(store.forms[.session("s")]?.isEmpty == true)
    #expect(store.forms[global]?.isEmpty == true)
    await store.stop()
}
@Test @MainActor func resyncDropsAGlobalFormAnsweredWhileDisconnected() async throws {
    // Only a location's global form is pending: no session request pulls its location into the refetch.
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo())
    store.apply(try readEvent("form.created", session: "global", data: ["form": .object(["id": .string("global-form"), "sessionID": .string("global")])]))
    let global = FormOwner.global(location: Location(directory: "/p").key)
    #expect(store.forms[global]?.map(\.id) == ["global-form"])
    store.client = { readAPI { request in
        switch request.url?.path {
        case "/api/session/active": return .object(["data": .object([:])])
        case "/api/project": return .array([])
        case "/api/permission/request", "/api/form": return .object(["location": .object(["directory": .string("/p")]), "data": .array([])])
        default: return .object(["data": .array([readInfo().raw]), "cursor": .object([:])])
        }
    } }
    try await store.resync(reason: .backlogOverflow)
    #expect(store.forms[global]?.isEmpty == true)
    await store.stop()
}
@Test @MainActor func revalidationSerializesAndDiscardsStaleResponses() async throws {
    let cell = Revalidating<Int>(), counter = Counter()
    let result = try await cell.load {
        let n = await counter.next()
        if n == 1 { cell.invalidate() }
        return n
    }
    #expect(result == 2); #expect(cell.value == 2); #expect(!cell.isLoading)
}

@Test @MainActor func disappearingCatalogConsumerDoesNotCancelSharedLoad() async throws {
    let cell = Revalidating<Int>()
    var continuation: CheckedContinuation<Void, Never>?
    let first = Task {
        try await cell.load {
            await withCheckedContinuation { continuation = $0 }
            try Task.checkCancellation()
            return 42
        }
    }
    while continuation == nil { await Task.yield() }
    var joined = false
    let second = Task {
        joined = true
        return try await cell.load { Issue.record("The concurrent load must be coalesced"); return 0 }
    }
    while !joined { await Task.yield() }
    first.cancel()
    try #require(continuation).resume()
    #expect(try await second.value == 42)
    do { _ = try await first.value; Issue.record("The disappearing consumer must remain cancelled") }
    catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    #expect(cell.value == 42 && !cell.isLoading)
    cell.stop()
}

@Test @MainActor func stoppingCatalogCancelsItsOwnedLoad() async throws {
    let cell = Revalidating<Int>()
    var started = false
    let consumer = Task {
        try await cell.load {
            started = true
            try await Task.sleep(for: .seconds(60))
            return 42
        }
    }
    while !started { await Task.yield() }
    cell.stop()
    do { _ = try await consumer.value; Issue.record("Stopping the cache must cancel its fetch") }
    catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    #expect(cell.value == nil && !cell.isLoading)
}

@Test @MainActor func activeSnapshotKeepsNewerRetryStatus() async throws {
    let store = ReadStore(serverID: "server"); store.seed(info: readInfo())
    store.client = { readAPI { request in
        switch request.url?.path {
        case "/api/session/active":
            try await MainActor.run {
                store.apply(try readEvent("session.retry.scheduled", seq: 3, data: ["assistantMessageID": .string("m"), "attempt": .integer(2), "at": .integer(500)]))
            }
            return .object(["data": .object(["s": .object(["type": .string("running")])])])
        case "/api/project": return .array([])
        case "/api/session": return .object(["data": .array([readInfo().raw])])
        default: return .object(["location": .object(["directory": .string("/p")]), "data": .array([])])
        }
    } }
    try await store.resync(reason: .backlogOverflow)
    #expect(store.sessions["s"]?.status == .retrying(attempt: 2, at: 500))
    await store.stop()
}

@Test(arguments: [false, true]) @MainActor func paginationCannotRestoreConcurrentRevert(jump: Bool) async throws {
    let store = ReadStore(serverID: "server")
    store.seed(info: readInfo(), messages: [readRow("d")])
    store.sessions["s"]?.transcript?.olderCursor = "older"
    store.client = { readAPI { _ in
        try await MainActor.run { store.apply(try readEvent("session.revert.committed", seq: 10, data: ["to": .string("b")])) }
        let rows = [readRow("a"), readRow("b"), readRow("c")]
        return .object(["data": .array((jump ? rows : Array(rows.reversed())).map(\.raw)), "cursor": .object([:])])
    } }
    if jump { try await store.jumpToStart("s") } else { try await store.loadOlder("s") }
    #expect(store.sessions["s"]?.transcript?.order == ["a"])
    await store.stop()
}

@Test @MainActor func attentionFetchesUnknownParents() async throws {
    let time = SyncTime(), store = ReadStore(serverID: "server", clock: time.clock)
    store.seed(info: readInfo("child", parent: "root"))
    store.client = { readAPI { request in
        if request.url?.path == "/api/session/root" { return .object(["data": readInfo("root").raw]) }
        return .object(["data": .array([]), "cursor": .object([:])])
    } }
    store.apply(try readEvent("permission.asked", session: "child", data: ["id": .string("per"), "action": .string("edit"), "resources": .array([])]))
    await time.test.advance(by: .milliseconds(500))
    await settle { store.sessions["root"]?.attention == 1 }
    #expect(store.sessions["root"]?.attention == 1)
    await store.stop()
}

@Test @MainActor func shortNewestPageWithCursorEndsHistory() async throws {
    let pages = Pages([[readRow("a"), readRow("b"), readRow("c")], []])
    let store = ReadStore(serverID: "server")
    let splice = try await store.fetchSplice("s", transcript: TranscriptModel(), api: readAPI { try await pages.response($0) })
    #expect(splice.rows.map(\.id) == ["a", "b", "c"] && splice.cursor == nil)
    #expect(await pages.queries.count == 1)
}

@Test @MainActor func shortOlderPageEndsSpliceAndLoadOlder() async throws {
    let pages = Pages([[readRow("d"), readRow("e")], [readRow("b")], []])
    let store = ReadStore(serverID: "server")
    let transcript = TranscriptModel(messages: [readRow("b"), readRow("c")], olderCursor: "stale")
    let splice = try await store.fetchSplice("s", transcript: transcript, api: readAPI { try await pages.response($0) }, limit: 2)
    #expect(splice.cursor == nil && splice.rows.map(\.id) == ["b", "d", "e"])
    #expect(await pages.queries.count == 2)
    let older = Pages([[readRow("a")], []])
    store.client = { readAPI { try await older.response($0) } }
    store.seed(info: readInfo(), messages: [readRow("b")])
    store.sessions["s"]?.transcript?.olderCursor = "cursor"
    try await store.loadOlder("s")
    #expect(store.sessions["s"]?.transcript?.olderCursor == nil)
    #expect(store.sessions["s"]?.transcript?.isAtStart == true)
    #expect(store.sessions["s"]?.transcript?.order == ["a", "b"])
    try await store.loadOlder("s")
    #expect(await older.queries.count == 1)
    await store.stop()
}

@Test func fullPageWithMalformedRowsRetainsItsCursor() throws {
    let raw: JSONValue = .object(["data": .array([.string("valid"), .object(["malformed": .bool(true)])]),
                                  "cursor": .object(["next": .string("older")])])
    let page = try JSONDecoder().decode(Page<String>.self, from: JSONEncoder().encode(raw))
    #expect(page.data.count == 1)
    #expect(page.nextCursor(limit: 2) == "older")
    #expect(page.nextCursor(limit: 3) == nil)
}

@Test @MainActor func shortSessionListDoesNotOfferAnotherPage() async throws {
    let store = ReadStore(serverID: "server", client: { readAPI { _ in
        .object(["data": .array([readInfo().raw]), "cursor": .object(["next": .string("unused")])])
    } })
    #expect(try await store.listSessions() == nil)
    #expect(store.rootCursor == nil)
    await store.stop()
}

@Test @MainActor func completeHistoryKeepsTheFetchedPrefixBeforeAnOverlap() async throws {
    let pages = Pages([[readRow("a"), readRow("b"), readRow("c"), readRow("d")], []])
    let store = ReadStore(serverID: "server")
    let transcript = TranscriptModel(messages: [readRow("c"), readRow("removed")], olderCursor: "old")
    let splice = try await store.fetchSplice("s", transcript: transcript, api: readAPI { try await pages.response($0) })
    #expect(splice.rows.map(\.id) == ["a", "b", "c", "d"])
    #expect(splice.cursor == nil)
}
private actor ArchiveFilters {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
@Test(arguments: [false, true]) @MainActor func archivedSessionsAreListedApartFrom2_1(apart: Bool) async throws {
    #expect(ServerInfo(version: "2.1.0").filtersArchivedSessions && !ServerInfo(version: "2.0.32").filtersArchivedSessions)
    let store = ReadStore(serverID: "server")
    store.seed(info: readInfo("kept")); store.seed(info: readInfo("away"))
    store.filtersArchived = apart
    func archived(_ id: String) -> JSONValue {
        var raw = readInfo(id).raw; raw.set(["time", "archived"], .integer(5)); raw.set(["time", "updated"], .integer(5)); return raw
    }
    let filters = ArchiveFilters(), away = archived("away"), other = archived("other"), kept = readInfo("kept").raw
    store.client = { readAPI { request in
        switch request.url?.path {
        case "/api/session/active": return .object(["data": .object([:])])
        case "/api/project": return .array([])
        case "/api/session":
            let filter = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "archived" }?.value
            await filters.record(filter ?? "both")
            // A 2.0.x server ignores the filter and lists both.
            let rows = filter == "false" ? [kept] : filter == "true" ? [away, other] : [kept, away]
            return .object(["data": .array(rows), "cursor": .object([:])])
        default: return .object(["data": .array([]), "cursor": .object([:])])
        }
    } }
    try await store.resync(reason: .backlogOverflow)
    #expect(await filters.values.sorted() == (apart ? ["false", "true"] : ["both"]))
    #expect(store.sessions["away"]?.info.time.archived == 5, "Archived while the app was away")
    #expect(store.sessions["other"] == nil, "Archived sessions the app never held stay unloaded")
    _ = try await store.listSessions()
    #expect(await filters.values.last == (apart ? "false" : "both"), "Home's own pages")
    await store.stop()
}
