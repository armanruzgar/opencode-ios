import Foundation
import OCFoundation
import OCModels
import OCNetworking
import OCPersistence

extension ReadStore {
    public func resync(reason: ResyncReason) async throws {
        guard let client else { return }
        // Do this before draining: an acknowledged offline prompt must never
        // interrupt an execution identified only by the pre-gap projection.
        for session in sessions.values { session.executionID = nil }
        try await drainOutbox()
        let api = try await client()
        // A write transport failure must not prevent read-side recovery.
        await flushWrites()
        for list in terminalLists.values { list.connected() }
        for run in shellRuns.values { run.resumePaging() }
        let token = UUID(), overlay = FetchOverlay()
        overlays[token] = overlay
        defer { overlays.removeValue(forKey: token) }
        // From 2.1.0 the first page leaves archived sessions out, so scripted `opencode run --archived` runs cannot fill
        // it. Archiving moves `time.updated`, so the newest archived page holds any held session archived while the
        // stream was down.
        let apart = filtersArchived
        async let activeRequest = api.send(ReadEndpoints.active)
        async let projectRequest = api.send(ReadEndpoints.projects)
        async let sessionRequest = api.send(ReadEndpoints.sessions(filter: .init(archived: apart ? false : nil)))
        async let archivedRequest: Page<SessionInfo>? = apart ? api.send(ReadEndpoints.sessions(filter: .init(archived: true))) : nil
        let (active, projects, roots, archivedRoots) = try await (activeRequest, projectRequest, sessionRequest, archivedRequest)
        try Task.checkCancellation()
        var nextRunning = Set(active.data.keys)
        for event in overlay.events {
            guard let id = event.sessionID else { continue }
            switch event.header?.type {
            case "session.execution.started": nextRunning.insert(id)
            case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.deleted": nextRunning.remove(id)
            default: break
            }
        }
        running = nextRunning
        rootCursor = roots.nextCursor(limit: 50)
        confirmStatus()
        let deleted = Set(overlay.events.filter { $0.header?.type == "session.deleted" }.compactMap(\.sessionID))
        for info in roots.data where !deleted.contains(info.id) && !hiddenSessions.contains(info.id) {
            let model = sessions[info.id] ?? SessionModel(info: info)
            model.info = overlay.apply(to: info); model.resetSequence(); sessions[info.id] = model; dirty.insert(info.id)
            if let title = pendingTitles[info.id] { model.info["title"] = .string(title) }
        }
        // Only sessions the app already holds; Home leaves archived ones out, so the rest need not be loaded.
        for info in archivedRoots?.data ?? [] where !deleted.contains(info.id) && !hiddenSessions.contains(info.id) {
            guard let model = sessions[info.id] else { continue }
            model.info = overlay.apply(to: info); model.resetSequence(); dirty.insert(info.id)
        }
        for (id, session) in sessions {
            session.executionID = nil
            session.status = running.contains(id) ? .running(since: session.info.time.updated) : .idle
            for event in overlay.events where event.sessionID == id {
                switch event.header?.type {
                case "session.retry.scheduled":
                    let payload = WireObject(raw: event.payload)
                    session.status = .retrying(attempt: payload.number("attempt"), at: payload.number("at"))
                case "session.execution.started", "session.step.started":
                    session.status = .running(since: event.header?.created ?? 0)
                    if event.header?.type == "session.execution.started" { session.turnStartedAt = event.header?.created }
                case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted": session.status = .idle
                default: break
                }
            }
        }
        var projectMap = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for event in overlay.events where event.header?.type == "project.updated" {
            let p = Project(raw: event.payload); projectMap[p.id] = p
        }
        self.projects = projectMap.values.sorted { ($0.time.active ?? 0) > ($1.time.active ?? 0) }
        for id in running where sessions[id] == nil { try await refreshSession(id, includeTranscript: false) }
        // Requests still shown as pending may have been answered elsewhere while the stream was down; their
        // locations are refetched too, or a session that is neither running nor open (or a location's global
        // form) keeps a stale request, and the badge counts it, until something else touches it.
        var waiting = Set(permissions.filter { !$0.value.isEmpty }.map(\.key))
        var waitingDirectories = Set<String>()
        for (owner, items) in forms where !items.isEmpty {
            switch owner {
            case .session(let id): waiting.insert(id)
            // A global form's owner is `Location.key`: the JSON array [directory, workspaceID], or the bare directory.
            case .global(let key): waitingDirectories.insert((try? JSONDecoder().decode([String?].self, from: Data(key.utf8)))?.first.flatMap { $0 } ?? key)
            }
        }
        let locations = Set(running.union(openSessions).union(waiting).compactMap { sessions[$0]?.info.location.directory }).union(waitingDirectories)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for directory in locations { group.addTask { try await self.refreshLocationRequests(directory, api: api) } }
            for id in openSessions { group.addTask { try await self.refreshSession(id) } }
            try await group.waitForAll()
        }
        requestsSynced = true
        for catalog in catalogs.values { catalog.invalidate() }
        for directory in Set(openSessions.compactMap { sessions[$0]?.info.location.directory }) { try await refreshCatalogs(directory) }
        updateAttention(); try await flush()
    }
    public func refreshSession(_ id: String, includeTranscript: Bool = true) async throws {
        if hiddenSessions.contains(id) { return }
        if outboxEntries[id]?.operation == "create", !acknowledgedSessions.contains(id) { return }
        if let task = sessionLoads[id] { return try await task.value }
        guard let client else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let api = try await client(), token = UUID(), overlay = FetchOverlay()
            self.overlays[token] = overlay
            defer { self.overlays.removeValue(forKey: token); self.sessionLoads.removeValue(forKey: id) }
            async let infoRequest = api.send(ReadEndpoints.session(id))
            async let inboxRequest = api.send(ReadEndpoints.inbox(id))
            async let permissionRequest = api.send(ReadEndpoints.permissions(id))
            async let formRequest = api.send(ReadEndpoints.forms(id))
            let transcript = self.sessions[id]?.transcript
            var splice: SpliceResult?
            if includeTranscript { splice = try await self.fetchSplice(id, transcript: transcript ?? TranscriptModel(), api: api) }
            let (info, inbox, permissions, forms) = try await (infoRequest, inboxRequest, permissionRequest, formRequest)
            try Task.checkCancellation()
            if self.hiddenSessions.contains(id) || overlay.events.contains(where: { $0.header?.type == "session.deleted" && $0.sessionID == id }) { return }
            let model = self.sessions[id] ?? SessionModel(info: info.data)
            if self.sessions[id] == nil, self.running.contains(id) { model.status = .running(since: info.data.time.updated) }
            model.info = overlay.apply(to: info.data); model.resetSequence(); self.sessions[id] = model
            if let title = self.pendingTitles[id] { model.info["title"] = .string(title) }
            if let splice, let transcript, model.transcript === transcript {
                transcript.replace(overlay.retainedRows(splice.rows, sessionID: id).filter { !self.cancelledInputs.contains($0.id) }, keeping: overlay.changed[id] ?? [])
                transcript.olderCursor = splice.cursor
                transcript.isAtStart = splice.cursor == nil
            }
            if let splice, transcript == nil, let cache = self.cache {
                await cache.save(.init(serverID: self.serverID, sessions: [model.info], transcripts: [id: .init(messages: overlay.retainedRows(splice.rows, sessionID: id), olderCursor: splice.cursor)]))
            }
            self.applyInbox(inbox.data, id: id, overlay: overlay)
            self.applyRequests(permissions.data, forms: forms.data, owner: id, overlay: overlay)
            self.dirty.insert(id); self.updateAttention()
        }
        sessionLoads[id] = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch APIError.server(tag: "SessionNotFoundError", status: 404, body: _) {
            sessions.removeValue(forKey: id); running.remove(id); permissions.removeValue(forKey: id)
            forms.removeValue(forKey: .session(id)); openSessions.remove(id); openCounts[id] = nil; lru.removeAll { $0 == id }; dirty.remove(id)
            try await cache?.writer.deleteSession(serverID: serverID, sessionID: id)
            updateAttention()
        }
    }
    func refreshLocationRequests(_ directory: String, api: APIClient) async throws {
        let token = UUID(), overlay = FetchOverlay(); overlays[token] = overlay
        defer { overlays.removeValue(forKey: token) }
        async let permissionRequest = api.send(ReadEndpoints.locationPermissions(directory))
        async let formRequest = api.send(ReadEndpoints.locationForms(directory))
        let (permissions, forms) = try await (permissionRequest, formRequest)
        try Task.checkCancellation()
        let known = sessions.values.filter { $0.info.location.directory == directory || $0.info.location.directory == permissions.location.directory }.map(\.id)
        let owners = Set(known + permissions.data.map(\.sessionID) + forms.data.map(\.sessionID)).union(["global"])
        for id in owners {
            applyRequests(permissions.data.filter { $0.sessionID == id }, forms: forms.data.filter { $0.sessionID == id }, owner: id,
                          overlay: overlay, location: forms.location)
        }
        updateAttention()
    }
    func applyInbox(_ snapshot: [InboxItem], id: String, overlay: FetchOverlay) {
        guard let session = sessions[id] else { return }
        for item in snapshot { admittedInputs.insert(item.id); acknowledgeEvent(item.id) }
        var items = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var order = snapshot.map(\.id)
        for event in overlay.events where event.sessionID == id {
            let p = WireObject(raw: event.payload), itemID = p.string("inboxID")
            switch event.header?.type {
            case "session.inbox.enqueued":
                var raw = p["item"] ?? .object([:]); raw.set("id", .string(itemID)); raw.set("sessionID", .string(id))
                raw.set("time", .object(["created": .number(event.header?.created ?? 0)]))
                items[itemID] = .init(raw: raw); if !order.contains(itemID) { order.append(itemID) }
            case "session.inbox.delivered", "session.inbox.cancelled": items.removeValue(forKey: itemID)
            case "session.inbox.delivery.changed":
                if var raw = items[itemID]?.raw { raw.set("delivery", p["delivery"]); items[itemID] = .init(raw: raw) }
            case "session.revert.committed":
                let retained = Set(session.pending.map(\.id)); items = items.filter { retained.contains($0.key) }
            default: break
            }
        }
        for item in session.pending where outboxEntries[item.id] != nil || session.transcript?.messages[item.id]?.acknowledged == false {
            if items[item.id] == nil { items[item.id] = item; order.append(item.id) }
        }
        session.pending = order.compactMap { itemID in
            guard !cancelledInputs.contains(itemID), !consumedInputs.contains(itemID), var item = items[itemID] else { return nil }
            if let delivery = pendingDeliveries[itemID] {
                if item.raw["delivery"] == delivery { pendingDeliveries.removeValue(forKey: itemID) }
                else { var raw = item.raw; raw.set("delivery", delivery); item = .init(raw: raw) }
            }
            return item
        }
        for item in session.pending { materialize(item, session: session, acknowledged: outboxEntries[item.id] == nil) }
    }
    func applyRequests(_ snapshot: [PermissionRequest], forms formSnapshot: [FormInfo], owner: String, overlay: FetchOverlay, location: Location = .init()) {
        var requests = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var pendingForms = Dictionary(formSnapshot.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for event in overlay.events where event.sessionID == owner {
            if owner == "global", Location(raw: event.header?.location ?? .object([:])).key != location.key { continue }
            let p = WireObject(raw: event.payload)
            switch event.header?.type {
            case "permission.asked": let request = PermissionRequest(raw: p.raw); requests[request.id] = request
            case "permission.replied": requests.removeValue(forKey: p.string("requestID"))
            case "form.created": let form: FormInfo = p.object("form"); pendingForms[form.id] = form
            case "form.replied", "form.cancelled": pendingForms.removeValue(forKey: p.string("id"))
            default: break
            }
        }
        let formOwner: FormOwner = owner == "global" ? .global(location: location.key) : .session(owner)
        permissions[owner] = requests.values.filter { !hiddenPermissions.contains($0.id) && !settledPermissions.contains($0.id) }.sorted { $0.id < $1.id }
        forms[formOwner] = pendingForms.values.filter { !(hiddenForms[formOwner]?.contains($0.id) ?? false) }.sorted { $0.id < $1.id }
    }
}

