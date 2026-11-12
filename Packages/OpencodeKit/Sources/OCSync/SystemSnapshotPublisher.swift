import Foundation
import Observation
import OCModels
import OCNetworking
import OCShared

/// The App Group snapshot from the registry's servers, in Home's terms.
@MainActor enum SystemSnapshotBuilder {
    /// - Parameters:
    ///   - syncedAt: when a server that is not online was last seen online, given its reachability.
    ///   - carried: rows of the snapshot written before launch, by ID, for servers that have not fetched their
    ///     requests since; a session that would read idle keeps the waiting or running state it had there.
    static func build(_ servers: [ServerStore], phase: AppScenePhase = .active, lastProject: SystemSnapshot.ProjectRef?,
                      carried: [String: SystemSnapshot.Session] = [:], suggestsSessions: Bool = true,
                      syncedAt: (ServerStore, SystemSnapshot.Reachability) -> Date?, now: Date) -> SystemSnapshot {
        let rows = HomeOrdering.all(servers)
            .sorted { ($0.activity, $1.id) > ($1.activity, $0.id) }
            .map { item in
                var row = session(item)
                if row.status == .idle, let old = carried[row.id] {
                    row.status = old.status; row.requests = old.requests; row.request = old.request; row.runningSince = old.runningSince
                }
                return row
            }
        let needsYou = rows.filter(\.status.needsYou).prefix(SystemDefaults.needsYouLimit)
        let running = rows.filter { !$0.status.needsYou && $0.status.isRunning }.prefix(SystemDefaults.runningLimit)
        var chosen = Set<String>(), sessions: [SystemSnapshot.Session] = []
        for row in Array(needsYou) + Array(running) + Array(rows.prefix(SystemDefaults.recentLimit)) where chosen.insert(row.id).inserted {
            sessions.append(row)
        }
        sessions.sort { ($0.activity, $1.id) > ($1.activity, $0.id) }
        return SystemSnapshot(writtenAt: now, servers: servers.map { server in
            let reachability = reachability(server, phase: phase)
            return SystemSnapshot.Server(id: server.id.rawValue.uuidString, name: server.record.name, reachability: reachability, syncedAt: syncedAt(server, reachability))
        }, sessions: sessions, projects: Array(projects(servers).prefix(SystemDefaults.projectLimit)), lastProject: lastProject,
           suggestsSessions: suggestsSessions)
    }
    /// Every project, most recently active first.
    static func projects(_ servers: [ServerStore]) -> [SystemSnapshot.Project] {
        servers.flatMap { server in
            server.projects.map { project in
                SystemSnapshot.Project(server: server.id.rawValue.uuidString, project: project.id,
                    name: project.name ?? URL(fileURLWithPath: project.canonical).lastPathComponent,
                    activity: minute(project.time.active ?? max(project.time.updated, project.time.created)))
            }
        }.sorted { ($0.activity, $1.id) > ($1.activity, $0.id) }
    }
    static func session(_ item: SessionSummary) -> SystemSnapshot.Session {
        let server = item.server
        var requests = 0, request: SystemSnapshot.Request?
        for model in item.family {
            let permissions = server.permissions[model.id] ?? [], forms = server.forms[.session(model.id)] ?? []
            requests += permissions.count + forms.count
            if request == nil, let first = permissions.first { request = .init(id: first.id, kind: .permission, session: model.id) }
            if request == nil, let first = forms.first { request = .init(id: first.id, kind: .question, session: model.id) }
        }
        let status: SystemSnapshot.Status
        if requests > 0 { status = .needsYou }
        else if item.failed {
            status = .failed
            let failed = item.family.first { $0.info.outcome == "failed" && $0.unread } ?? item.session
            request = .init(id: "error", kind: .failure, session: failed.id)
        }
        else if item.runningCount > 0 { status = item.family.contains { if case .retrying = $0.status { true } else { false } } ? .retrying : .running }
        else { status = .idle }
        let since = item.family.compactMap { model -> Double? in if case .running(let since) = model.status { since } else { nil } }.min()
        return .init(server: server.id.rawValue.uuidString, session: item.session.id, title: item.session.info.title ?? localized("Untitled session"),
                     project: item.projectName, projectID: item.session.info.projectID, status: status, unread: item.session.unread,
                     activity: minute(item.activity), runningSince: since.flatMap { $0 > 0 ? minute($0) : nil }, requests: requests, request: request)
    }
    /// Coarse, so a reconnect that retries does not rewrite the snapshot at each attempt: every state that is trying
    /// to reach the server is offline. In the background every stream is closed, so servers count as paused from the
    /// moment the app leaves.
    static func reachability(_ server: ServerStore, phase: AppScenePhase = .active) -> SystemSnapshot.Reachability {
        if server.needsRepair { return .needsRepair }
        if phase == .background, ![.unauthorized].contains(server.state), !isIncompatible(server.state) { return .paused }
        switch server.state {
        case .connected: return .online
        case .idle, .suspended: return .paused
        case .resolving, .connecting, .waiting, .serviceStarting: return .offline
        case .unauthorized: return .needsRepair
        case .incompatible: return .unsupported
        }
    }
    private static func isIncompatible(_ state: ConnectionState) -> Bool { if case .incompatible = state { true } else { false } }
    /// Server times are milliseconds; the snapshot keeps minutes, so a streaming run does not rewrite it every second.
    static func minute(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: (milliseconds / 60_000).rounded(.down) * 60)
    }
}

