import Foundation
import Testing
import Clocks
import OCFoundation
import OCIntents
import OCModels
import OCNetworking
import OCPersistence
import OCSecurity
import OCShared
@testable import OCSync

enum IndexCall: Equatable, Sendable { case index([String]), delete([String]), domains([String]), deleteAll }

/// What Spotlight was asked to do, and what it would hold.
actor RecordingIndex: SpotlightIndexing {
    var calls: [IndexCall] = []
    var items: [String: SpotlightItem] = [:]
    var fails = false
    func index(_ values: [SpotlightItem]) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        calls.append(.index(values.map(\.session))); for item in values { items[item.id] = item }
    }
    func delete(ids: [String]) { calls.append(.delete(ids.map { String($0.split(separator: ":").last ?? "") })); for id in ids { items[id] = nil } }
    func delete(domains: [String]) { calls.append(.domains(domains)); items = items.filter { !domains.contains($0.value.domain) } }
    func deleteAll() throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        calls.append(.deleteAll); items = [:]
    }
    func reset() { calls = [] }
    func failing(_ value: Bool) { fails = value }
}

@MainActor final class SystemLog {
    var reloads: [Set<SystemReload>] = []
    var shortcuts = 0
}

/// A registry with one server, its system integration on a test clock, and fakes for Spotlight and the reloads.
@MainActor final class SystemHarness {
    let time = SyncTime()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let index = RecordingIndex()
    let log = SystemLog()
    let connection = FakeConnection()
    let suite: String
    let defaults: UserDefaults
    let registry: ServerRegistry
    let system: SystemIntegration
    private(set) var server: ServerStore!
    var store: SystemSnapshotStore { SystemSnapshotStore(directory: root.appending(path: "group")) }
    init(spotlight: Bool = true, manifest: Data? = nil) throws {
        suite = "system-tests-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        if !spotlight { defaults.set(false, forKey: SystemIntegration.spotlightKey) }
        if let manifest {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try manifest.write(to: root.appending(path: "spotlight.json"))
        }
        let connection = connection
        registry = ServerRegistry(records: MemoryRecords(), credentials: CredentialStore(secrets: InMemorySecretStore()), cache: CacheStore(writer: try PersistenceWriter()),
                                  clock: time.clock, pathMonitor: nil, localNetworkExplained: true, factory: { _, _, _ in connection })
        let log = log
        system = SystemIntegration(store: SystemSnapshotStore(directory: root.appending(path: "group")), index: index, manifest: root.appending(path: "spotlight.json"),
                                   defaults: defaults, clock: time.clock, reload: { log.reloads.append($0) }, shortcutsChanged: { log.shortcuts += 1 })
        registry.system = system
    }
    func start() async throws {
        await registry.load()
        let endpoint = EndpointRecord(url: try #require(URL(string: "https://studio.example.invalid")), kind: .https)
        server = try await registry.add(.init(name: "Studio Mac", endpoints: [endpoint]), credential: .password("p4ss-w0rd-secret"))
        server.readPath.projects = [Project(raw: .object(["id": .string("prj"), "name": .string("opencode-ios"), "canonical": .string("/Users/Shared/opencode-ios"),
                                                          "time": .object(["active": .number(1_790_000_040_000)])]))]
    }
    /// Lets the owned tasks run, then moves the clock.
    func advance(_ seconds: Double) async {
        for _ in 0..<50 { await Task.yield() }
        await time.test.advance(by: .milliseconds(Int(seconds * 1_000)))
        for _ in 0..<50 { await Task.yield() }
    }
    func seed(_ id: String, title: String? = nil, parent: String? = nil, outcome: String? = nil, unread: Bool = false, archived: Bool = false, updated: Double = 1_790_000_000_000) {
        var time: [String: JSONValue] = ["created": .number(updated - 60_000), "updated": .number(updated)]
        if unread { time["idle"] = .number(updated); time["viewed"] = .number(updated - 1) }
        if archived { time["archived"] = .number(updated) }
        var raw: [String: JSONValue] = ["id": .string(id), "projectID": .string("prj"), "title": .string(title ?? "Title " + id), "time": .object(time),
                                        "location": .object(["directory": .string("/Users/Shared/opencode-ios")])]
        if let parent { raw["parentID"] = .string(parent) }
        if let outcome { raw["outcome"] = .string(outcome) }
        server.readPath.seed(info: SessionInfo(raw: .object(raw)), messages: [])
    }
    func snapshot() throws -> SystemSnapshot { try #require(store.read().snapshot) }
    func cleanUp() async {
        await registry.shutdown()
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

private func permission(_ id: String, session: String) -> PermissionRequest {
    .init(raw: .object(["id": .string(id), "sessionID": .string(session), "action": .string("edit"), "resources": .array([.string("/Users/Shared/opencode-ios/file")])]))
}
private func form(_ id: String, session: String) -> FormInfo {
    .init(raw: .object(["id": .string(id), "sessionID": .string(session), "fields": .array([])]))
}

@MainActor @Suite(.serialized) struct SystemSnapshotPublisherTests {
    @Test func theSnapshotIsHomeInTitlesAndStatesWithNoSecrets() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_ask"); harness.seed("ses_child", parent: "ses_ask"); harness.seed("ses_form"); harness.seed("ses_fail", outcome: "failed", unread: true)
        harness.seed("ses_run", updated: 1_790_000_100_000); harness.seed("ses_idle", updated: 1_789_000_000_000)
        harness.seed("ses_hidden"); harness.seed("ses_archived", archived: true)
        let readPath = harness.server.readPath
        readPath.permissions["ses_child"] = [permission("per_1", session: "ses_child")]
        readPath.forms[.session("ses_form")] = [form("frm_1", session: "ses_form")]
        readPath.sessions["ses_run"]?.status = .running(since: 1_790_000_040_000); readPath.running.insert("ses_run")
        readPath.localMeta["ses_hidden"] = .init(hidden: true)
        harness.system.flush()
        let snapshot = try harness.snapshot()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.session, $0) })
        #expect(Set(byID.keys) == ["ses_ask", "ses_form", "ses_fail", "ses_run", "ses_idle"], "Roots only; hidden and archived sessions stay out")
        #expect(byID["ses_ask"]?.status == .needsYou && byID["ses_ask"]?.requests == 1 && byID["ses_ask"]?.request == .init(id: "per_1", kind: .permission, session: "ses_child"))
        #expect(byID["ses_form"]?.request?.kind == .question && byID["ses_fail"]?.status == .failed && byID["ses_fail"]?.request?.kind == .failure)
        #expect(byID["ses_run"]?.status == .running && byID["ses_run"]?.runningSince == Date(timeIntervalSince1970: 1_790_000_040))
        #expect(byID["ses_run"]?.activity == Date(timeIntervalSince1970: 1_790_000_100), "Activity to the minute")
        #expect(byID["ses_idle"]?.status == .idle && byID["ses_ask"]?.project == "opencode-ios")
        #expect(snapshot.projects == [.init(server: harness.server.id.rawValue.uuidString, project: "prj", name: "opencode-ios", activity: Date(timeIntervalSince1970: 1_790_000_040))])
        #expect(snapshot.servers.map(\.name) == ["Studio Mac"] && snapshot.servers.first?.reachability == .paused)
        let json = String(decoding: try Data(contentsOf: harness.root.appending(path: "group/snapshot.json")), as: UTF8.self)
        for secret in ["p4ss-w0rd-secret", "studio.example.invalid", "/Users/Shared", "Authorization"] { #expect(!json.contains(secret), "\(secret)") }
        await harness.cleanUp()
    }
    @Test func writesAreCoalescedAndOnlyChangedKindsReload() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a")
        await harness.advance(1)
        let writes = harness.log.reloads.count
        #expect(writes >= 1, "The server and its session were written")
        harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Draft 1")
        await harness.advance(0.5)
        #expect(harness.log.reloads.count == writes, "Nothing yet: a write waits a second for more changes")
        for value in 2...5 { harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Draft \(value)"); await harness.advance(0.1) }
        await harness.advance(0.2)
        #expect(harness.log.reloads.count == writes + 1 && harness.log.reloads.last == [.widget(.recent)], "Five changes, one write, and only Recent shows titles that changed")
        #expect(try harness.snapshot().sessions.first?.title == "Draft 5")
        harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Draft 5")
        await harness.advance(2)
        #expect(harness.log.reloads.count == writes + 1, "The same content is not written again")
        // A session that keeps changing writes at most once a second.
        for value in 0..<10 { harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Stream \(value)"); await harness.advance(0.5) }
        await harness.advance(1)
        #expect((writes + 3...writes + 6).contains(harness.log.reloads.count), "Ten changes in five seconds: \(harness.log.reloads.count - writes - 1) writes")
        #expect(try harness.snapshot().sessions.first?.title == "Stream 9")
        harness.server.readPath.permissions["ses_a"] = [permission("per_1", session: "ses_a")]
        await harness.advance(1.5)
        #expect(harness.log.reloads.last == [.widget(.needsYou), .control(.reviewApproval), .widget(.recent)])
        await harness.cleanUp()
    }
    @Test func onlineServersAreRewrittenBeforeTheirWidgetsTurnStale() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a")
        await harness.connection.emit(.state(.connected(harness.server.record.endpoints[0].id, since: .now)))
        await harness.advance(1.5)
        #expect(try harness.snapshot().servers.first?.reachability == .online)
        let written = try harness.snapshot().writtenAt, count = harness.log.reloads.count
        // A change that leaves the snapshot as it was neither writes nor postpones the heartbeat.
        await harness.advance(10 * 60)
        harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Title ses_a")
        await harness.advance(1.5)
        #expect(harness.log.reloads.count == count)
        // Nor does a write that reloads only Recent: Needs you and Running still show the snapshot they last read.
        harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Renamed")
        await harness.advance(1.5)
        #expect(harness.log.reloads.count == count + 1 && harness.log.reloads.last == [.widget(.recent)])
        await harness.advance(20 * 60)
        #expect(try harness.snapshot().writtenAt > written && harness.log.reloads.count == count + 2, "Thirty minutes after every kind last reloaded")
        #expect(harness.log.reloads.last == Set(WidgetKind.allCases.map(SystemReload.widget)), "The heartbeat reloads the widgets only")
        await harness.cleanUp()
    }
    @Test func aReconnectThatKeepsRetryingWritesOnce() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        let endpoint = harness.server.record.endpoints[0].id
        await harness.connection.emit(.state(.connected(endpoint, since: .now)))
        await harness.advance(1.5)
        await harness.connection.emit(.state(.waiting(attempt: 1, retryAt: harness.time.clock.now(), failure: .transport)))
        await harness.advance(1.5)
        #expect(try harness.snapshot().servers.first?.reachability == .offline)
        let count = harness.log.reloads.count
        for attempt in 2...5 {
            await harness.connection.emit(.state(.connecting(attempt: attempt)))
            await harness.advance(1.5)
            await harness.connection.emit(.state(.waiting(attempt: attempt, retryAt: harness.time.clock.now(), failure: .timeout)))
            await harness.advance(1.5)
        }
        #expect(harness.log.reloads.count == count, "Each attempt is still offline: nothing is rewritten or reloaded")
        await harness.cleanUp()
    }
    @Test func backgroundShowsTheServersPausedSinceTheyLeft() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        await harness.connection.emit(.state(.connected(harness.server.record.endpoints[0].id, since: .now)))
        await harness.advance(1.5)
        await harness.registry.setScenePhase(.background)
        let paused = try harness.snapshot().servers.first
        #expect(paused?.reachability == .paused && paused?.syncedAt != nil, "Written at once, with the time the server was last online")
        await harness.cleanUp()
    }
    @Test func aColdLaunchKeepsWhatTheLastSnapshotKnewUntilTheServerSyncs() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_ask"); harness.seed("ses_run", updated: 1_790_000_100_000)
        let readPath = harness.server.readPath, ref = harness.server.id.rawValue.uuidString
        readPath.permissions["ses_ask"] = [permission("per_1", session: "ses_ask")]
        readPath.sessions["ses_run"]?.status = .running(since: 1_790_000_040_000); readPath.running.insert("ses_run")
        harness.system.flush()
        // Relaunched with the server offline: the cache has the sessions but no requests, and nothing runs yet.
        harness.system.stop()
        readPath.permissions = [:]; readPath.running = []; readPath.sessions["ses_run"]?.status = .idle
        harness.seed("ses_new", updated: 1_790_000_200_000)
        let relaunched = SystemIntegration(store: harness.store, index: harness.index, manifest: harness.root.appending(path: "spotlight.json"),
                                           defaults: harness.defaults, clock: harness.time.clock, reload: { _ in })
        harness.registry.system = relaunched
        relaunched.start(harness.registry)
        var byID = Dictionary(uniqueKeysWithValues: try harness.snapshot().sessions.map { ($0.session, $0) })
        #expect(byID["ses_new"] != nil, "Rewritten at launch")
        #expect(byID["ses_ask"]?.status == .needsYou && byID["ses_ask"]?.request == .init(id: "per_1", kind: .permission, session: "ses_ask"))
        #expect(byID["ses_run"]?.status == .running && byID["ses_run"]?.runningSince == Date(timeIntervalSince1970: 1_790_000_040))
        // Review approval and Get session status answer from it too.
        harness.server.readPath.client = { throw URLError(.notConnectedToInternet) }
        let intents = IntentActions(registry: { harness.registry }, links: LinkInbox(), clock: harness.time.clock)
        #expect(await intents.nextApproval() == DeepLink.url(serverID: harness.server.id.rawValue, sessionID: "ses_ask", requestID: "per_1"))
        let status = try await intents.status(server: ref, session: "ses_ask")
        #expect(status.state == .needsPermission && !status.live)
        // Once the server has fetched its requests (this one was answered elsewhere), the app's own state wins.
        readPath.requestsSynced = true
        await harness.advance(1.5)
        byID = Dictionary(uniqueKeysWithValues: try harness.snapshot().sessions.map { ($0.session, $0) })
        #expect(byID["ses_ask"]?.status == .idle && byID["ses_run"]?.status == .idle)
        #expect(await intents.nextApproval() == nil)
        await harness.cleanUp()
    }
    @Test func removingAServerPurgesTheSnapshotTheWidgetsAndSpotlight() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a"); harness.server.readPath.sessionOpened("ses_a")
        await harness.advance(3)
        let id = harness.server.id.rawValue.uuidString
        let indexed = await harness.index.items
        #expect(try harness.snapshot().lastProject?.server == id && !indexed.isEmpty)
        harness.log.reloads = []
        try await harness.registry.remove(harness.server)
        let snapshot = try harness.snapshot()
        #expect(snapshot.servers.isEmpty && snapshot.sessions.isEmpty && snapshot.lastProject == nil, "Without waiting for the clock")
        #expect(harness.log.reloads.first == Set(WidgetKind.allCases.map(SystemReload.widget) + ControlKind.allCases.map(SystemReload.control)))
        let calls = await harness.index.calls, left = await harness.index.items
        #expect(calls.contains(.domains(["server." + id])) && left.isEmpty)
        await harness.cleanUp()
    }
    @Test func theLastOpenedOrSentSessionPicksNewPromptsProject() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a"); harness.seed("ses_child", parent: "ses_a")
        harness.server.readPath.sessionOpened("ses_child")
        #expect(harness.system.lastProject == nil, "A subagent is no project choice")
        harness.server.readPath.phonePromptSent("ses_a")
        #expect(harness.system.lastProject == .init(server: harness.server.id.rawValue.uuidString, project: "prj", name: "opencode-ios"))
        await harness.advance(1.5)
        #expect(harness.log.reloads.last?.contains(.control(.newPrompt)) == true)
        await harness.cleanUp()
    }
    @Test func homeLeavesArchivedSessionsOutAndFollowsArchiveEvents() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a"); harness.seed("ses_b"); harness.seed("ses_old", archived: true)
        let home = { Set(HomeOrdering.all([harness.server]).map(\.session.id)) }
        #expect(home() == ["ses_a", "ses_b"])
        harness.server.readPath.apply(try readEvent("session.archived", session: "ses_b", seq: 1, created: 1_790_000_200_000))
        #expect(home() == ["ses_a"], "Archived on another client")
        harness.server.readPath.apply(try readEvent("session.unarchived", session: "ses_old", seq: 1, created: 1_790_000_300_000))
        #expect(home() == ["ses_a", "ses_old"])
        harness.system.flush()
        #expect(Set(try harness.snapshot().sessions.map(\.session)) == ["ses_a", "ses_old"], "Widgets follow Home")
        await harness.cleanUp()
    }
}

