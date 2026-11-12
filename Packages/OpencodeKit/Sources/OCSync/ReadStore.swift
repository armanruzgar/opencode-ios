import Foundation
import Observation
import OCFoundation
import OCModels
import OCNetworking
import OCPersistence
import OCSecurity

/// The read projection is also the connection's event sink and resync extension.
@MainActor @Observable public final class ReadStore: ServerEventSink, ResyncExtension {
    @ObservationIgnored var activityProgress = ActivityProgress()
    @ObservationIgnored var pushChanged: @MainActor () -> Void = {}
    @ObservationIgnored var phonePromptSent: @MainActor (String) -> Void = { _ in }
    /// A session was opened on screen; New prompt starts in the last one's project.
    @ObservationIgnored var sessionOpened: @MainActor (String) -> Void = { _ in }
    public let serverID: String
    public var projects: [Project] = []
    public var sessions: [String: SessionModel] = [:]
    public var running: Set<String> = []
    public var localMeta: [String: SessionLocalMeta] = [:]
    public var rootCursor: String?
    public private(set) var lastStatusSync: Date?
    /// Set once a resync has also fetched the waiting requests. Before that, after a cold launch, the cache knows the
    /// sessions but not their permissions and questions.
    public internal(set) var requestsSynced = false
    /// True while the server is unreachable, so running and sending states are only last known.
    public internal(set) var offline = false
    public var shells: [String: [String: ShellInfo]] = [:]
    public var permissions: [String: [PermissionRequest]] = [:]
    public var forms: [FormOwner: [FormInfo]] = [:]
    public var catalogs: [String: LocationCatalog] = [:]
    public internal(set) var openSessions: Set<String> = []
    @ObservationIgnored var openCounts: [String: Int] = [:]
    /// A permission or question to present when its card appears (Review next approval).
    public var reviewRequest: String?
    public internal(set) var error: String?
    public private(set) var cacheLoaded = false
    public internal(set) var outboxEntries: [String: OutboxEntry] = [:]
    public internal(set) var writeError: String?
    /// Reply failures keyed by permission or form id, shown on that request instead of server-wide.
    public internal(set) var approvalErrors: [String: String] = [:]
    public internal(set) var failedCreationDirectories: [String: String] = [:]
    /// Whether this server's session info has `time.busy`, which the projection then keeps as the server does.
    @ObservationIgnored public var projectsBusyTime = false
    /// Whether this server lists archived sessions apart (2.1.0 and later), so the root lists Home pages through
    /// leave them out.
    @ObservationIgnored public var filtersArchived = false
    /// Moves requested from this device, until `session.moved` or a failure; the inbox item shows moves from anywhere.
    public internal(set) var requestedMoves: [String: SessionMove] = [:]
    /// The side question of each session (`/btw`). It is never part of the history.
    public internal(set) var sideQuestions: [String: SideQuestion] = [:]
    @ObservationIgnored var sideQuestionTasks: [String: Task<Void, Never>] = [:]
    public var formDrafts: [String: [String: JSONValue]] = [:]
    public internal(set) var lastApprovalRoundTrip: Double?
    public internal(set) var lastAnswerRoundTrip: Double?
    @ObservationIgnored var answerStarts: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var approvalStarts: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var reviews: [String: ReviewModel] = [:]
    @ObservationIgnored var turnDiffs: [String: TurnDiffModel] = [:]
    @ObservationIgnored var fileModels: [String: FilesModel] = [:]
    @ObservationIgnored var terminalLists: [String: TerminalListModel] = [:]
    @ObservationIgnored var shellRuns: [String: ShellRunModel] = [:]
    @ObservationIgnored var adminModel: ServerAdminModel?
    /// Every settings model open on this server (one per window); events and backgrounding reach each.
    @ObservationIgnored private var adminModels: [WeakAdminModel] = []
    var liveAdminModels: [ServerAdminModel] { adminModels.compactMap(\.model) }
    func register(_ model: ServerAdminModel) { adminModels.removeAll { $0.model == nil }; adminModels.append(.init(model: model)) }
    /// Opens PTY sockets; tests replace it.
    @ObservationIgnored public var webSockets: any WebSocketConnecting = URLSessionWebSockets()
    @ObservationIgnored var composers: [String: ComposerModel] = [:]
    public internal(set) var replacingDraftSessionID: String?
    @ObservationIgnored var draftReplacementReply: CheckedContinuation<Bool, Never>?
    public let drafts: DraftStore?
    @ObservationIgnored public var biometricGate: any BiometricAuthenticating = BiometricGate()
    @ObservationIgnored var replyingPermissions: Set<String> = []
    @ObservationIgnored var hiddenPermissions: Set<String> = []
    @ObservationIgnored var settledPermissions: Set<String> = []
    @ObservationIgnored var hiddenForms: [FormOwner: Set<String>] = [:]
    @ObservationIgnored var settledForms: [FormOwner: Set<String>] = [:]
    @ObservationIgnored let minter: IDMinter
    @ObservationIgnored let serverClock: ServerClock
    @ObservationIgnored let background: any BackgroundTaskProviding
    @ObservationIgnored var writeTask: Task<Void, Never>?
    @ObservationIgnored var submissionTask: Task<Void, any Error>?
    @ObservationIgnored var writesConnected = false
    @ObservationIgnored var admittedInputs: Set<String> = []
    @ObservationIgnored var consumedInputs: Set<String> = []
    @ObservationIgnored var cancelledInputs: Set<String> = []
    @ObservationIgnored var pendingDeliveries: [String: JSONValue] = [:]
    @ObservationIgnored var acknowledgedSessions: Set<String> = []
    @ObservationIgnored var hiddenSessions: Set<String> = []
    @ObservationIgnored var deletedSessions: Set<String> = []
    @ObservationIgnored var pendingTitles: [String: String] = [:]
    @ObservationIgnored public var client: (@MainActor () async throws -> APIClient)?
    @ObservationIgnored public var drainOutbox: @MainActor () async throws -> Void = {}
    @ObservationIgnored let outboxDrain: OutboxDrain?
    @ObservationIgnored let residency: TranscriptResidency
    @ObservationIgnored let cache: CacheStore?
    @ObservationIgnored let clock: NetworkClock
    @ObservationIgnored var seenEvents: Set<String> = []
    @ObservationIgnored var eventRing: [String] = []
    @ObservationIgnored var overlays: [UUID: FetchOverlay] = [:]
    @ObservationIgnored var refreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var refreshDeadlines: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var lru: [String] = []
    @ObservationIgnored var dirty: Set<String> = []
    @ObservationIgnored var persistTask: Task<Void, Never>?
    @ObservationIgnored var flushRequested = false
    @ObservationIgnored var work: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var sessionLoads: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored var stopped = false
    public init(serverID: String, cache: CacheStore? = nil, clock: NetworkClock = .init(),
                residency: TranscriptResidency = .init(), serverClock: ServerClock? = nil, drafts: DraftStore? = nil,
                background: (any BackgroundTaskProviding)? = nil, client: (@MainActor () async throws -> APIClient)? = nil) {
        self.residency = residency
        self.serverID = serverID; self.cache = cache; self.clock = clock; self.client = client
        let serverClock = serverClock ?? ServerClock(now: clock.date)
        self.serverClock = serverClock; self.minter = IDMinter(clock: serverClock)
        self.drafts = drafts ?? cache.map { DraftStore(writer: $0.writer) }
        self.background = background ?? SystemBackgroundTaskProvider()
        self.outboxDrain = cache.map { OutboxDrain(store: OutboxStore(writer: $0.writer), serverID: serverID) }
    }
    deinit {
        persistTask?.cancel()
        writeTask?.cancel(); submissionTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
        for task in work.values { task.cancel() }
        for task in sessionLoads.values { task.cancel() }
        for task in sideQuestionTasks.values { task.cancel() }
    }
    public func receive(_ batch: EventBatch) {
        guard !stopped else { return }
        for event in batch.events { apply(event) }
    }
    public func apply(_ event: ServerEvent) {
        guard let header = event.header else { return }
        if let created = header.created { serverClock.refine(eventTimestamp: Date(timeIntervalSince1970: created / 1_000), receivedAt: clock.date()) }
        if seenEvents.contains(header.id) { return }
        seenEvents.insert(header.id); eventRing.append(header.id)
        if eventRing.count > 20_000 {
            for id in eventRing.prefix(10_000) { seenEvents.remove(id) }
            eventRing.removeFirst(10_000)
        }
        let sessionID = event.sessionID
        if let id = sessionID, let seq = event.sequence, let session = sessions[id] {
            if session.seenSequences.contains(seq) { return }
            if let last = session.lastSeq, seq < last { scheduleRefresh(id); return }
            session.lastSeq = seq; session.seenSequences.insert(seq)
        }
        if event.isFallback {
            if header.durable != nil, header.type.hasPrefix("session."), let id = sessionID { scheduleRefresh(id) }
            return
        }
        activityProgress.receive(event, sessions: sessions)
        let before = sessionID.flatMap { sessions[$0]?.info.raw }
        handle(event)
        refreshReviewViews(event)
        if let id = sessionID, let seq = event.sequence, let session = sessions[id] {
            session.lastSeq = seq; session.seenSequences.insert(seq)
        }
        for overlay in overlays.values {
            overlay.events.append(event)
            if let id = sessionID, let after = sessions[id]?.info.raw {
                overlay.recordInfo(id, before: before, after: after)
            }
        }
        if let id = sessionID {
            if event.sequence != nil, sessions[id]?.transcript != nil {
                let messageID = event.payload["assistantMessageID"]?.stringValue ?? event.payload["inboxID"]?.stringValue ?? header.id.replacingOccurrences(of: "evt_", with: "msg_", options: .anchored)
                for overlay in overlays.values { overlay.changed[id, default: []].insert(messageID) }
            }
            dirty.insert(id)
            schedulePersistence(turnEnded: header.type.hasPrefix("session.execution.") && header.type != "session.execution.started")
        }
    }
    public func seed(info: SessionInfo, messages: [SessionMessage]? = nil, pending: [InboxItem] = [], permissions: [PermissionRequest] = [], forms: [FormInfo] = []) {
        let model = sessions[info.id] ?? SessionModel(info: info)
        model.info = info; model.resetSequence(); model.pending = pending
        if let messages { model.transcript = TranscriptModel(messages: messages) }
        sessions[info.id] = model; self.permissions[info.id] = permissions; self.forms[.session(info.id)] = forms
        updateAttention()
    }
    public func loadCache() async throws {
        guard let cache else { cacheLoaded = true; return }
        try await outboxDrain?.prepareLaunch(now: clock.date())
        let snapshot = try await cache.load(serverID: serverID)
        projects = snapshot.projects
        localMeta = try await cache.writer.sessionLocalMeta(serverID: serverID)
        for info in snapshot.sessions where sessions[info.id] == nil { sessions[info.id] = SessionModel(info: info) }
        try await reloadOutbox()
        for (key, values) in try await cache.writer.catalogs(serverID: serverID) {
            let catalog = LocationCatalog()
            if let value = values["agent"] { catalog.agents.seed(value.lossy(AgentInfo.self).values) }
            if let value = values["model"] { catalog.models.seed(value.lossy(ModelInfo.self).values) }
            if let value = values["provider"] { catalog.providers.seed(value.lossy(ProviderInfo.self).values) }
            if let value = values["model/default"] { catalog.defaultModel.seed(value.isNull ? nil : ModelInfo(raw: value)) }
            catalogs[key] = catalog
        }
        cacheLoaded = true
    }
    func owned(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        work[id] = Task { [weak self] in
            do { try await operation() } catch is CancellationError {} catch { self?.error = localized("Could not refresh server data.") }
            self?.work.removeValue(forKey: id)
        }
    }
    func scheduleRefresh(_ id: String) {
        guard client != nil, !stopped else { return }
        refreshDeadlines[id] = clock.now().advanced(by: .milliseconds(500))
        if refreshTasks[id] != nil { return }
        refreshTasks[id] = Task { [weak self, clock] in
            guard let self else { return }
            defer { self.refreshTasks.removeValue(forKey: id); self.refreshDeadlines.removeValue(forKey: id) }
            do {
                while let deadline = self.refreshDeadlines[id] {
                    let delay = clock.now().duration(to: deadline)
                    if delay > .zero { try await clock.sleep(delay) }
                    try Task.checkCancellation()
                    // A later event moves the deadline; events during the request get a new pass.
                    guard self.refreshDeadlines[id] == deadline else { continue }
                    self.refreshDeadlines.removeValue(forKey: id)
                    if let existing = self.sessionLoads[id] { try await existing.value }
                    try await self.refreshSession(id, includeTranscript: true)
                }
            } catch is CancellationError {} catch { self.error = localized("Could not refresh the session.") }
        }
    }
    func confirmStatus() { lastStatusSync = clock.date() }
    func updateAttention() {
        defer { pushChanged() }
        var counts: [String: Int] = [:]
        let owners = Set(permissions.keys).union(forms.keys.compactMap { if case .session(let id) = $0 { id } else { nil } }).union(sessions.keys)
        for owner in owners {
            let failure = sessions[owner].map { $0.info.outcome == "failed" && $0.unread ? 1 : 0 } ?? 0
            let count = (permissions[owner]?.count ?? 0) + (forms[.session(owner)]?.count ?? 0) + failure
            guard count > 0 else { continue }
            var current: String? = owner, seen: Set<String> = []
            while let id = current, seen.insert(id).inserted {
                counts[id, default: 0] += count
                guard let session = sessions[id] else { scheduleRefresh(id); break }
                current = session.info.parentID
            }
        }
        for (id, session) in sessions {
            session.attention = counts[id, default: 0]
        }
    }
    func schedulePersistence(turnEnded: Bool = false) {
        guard cache != nil else { return }
        flushRequested = flushRequested || turnEnded
        let immediate = flushRequested
        persistTask?.cancel()
        persistTask = Task { [weak self, clock] in
            do {
                if !immediate { try await clock.sleep(.seconds(2)) }
                try Task.checkCancellation(); try await self?.flush()
            } catch is CancellationError {} catch { self?.error = localized("Could not save the cache.") }
        }
    }
    public func flush() async throws {
        guard let cache else { return }
        flushRequested = false
        let ids = dirty; dirty.subtract(ids)
        let snapshot = CacheSnapshot(serverID: serverID, projects: projects,
            sessions: ids.compactMap { sessions[$0]?.info }, transcripts: Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                guard let t = sessions[id]?.transcript else { return nil }
                return (id, CachedTranscript(messages: t.snapshot.filter { row in !(sessions[id]?.pending.contains { $0.id == row.id } ?? false) }, olderCursor: t.olderCursor))
            }))
        await cache.save(snapshot)
        do { try await cache.flush() } catch { dirty.formUnion(ids); throw error }
    }
    /// The server is being removed: its terminals end now, so no renderer or socket outlives it.
    func endTerminals() {
        for list in terminalLists.values { list.endAll() }
        terminalLists = [:]
    }
    public func stop() async {
        resolveDraftReplacement(false)
        stopped = true
        writesConnected = false
        writeTask?.cancel()
        await writeTask?.value; writeTask = nil
        _ = try? await submissionTask?.value
        do { try await flushComposers(); try await drafts?.flush() } catch { writeError = localized("Could not save drafts.") }
        let persistence = persistTask, refreshes = Array(refreshTasks.values), work = Array(work.values), loads = Array(sessionLoads.values)
        persistence?.cancel()
        for task in refreshes { task.cancel() }
        for task in work { task.cancel() }
        for task in loads { task.cancel() }
        for catalog in catalogs.values { catalog.stop() }
        for review in reviews.values { await review.stop() }
        for model in turnDiffs.values { model.stop() }
        for model in fileModels.values { model.stop() }
        // Terminals save their screens and close their sockets; they reconnect from the saved cursor after the next resync.
        for list in terminalLists.values { await list.suspend() }
        for run in shellRuns.values { run.cancel() }
        for model in liveAdminModels { model.suspend() }
        await outboxDrain?.stop()
        await persistence?.value
        for task in refreshes { await task.value }
        for task in work { await task.value }
        for task in loads { _ = try? await task.value }
        persistTask = nil
        do { try await flush() } catch { self.error = localized("Could not save the cache.") }
    }
    public func resume() {
        stopped = false
        for model in liveAdminModels { model.resume() }
        // A composer that appeared while the store was paused, as when a link opens a session while the app comes
        // forward, could not load its draft; it loads now.
        for composer in composers.values where !composer.loaded { Task { await composer.load() } }
    }
}