/// Writes the snapshot when what it shows changes. Building it runs under observation tracking, so exactly the values
/// it reads trigger the next write. Writes are coalesced: the first change schedules one a second later, which takes
/// every change made meanwhile, so a busy session writes at most once a second. An unchanged snapshot is not written,
/// and only the widgets and controls whose content changed reload.
@MainActor final class SystemSnapshotPublisher {
    private let store: SystemSnapshotStore?
    private let clock: NetworkClock
    private let build: @MainActor (Date) -> SystemSnapshot
    private let reload: @MainActor (Set<SystemReload>) -> Void
    private let written: @MainActor (SystemSnapshot?, SystemSnapshot) -> Void
    private(set) var last: SystemSnapshot?
    private var pending: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var heartbeatDeadline: ContinuousClock.Instant?
    /// When every widget kind last reloaded together. A write that reloads only some kinds leaves the others counting
    /// staleness from the snapshot they last read, so the heartbeat counts from this.
    private var fullReload: ContinuousClock.Instant?
    private var started = false
    let delay: Duration, heartbeatInterval: Duration
    init(store: SystemSnapshotStore?, clock: NetworkClock = .init(), delay: Duration = .seconds(1),
         heartbeat: Duration = .seconds(30 * 60), build: @escaping @MainActor (Date) -> SystemSnapshot,
         reload: @escaping @MainActor (Set<SystemReload>) -> Void, written: @escaping @MainActor (SystemSnapshot?, SystemSnapshot) -> Void = { _, _ in }) {
        self.store = store; self.clock = clock; self.delay = delay; self.heartbeatInterval = heartbeat
        self.build = build; self.reload = reload; self.written = written
        last = store?.read().snapshot
    }
    deinit { pending?.cancel(); heartbeat?.cancel() }
    /// Writes the first snapshot and starts following changes.
    func start() {
        guard !started else { return }
        started = true
        write()
    }
    func stop() { started = false; pending?.cancel(); pending = nil; heartbeat?.cancel(); heartbeat = nil; heartbeatDeadline = nil }
    /// Something the snapshot shows changed.
    func changed() {
        guard started, pending == nil else { return }
        pending = Task { [weak self, clock, delay] in
            do { try await clock.sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.write()
        }
    }
    /// Writes at once: the app is going to the background, or a server was removed.
    func flush() {
        guard started else { return }
        pending?.cancel(); pending = nil
        write()
    }
    private func write(force: Bool = false) {
        let next = withObservationTracking { build(clock.date()) } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        let previous = last
        if !force, let previous, previous.hasSameContent(as: next) { return }
        do { try store?.write(next) } catch { return }
        last = next
        // A heartbeat only moves the time the widgets measure staleness from.
        let reloads = force ? Self.widgets : SystemSnapshot.reloads(from: previous, to: next)
        if fullReload == nil || Self.widgets.isSubset(of: reloads) { fullReload = clock.now() }
        scheduleHeartbeat(next)
        reload(reloads)
        written(previous, next)
    }
    private static let widgets = Set(WidgetKind.allCases.map(SystemReload.widget))
    /// While a server is online the widgets count staleness from the snapshot they last read; reload them all before
    /// the oldest of those goes stale. Writes that reload only some kinds, and builds that change nothing, do not
    /// postpone it.
    private func scheduleHeartbeat(_ snapshot: SystemSnapshot) {
        guard snapshot.servers.contains(where: { $0.reachability == .online }), let fullReload else {
            heartbeat?.cancel(); heartbeat = nil; heartbeatDeadline = nil
            return
        }
        let deadline = fullReload.advanced(by: heartbeatInterval)
        guard heartbeat == nil || heartbeatDeadline != deadline else { return }
        heartbeat?.cancel()
        heartbeatDeadline = deadline
        heartbeat = Task { [weak self, clock] in
            do { try await clock.sleep(max(.zero, clock.now().duration(to: deadline))) } catch { return }
            guard let self, self.started, !Task.isCancelled else { return }
            self.heartbeat = nil
            self.pending?.cancel(); self.pending = nil
            self.write(force: true)
        }
    }
}