struct SpliceResult { let rows: [SessionMessage]; let cursor: String? }
extension ReadStore {
    func fetchSplice(_ id: String, transcript: TranscriptModel, api: APIClient, limit: Int = 50) async throws -> SpliceResult {
        let local = transcript.snapshot
        let pending = Set(sessions[id]?.pending.map(\.id) ?? [])
        let confirmed = Set(transcript.order.filter { transcript.messages[$0]?.acknowledged == true && !pending.contains($0) })
        let newest = try await api.send(ReadEndpoints.messages(id, limit: limit))
        let newestCursor = newest.nextCursor(limit: limit)
        var fetched = Array(newest.data.reversed()), cursor = newestCursor
        guard !confirmed.isEmpty else { return .init(rows: fetched, cursor: cursor) }
        for attempt in 0...4 {
            // A complete history must retain its fetched prefix too. Splicing
            // only at the newest overlap could hide older rows with no cursor.
            if cursor == nil { return .init(rows: fetched, cursor: nil) }
            let fetchedIDs = Set(fetched.map(\.id))
            if let anchor = local.lastIndex(where: { confirmed.contains($0.id) && fetchedIDs.contains($0.id) }),
               let remote = fetched.firstIndex(where: { $0.id == local[anchor].id }) {
                return .init(rows: Array(local.prefix(anchor)) + Array(fetched.dropFirst(remote)), cursor: transcript.olderCursor)
            }
            if attempt == 4 { break }
            let page = try await api.send(ReadEndpoints.messages(id, limit: limit, cursor: cursor))
            fetched = Array(page.data.reversed()) + fetched; cursor = page.nextCursor(limit: limit)
        }
        return .init(rows: Array(newest.data.reversed()), cursor: newestCursor)
    }
    public func open(_ id: String) async throws {
        sessionOpened(id)
        openCounts[id, default: 0] += 1
        openSessions.insert(id); lru.removeAll { $0 == id }; lru.append(id)
        // Release the victim before suspending or attaching another window. Concurrent
        // opens must not resurrect a cache read that was evicted while it was in flight.
        for (owner, evicted) in residency.touch(self, sessionID: id) {
            try await owner.evictTranscript(evicted)
        }
        guard lru.contains(id) else { return }
        if sessions[id] == nil { try await refreshSession(id, includeTranscript: false) }
        guard lru.contains(id), let session = sessions[id] else { return }
        if session.transcript == nil {
            let cached = try await cache?.transcript(serverID: serverID, sessionID: id)
            guard lru.contains(id), sessions[id] === session else { return }
            if session.transcript == nil {
                session.transcript = TranscriptModel(messages: cached?.messages ?? [], olderCursor: cached?.olderCursor)
                for item in session.pending { materialize(item, session: session, acknowledged: outboxEntries[item.id] == nil) }
            }
        }
        // Publish the cached window before the first network suspension.
        if client != nil { try await refreshSession(id); try await refreshCatalogs(session.info.location.directory) }
    }
    private func evictTranscript(_ id: String) async throws {
        let model = sessions[id], transcript = model?.transcript
        let cached = transcript.map { t in
            CachedTranscript(messages: t.snapshot.filter { row in !(model?.pending.contains { $0.id == row.id } ?? false) }, olderCursor: t.olderCursor)
        }
        model?.transcript = nil; openSessions.remove(id); lru.removeAll { $0 == id }; dirty.remove(id)
        if let cache, let model {
            await cache.save(.init(serverID: serverID, projects: projects, sessions: [model.info],
                                   transcripts: cached.map { [id: $0] } ?? [:]))
            try await cache.flush()
        }
    }
    /// A session open in two windows stays open until both close it.
    public func close(_ id: String) {
        let count = (openCounts[id] ?? 1) - 1
        openCounts[id] = count > 0 ? count : nil
        if count <= 0 { openSessions.remove(id) }
    }
    public func loadOlder(_ id: String) async throws {
        guard let t = sessions[id]?.transcript, !t.loadingOlder, let cursor = t.olderCursor, let client else { return }
        t.loadingOlder = true; defer { t.loadingOlder = false }
        let token = UUID(), overlay = FetchOverlay(); overlays[token] = overlay
        defer { overlays.removeValue(forKey: token) }
        let limit = 50
        let api = try await client(), page = try await api.send(ReadEndpoints.messages(id, limit: limit, cursor: cursor))
        try Task.checkCancellation()
        guard sessions[id]?.transcript === t else { return }
        t.prepend(overlay.retainedRows(Array(page.data.reversed()), sessionID: id))
        t.olderCursor = page.nextCursor(limit: limit); t.isAtStart = t.olderCursor == nil
        dirty.insert(id); schedulePersistence()
    }
    public func jumpToStart(_ id: String) async throws {
        guard let t = sessions[id]?.transcript, let client else { return }
        let token = UUID(), overlay = FetchOverlay(); overlays[token] = overlay
        defer { overlays.removeValue(forKey: token) }
        let api = try await client(), page = try await api.send(ReadEndpoints.messages(id, order: .asc))
        try Task.checkCancellation()
        guard sessions[id]?.transcript === t else { return }
        t.replace(overlay.retainedRows(page.data, sessionID: id), keeping: overlay.changed[id] ?? [])
        t.olderCursor = nil; t.isAtStart = true; dirty.insert(id); schedulePersistence()
    }
}