@MainActor @Suite(.serialized) struct SpotlightIndexerTests {
    @Test func indexesAddsUpdatesAndDeletesIncrementally() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        await harness.system.spotlight.settle()
        #expect(await harness.index.calls == [.deleteAll], "No manifest: a full rebuild")
        harness.seed("ses_a"); harness.seed("ses_b"); harness.seed("ses_child", parent: "ses_a"); harness.seed("ses_old", archived: true)
        await harness.advance(2.5)
        #expect(await harness.index.calls.last == .index(["ses_a", "ses_b"]), "Roots only, archived left out")
        let entry = try #require(await harness.index.items.values.first { $0.session == "ses_a" })
        #expect(entry.title == "Title ses_a" && entry.project == "opencode-ios" && entry.serverName == "Studio Mac")
        await harness.index.reset()
        harness.server.readPath.sessions["ses_a"]?.info["title"] = .string("Renamed")
        harness.server.readPath.localMeta["ses_b"] = .init(hidden: true)
        await harness.advance(2.5)
        #expect(await harness.index.calls == [.delete(["ses_b"]), .index(["ses_a"])], "Only what changed; a hidden session leaves")
        await harness.index.reset()
        harness.server.readPath.sessions["ses_a"]?.info.raw.set(["time", "updated"], .number(1_790_000_010_000))
        await harness.advance(2.5)
        #expect(await harness.index.calls.isEmpty, "Activity on the same day indexes nothing")
        await harness.cleanUp()
    }
    @Test func theToggleClearsAndRebuildsAndAManifestSurvivesARelaunch() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a")
        await harness.advance(2.5)
        await harness.index.reset()
        let shortcuts = harness.log.shortcuts
        await harness.system.setSpotlight(false)
        let cleared = await harness.index.calls
        #expect(cleared == [.deleteAll] && !harness.system.spotlightEnabled && harness.defaults.object(forKey: SystemIntegration.spotlightKey) as? Bool == false)
        // Siri's parameter phrases are refreshed, and the queries stop suggesting titles in both processes.
        #expect(harness.log.shortcuts == shortcuts + 1)
        await harness.advance(1.5)
        #expect(try harness.snapshot().suggestsSessions == false)
        let directory = await IntentActions(registry: { harness.registry }, links: LinkInbox(), clock: harness.time.clock).directory()
        #expect(!directory.suggestsSessions)
        harness.seed("ses_b")
        await harness.advance(3)
        #expect(await harness.index.calls == [.deleteAll], "Off: nothing more is indexed")
        await harness.system.setSpotlight(true)
        #expect(await harness.index.calls == [.deleteAll, .deleteAll, .index(["ses_a", "ses_b"])], "On: everything again")
        await harness.index.reset()
        await harness.system.rebuildSpotlight()
        #expect(await harness.index.calls == [.deleteAll, .index(["ses_a", "ses_b"])], "A rebuild after a cache reset")
        // A relaunch with the same manifest changes nothing; a manifest from another version rebuilds.
        let manifest = try Data(contentsOf: harness.root.appending(path: "spotlight.json"))
        let again = try SystemHarness(manifest: manifest)
        try await again.start()
        await again.system.spotlight.settle()
        let relaunch = await again.index.calls
        #expect(!relaunch.contains(.deleteAll), "A known manifest is not rebuilt")
        let older = try SystemHarness(manifest: Data(#"{"version":0,"items":{}}"#.utf8))
        try await older.start()
        await older.system.spotlight.settle()
        #expect(await older.index.calls.first == .deleteAll)
        await harness.cleanUp(); await again.cleanUp(); await older.cleanUp()
    }
    @Test func spotlightOffFromSettingsIndexesNothing() async throws {
        let harness = try SystemHarness(spotlight: false)
        try await harness.start()
        await harness.system.spotlight.settle()
        harness.seed("ses_a")
        await harness.advance(3)
        let calls = await harness.index.calls
        #expect(calls == [.deleteAll] && !harness.system.spotlightEnabled, "Off at launch: anything left is deleted, nothing is indexed")
        await harness.cleanUp()
    }
    @Test func aSwitchOffThatFailsIsRetriedAtLaunch() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a")
        await harness.advance(2.5)
        await harness.index.failing(true)
        await harness.system.setSpotlight(false)
        let manifestURL = harness.root.appending(path: "spotlight.json")
        let left = await harness.index.items
        #expect(!left.isEmpty && FileManager.default.fileExists(atPath: manifestURL.path), "The manifest stays until Spotlight has deleted the items")
        // Relaunched with the switch off, as also after a kill before the deletion ran: the items go at launch.
        let again = try SystemHarness(spotlight: false, manifest: try Data(contentsOf: manifestURL))
        try await again.start()
        await again.system.spotlight.settle()
        #expect(await again.index.calls == [.deleteAll])
        #expect(!FileManager.default.fileExists(atPath: again.root.appending(path: "spotlight.json").path))
        await harness.cleanUp(); await again.cleanUp()
    }
    @Test func aFailedPassRebuildsNextTime() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        await harness.system.spotlight.settle()
        await harness.index.failing(true)
        harness.seed("ses_a")
        await harness.advance(2.5)
        await harness.index.failing(false); await harness.index.reset()
        harness.seed("ses_b")
        await harness.advance(2.5)
        #expect(await harness.index.calls == [.deleteAll, .index(["ses_a", "ses_b"])])
        await harness.cleanUp()
    }
}

