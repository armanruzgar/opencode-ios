import Foundation
import Observation
import OCFoundation
import OCIntents
import OCModels
import OCNetworking
import OCShared

/// Links for the app's windows from outside them (Shortcuts, Spotlight, controls). Each window watches it, as it
/// watches notification taps, and the first one routes it; a link that arrives before any window waits here.
@MainActor @Observable public final class LinkInbox {
    public var url: URL?
    public init() {}
}

/// The intents' work in the app process. Sends go through the outbox, so a prompt is admitted once and survives the
/// app being closed; with the app in the background its servers are suspended, so the outbox is sent directly here,
/// as notification replies are, without waiting for the event stream.
@MainActor final class IntentActions: IntentApp {
    private let registry: @MainActor () async throws -> ServerRegistry
    private let links: LinkInbox
    private let clock: NetworkClock
    /// How long a send waits for the server before it reports the prompt as saved for later.
    let sendDeadline: Duration
    init(registry: @escaping @MainActor () async throws -> ServerRegistry, links: LinkInbox, clock: NetworkClock = .init(), sendDeadline: Duration = .seconds(10)) {
        self.registry = registry; self.links = links; self.clock = clock; self.sendDeadline = sendDeadline
    }
    func send(_ request: PromptRequest) async throws -> PromptReceipt {
        let registry = try await registry()
        let serverRef: String = switch request.destination { case .session(let server, _), .newSession(let server, _): server }
        guard let server = registry.servers.first(where: { $0.id.rawValue.uuidString == serverRef }) else { throw IntentError.serverUnavailable }
        let store = server.readPath
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentError.emptyPrompt }
        let sessionID: String, admitted: [String]
        switch request.destination {
        case .session(_, let id):
            guard let session = store.sessions[id] else { throw IntentError.sessionNotFound }
            // Refused before anything is admitted, as the composer refuses them.
            if session.info.parentID != nil { throw IntentError.subagentSession }
            if session.info.revert != nil { throw IntentError.revertStaged }
            let delivery: Delivery = session.status.isRunning ? Self.followUp : .steer
            admitted = [try await store.sendPrompt(id, input: PromptInput(text: text, delivery: delivery))]
            sessionID = id
        case .newSession(_, let projectID):
            guard let project = server.projects.first(where: { $0.id == projectID }) else { throw IntentError.projectNotFound }
            let id = try await store.createSession(location: .init(directory: project.canonical), projectID: project.id)
            admitted = [id, try await store.sendPrompt(id, input: PromptInput(text: text))]
            sessionID = id
        }
        // Admitted: from here nothing throws, so Shortcuts never offers to run it again.
        await store.drainNow(deadline: sendDeadline)
        let delivered = admitted.allSatisfy { store.outboxEntries[$0] == nil }
        let snapshot = store.sessions[sessionID].map { SystemSnapshotBuilder.session(SessionSummary(server: server, session: $0)) }
            ?? .init(server: serverRef, session: sessionID, title: localized("New session"), project: "", projectID: "", status: .idle, activity: clock.date())
        return PromptReceipt(session: snapshot, serverName: server.record.name, delivered: delivered)
    }
    /// The composer's Follow-up behavior for a running session.
    static var followUp: Delivery { UserDefaults.standard.string(forKey: "followUpBehavior") == "queue" ? .queue : .steer }

    func status(server serverRef: String, session id: String) async throws -> SessionStatusReport {
        let registry = try await registry()
        guard let server = registry.servers.first(where: { $0.id.rawValue.uuidString == serverRef }) else { throw IntentError.serverUnavailable }
        let store = server.readPath
        // Subagents' requests count as in Home; the server is asked about the session itself.
        let children = store.family(id).filter { $0.id != id }
        let childPermission = children.contains { !(store.permissions[$0.id] ?? []).isEmpty }
        let childQuestion = children.contains { !(store.forms[.session($0.id)] ?? []).isEmpty }
        if let client = store.client, var fresh = try? await withActionDeadline(seconds: .seconds(5), clock: clock, operation: {
            try await Self.fetchStatus(try await client(), session: id)
        }) {
            if fresh.state != .needsPermission && childPermission { fresh.state = .needsPermission }
            else if ![.needsPermission, .needsAnswer].contains(fresh.state) && childQuestion { fresh.state = .needsAnswer }
            return fresh
        }
        guard let session = store.sessions[id] else { throw IntentError.sessionNotFound }
        var report = Self.report(SessionSummary(server: server, session: session))
        // Before the first sync after a cold launch the cache has no requests or runs; the last snapshot knew better.
        if ![.needsPermission, .needsAnswer, .running, .retrying].contains(report.state), let row = registry.system?.carried()[serverRef + ":" + id] {
            report.state = switch row.status {
            case .needsYou: row.request?.kind == .question ? .needsAnswer : .needsPermission
            case .retrying: .retrying
            default: .running
            }
            report.runningSince = row.runningSince
        }
        report.live = false
        return report
    }
    /// The session, whether it runs, and its waiting requests, straight from the server.
    private static func fetchStatus(_ api: APIClient, session id: String) async throws -> SessionStatusReport {
        async let infoRequest = api.send(ReadEndpoints.session(id))
        async let activeRequest = api.send(ReadEndpoints.active)
        async let permissionRequest = api.send(ReadEndpoints.permissions(id))
        async let formRequest = api.send(ReadEndpoints.forms(id))
        let (info, active, permissions, forms) = try await (infoRequest.data, activeRequest.data, permissionRequest.data, formRequest.data)
        var report = report(info: info, running: active[id] != nil, permission: !permissions.isEmpty, question: !forms.isEmpty,
                            unread: (info.time.idle ?? 0) > (info.time.viewed ?? 0))
        if report.state == .running, let started = active[id]?["time"]?["started"]?.wireNumber ?? info.time.started, started > 0 {
            report.runningSince = Date(timeIntervalSince1970: started / 1_000)
        }
        return report
    }
    /// Home's state for a session the app has.
    static func report(_ item: SessionSummary) -> SessionStatusReport {
        let server = item.server
        let permission = item.family.contains { !(server.permissions[$0.id] ?? []).isEmpty }
        let question = item.family.contains { !(server.forms[.session($0.id)] ?? []).isEmpty }
        var report = report(info: item.session.info, running: item.runningCount > 0, permission: permission, question: question, unread: item.session.unread)
        if case .retrying = item.session.status, report.state == .running { report.state = .retrying }
        if case .running(let since) = item.session.status, since > 0 { report.runningSince = Date(timeIntervalSince1970: since / 1_000) }
        report.lastActivity = Date(timeIntervalSince1970: item.activity / 1_000)
        return report
    }
    /// A waiting request comes first, then a run, then how the last run ended.
    static func report(info: SessionInfo, running: Bool, permission: Bool, question: Bool, unread: Bool) -> SessionStatusReport {
        let ended: SessionStatusReport.State = switch info.outcome {
        case "failed": .failed
        case "interrupted": .stopped
        case "succeeded": .finished
        default: .idle
        }
        let state: SessionStatusReport.State = permission ? .needsPermission : question ? .needsAnswer : running ? .running : ended
        let updated = max(info.time.updated, info.time.created)
        return .init(state: state, title: info.title ?? localized("Untitled session"), unread: unread,
                     lastActivity: updated > 0 ? Date(timeIntervalSince1970: updated / 1_000) : nil)
    }

    func open(_ url: URL) { links.url = url }
    /// The first waiting permission or question in Home's order; Review next approval (⇧⌘A) presents it the same way.
    func nextApproval() async -> URL? {
        guard let registry = try? await registry() else { return nil }
        if let ref = HomeOrdering.approvals(HomeOrdering.ordered(registry.servers, server: nil, project: nil)).first {
            registry.servers.first { $0.id == ref.serverID }?.readPath.reviewRequest = ref.requestID
            return DeepLink.url(serverID: ref.serverID.rawValue, sessionID: ref.sessionID, requestID: ref.requestID)
        }
        // Before the servers have synced (a cold start from a control), what the snapshot last showed.
        return registry.system?.snapshot?.needsYou().first { $0.status == .needsYou }?.url
    }
    func newPrompt() async -> URL? {
        guard let registry = try? await registry() else { return nil }
        if let last = registry.system?.lastProject, let server = UUID(uuidString: last.server),
           registry.servers.contains(where: { $0.id.rawValue == server }) {
            return DeepLink.compose(serverID: server, projectID: last.project)
        }
        return registry.servers.first.flatMap { DeepLink.compose(serverID: $0.id.rawValue) }
    }
    /// Every session and project the registry has, not only the snapshot's: an intent that started the app waits for
    /// the registry to load, so a Shortcut or Spotlight result for an older session still finds it.
    func directory() async -> IntentDirectory {
        guard let registry = try? await registry() else { return IntentDirectory(IntentEnvironment.snapshot().snapshot) }
        return Self.directory(registry)
    }
    static func directory(_ registry: ServerRegistry) -> IntentDirectory {
        let servers = registry.servers
        let sessions = HomeOrdering.all(servers).map(SystemSnapshotBuilder.session)
        let snapshot = SystemSnapshotBuilder.build(servers, lastProject: nil, syncedAt: { _, _ in nil }, now: Date())
        return IntentDirectory(servers: snapshot.servers, projects: SystemSnapshotBuilder.projects(servers), sessions: sessions,
                               suggestsSessions: registry.system?.spotlightEnabled ?? true)
    }
}