@MainActor final class FetchOverlay {
    var events: [ServerEvent] = []
    var info: [String: [String: JSONValue]] = [:]
    var changed: [String: Set<String>] = [:]
    var removed: [String: Set<String>] = [:]
    func retainedRows(_ rows: [SessionMessage], sessionID: String) -> [SessionMessage] {
        var rows = rows
        for event in events where event.sessionID == sessionID && event.header?.type == "session.revert.committed" {
            guard let boundary = event.payload["to"]?.stringValue else { continue }
            let index = rows.firstIndex { $0.id == boundary } ?? rows.firstIndex { $0.id >= boundary } ?? rows.count
            rows = Array(rows.prefix(index))
        }
        return rows.filter { !(removed[sessionID]?.contains($0.id) ?? false) }
    }
    func recordInfo(_ id: String, before: JSONValue?, after: JSONValue) {
        let keys = Set(before?.objectValue?.keys.map { $0 } ?? []).union(after.objectValue?.keys.map { $0 } ?? [])
        for key in keys {
            if key == "time" {
                for field in ["created", "updated", "idle", "viewed", "archived"] where before?[key]?[field] != after[key]?[field] {
                    info[id, default: [:]]["time.\(field)"] = after[key]?[field] ?? .null
                }
            } else if before?[key] != after[key] { info[id, default: [:]][key] = after[key] ?? .null }
        }
    }
    func apply(to value: SessionInfo) -> SessionInfo {
        var value = value
        for (path, raw) in info[value.id] ?? [:] { value.raw.set(path.split(separator: ".").map(String.init), raw) }
        return value
    }
}