/// A server that admits each prompt and session once, losing the first response when asked to.
private actor AdmittingServer {
    var requests: [String] = []
    var bodies: [String: [Data]] = [:]
    var loseFirst: Bool
    init(loseFirst: Bool = false) { self.loseFirst = loseFirst }
    func respond(_ request: URLRequest) throws -> JSONValue {
        let path = request.url?.path ?? ""
        requests.append((request.httpMethod ?? "GET") + " " + path)
        let raw = try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
        if let id = raw["id"]?.stringValue, let body = request.httpBody { bodies[id, default: []].append(body) }
        if request.httpMethod == "POST", path.hasSuffix("/prompt"), loseFirst { loseFirst = false; throw URLError(.networkConnectionLost) }
        if path == "/api/session" {
            return .object(["data": .object(["id": raw["id"] ?? .null, "projectID": .string("prj"), "location": raw["location"] ?? .object([:]),
                                             "time": .object(["created": .number(1), "updated": .number(1)])])])
        }
        let session = String(path.split(separator: "/").dropFirst(2).first ?? "")
        return .object(["data": .object(["id": raw["id"] ?? .null, "sessionID": .string(session), "type": .string("user"), "delivery": .string("steer"),
                                         "payload": .object(["text": raw["text"] ?? .string("")]), "time": .object(["created": .number(1)])])])
    }
}

@MainActor @Suite(.serialized) struct IntentActionsTests {
    private func actions(_ harness: SystemHarness, links: LinkInbox = LinkInbox()) -> IntentActions {
        let registry = harness.registry
        return IntentActions(registry: { registry }, links: links, clock: harness.time.clock)
    }
    @Test func sendGoesThroughTheOutboxOnceAcrossARetry() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a")
        let server = AdmittingServer(loseFirst: true)
        harness.server.readPath.client = { readAPI { try await server.respond($0) } }
        let ref = harness.server.id.rawValue.uuidString
        let receipt = try await actions(harness).send(.init(destination: .session(server: ref, session: "ses_a"), text: "  Run the tests  "))
        #expect(!receipt.delivered && receipt.session.session == "ses_a" && receipt.serverName == "Studio Mac", "The answer was lost: saved, not failed")
        #expect(harness.server.readPath.outboxEntries.count == 1)
        await harness.server.readPath.drainNow(deadline: .seconds(5))
        let bodies = await server.bodies
        #expect(bodies.count == 1 && bodies.values.first?.count == 2, "One prompt ID, sent twice")
        #expect(Set(bodies.values.first ?? []).count == 1, "The retry repeats the exact admission")
        #expect(harness.server.readPath.outboxEntries.isEmpty)
        let text = try JSONDecoder().decode(JSONValue.self, from: try #require(bodies.values.first?.first))["text"]?.stringValue
        #expect(text == "Run the tests")
        await harness.cleanUp()
    }
    @Test func aNewSessionIsCreatedThenPromptedAndNothingIsAdmittedForARefusedSession() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a"); harness.seed("ses_child", parent: "ses_a")
        let server = AdmittingServer()
        harness.server.readPath.client = { readAPI { try await server.respond($0) } }
        let ref = harness.server.id.rawValue.uuidString, intents = actions(harness)
        await #expect(throws: IntentError.subagentSession) { try await intents.send(.init(destination: .session(server: ref, session: "ses_child"), text: "Hi")) }
        await #expect(throws: IntentError.projectNotFound) { try await intents.send(.init(destination: .newSession(server: ref, project: "nope"), text: "Hi")) }
        await #expect(throws: IntentError.serverUnavailable) { try await intents.send(.init(destination: .session(server: "other", session: "ses_a"), text: "Hi")) }
        let sent = await server.requests
        #expect(harness.server.readPath.outboxEntries.isEmpty && sent.isEmpty)
        let receipt = try await intents.send(.init(destination: .newSession(server: ref, project: "prj"), text: "Start the release notes"))
        #expect(receipt.delivered)
        let requests = await server.requests
        #expect(requests.count == 2 && requests[0] == "POST /api/session" && requests[1] == "POST /api/session/\(receipt.session.session)/prompt")
        await harness.cleanUp()
    }
    @Test func statusFollowsHomeAndSaysWhenItIsOnlyLastKnown() async throws {
        func info(_ outcome: String?) -> SessionInfo {
            SessionInfo(raw: .object(["id": .string("s"), "title": .string("T"), "outcome": outcome.map(JSONValue.string) ?? .null,
                                      "time": .object(["created": .number(1_000), "updated": .number(120_000)])]))
        }
        #expect(IntentActions.report(info: info(nil), running: true, permission: true, question: true, unread: false).state == .needsPermission)
        #expect(IntentActions.report(info: info(nil), running: true, permission: false, question: true, unread: false).state == .needsAnswer)
        #expect(IntentActions.report(info: info("failed"), running: true, permission: false, question: false, unread: false).state == .running)
        for (outcome, state) in [("failed", SessionStatusReport.State.failed), ("interrupted", .stopped), ("succeeded", .finished), ("other", .idle)] {
            #expect(IntentActions.report(info: info(outcome), running: false, permission: false, question: false, unread: false).state == state)
        }
        #expect(IntentActions.report(info: info(nil), running: false, permission: false, question: false, unread: true).lastActivity == Date(timeIntervalSince1970: 120))
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a", outcome: "succeeded", unread: true)
        harness.server.readPath.client = { readAPI { request in
            switch request.url?.path {
            case "/api/session/ses_a": return .object(["data": .object(["id": .string("ses_a"), "title": .string("Fresh"), "outcome": .string("succeeded"),
                                                                        "time": .object(["created": .number(1), "updated": .number(2)])])])
            case "/api/session/active": return .object(["data": .object(["ses_a": .object(["time": .object(["started": .number(60_000)])])])])
            default: return .object(["data": .array([])])
            }
        } }
        let ref = harness.server.id.rawValue.uuidString
        let live = try await actions(harness).status(server: ref, session: "ses_a")
        #expect(live.state == .running && live.title == "Fresh" && live.live && live.runningSince == Date(timeIntervalSince1970: 60))
        harness.server.readPath.client = { throw URLError(.notConnectedToInternet) }
        let cached = try await actions(harness).status(server: ref, session: "ses_a")
        #expect(cached.state == .finished && cached.unread && !cached.live)
        await #expect(throws: IntentError.sessionNotFound) { try await actions(harness).status(server: ref, session: "missing") }
        await harness.cleanUp()
    }
    @Test func reviewOpensTheNextRequestAndNeverReplies() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        harness.seed("ses_a")
        let server = AdmittingServer()
        harness.server.readPath.client = { readAPI { try await server.respond($0) } }
        let links = LinkInbox(), intents = actions(harness, links: links)
        #expect(await intents.nextApproval() == nil, "Nothing waits")
        harness.server.readPath.permissions["ses_a"] = [permission("per_1", session: "ses_a")]
        let url = try #require(await intents.nextApproval())
        #expect(url == DeepLink.url(serverID: harness.server.id.rawValue, sessionID: "ses_a", requestID: "per_1"))
        #expect(harness.server.readPath.reviewRequest == "per_1", "Presented as Review next approval presents it")
        intents.open(url)
        #expect(links.url == url)
        #expect(await server.requests.isEmpty, "Reviewing sends nothing to the server, so it can never reply")
        #expect(harness.server.readPath.permissions["ses_a"]?.count == 1)
        await harness.cleanUp()
    }
    @Test func theQueriesSeeEverySessionAndProjectNotOnlyTheSnapshots() async throws {
        let harness = try SystemHarness()
        try await harness.start()
        for index in 0..<70 { harness.seed(String(format: "ses_%02d", index), updated: 1_790_000_000_000 + Double(index) * 60_000) }
        harness.server.readPath.projects = (0..<60).map { index in
            Project(raw: .object(["id": .string("prj\(index)"), "name": .string("Project \(index)"), "canonical": .string("/Users/Shared/project\(index)"),
                                  "time": .object(["active": .number(Double(index) * 60_000)])]))
        }
        harness.system.flush()
        let snapshot = try harness.snapshot()
        #expect(snapshot.sessions.count == SystemDefaults.recentLimit && snapshot.projects.count == SystemDefaults.projectLimit)
        // An intent that started the app waits for the registry, then chooses from all of it.
        let directory = await actions(harness).directory()
        #expect(directory.sessions.count == 70 && directory.projects.count == 60)
        await harness.cleanUp()
    }
    @Test func newPromptOpensTheComposerInTheLastProject() async throws {
        let harness = try SystemHarness()
        let intents = actions(harness)
        await harness.registry.load()
        #expect(await intents.newPrompt() == nil, "No server, nothing to open")
        try await harness.start()
        let server = harness.server.id.rawValue
        #expect(await intents.newPrompt() == DeepLink.compose(serverID: server))
        harness.seed("ses_a"); harness.server.readPath.sessionOpened("ses_a")
        #expect(await intents.newPrompt() == DeepLink.compose(serverID: server, projectID: "prj"))
        await harness.cleanUp()
    }
}
