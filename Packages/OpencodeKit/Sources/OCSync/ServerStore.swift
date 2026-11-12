import Foundation
import Observation
import OCFoundation
import OCModels
import OCNetworking
import OCSecurity
import OCPersistence

@MainActor @Observable public final class ServerStore: Identifiable {
    @ObservationIgnored var pushConnectionChanged: @MainActor () -> Void = {}
    public var id: ServerID { record.id }
    public private(set) var record: ServerRecord
    public private(set) var state: ConnectionState = .idle
    public private(set) var lastResolution: EndpointResolution?
    public private(set) var transitions: [StateTransition] = []
    public private(set) var capabilities: ServerCapabilities
    public var info: ServerInfo? { record.lastInfo }
    public var version: String? {
        switch state {
        case .incompatible(.v1(let version)): version
        case .incompatible(.unsupportedV2(let info)): info.version
        default: info?.version
        }
    }
    public private(set) var tokenExpiresAt: Date?
    public var tokenExpiresSoon: Bool { tokenExpiresAt.map { $0.timeIntervalSince(clock.date()) <= 5 * 86400 } ?? false }
    public private(set) var needsRepair = false
    public private(set) var persistenceError: String?
    public let connection: any ConnectionControlling
    public let eventSink: any ServerEventSink
    public let readPath: ReadStore
    public var projects: [Project] { readPath.projects }
    public var sessions: [String: SessionModel] { readPath.sessions }
    public var running: Set<String> { readPath.running }
    public var permissions: [String: [PermissionRequest]] { readPath.permissions }
    public var forms: [FormOwner: [FormInfo]] { readPath.forms }
    public var catalogs: [String: LocationCatalog] { readPath.catalogs }
    @ObservationIgnored public private(set) var resync: ResyncCoordinator?
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let clock: NetworkClock
    @ObservationIgnored private let fetchInfo: @Sendable (URL, Credential?, [String: String]) async throws -> ServerInfo
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var resolutionTime: ContinuousClock.Instant?
    @ObservationIgnored private var hasResolution = false
    @ObservationIgnored private let recordChanged: @MainActor () async throws -> Void
    @ObservationIgnored private let canConnect: @MainActor () -> Bool

    public init(record: ServerRecord, connection: any ConnectionControlling, credentials: CredentialStore,
                clock: NetworkClock = .init(), cache: CacheStore? = nil, residency: TranscriptResidency = .init(),
                drafts: DraftStore? = nil, background: (any BackgroundTaskProviding)? = nil, eventSink: (any ServerEventSink)? = nil,
                extensionWork: (any ResyncExtension)? = nil, transport: (any HTTPTransport)? = nil,
                fetchInfo: (@Sendable (URL, Credential?, [String: String]) async throws -> ServerInfo)? = nil,
                canConnect: @escaping @MainActor () -> Bool = { true },
                recordChanged: @escaping @MainActor () async throws -> Void = {}) {
        self.record = record; self.connection = connection; self.credentials = credentials; self.clock = clock
        self.capabilities = .init(info: record.lastInfo)
        let readPath = ReadStore(serverID: record.id.rawValue.uuidString, cache: cache, clock: clock, residency: residency, drafts: drafts, background: background)
        readPath.projectsBusyTime = record.lastInfo?.reportsBusyTime ?? false
        readPath.filtersArchived = record.lastInfo?.filtersArchivedSessions ?? false
        self.readPath = readPath; self.eventSink = eventSink ?? readPath
        self.recordChanged = recordChanged
        self.canConnect = canConnect
        let transport = transport ?? URLSessionTransport()
        self.fetchInfo = fetchInfo ?? { url, credential, headers in
            try await APIClient(baseURL: url, credential: credential, headers: headers, transport: transport, clock: clock)
                .send(Endpoint<ServerInfo>.json(path: "/api/info"))
        }
        resync = ResyncCoordinator(date: clock.date, extensionWork: extensionWork ?? readPath) { [weak self] _ in
            guard let self else { throw CancellationError() }
            try await self.refreshInfo()
        }
        readPath.client = { [weak self] in
            guard let self, let endpoint = self.lastResolution?.selected ?? self.record.endpoints.first else { throw CancellationError() }
            return try await APIClient(baseURL: endpoint.url, credential: self.credentials.credential(for: self.id),
                                       headers: self.credentials.headers(for: self.id), transport: transport, clock: clock,
                                       serverClock: self.readPath.serverClock)
        }
        consumer = Task { [weak self, connection] in
            for await output in connection.output {
                guard !Task.isCancelled, let self else { return }
                await self.receive(output)
            }
        }
    }
    deinit { consumer?.cancel() }

    public func start(rerace: Bool = true) async {
        guard canConnect() else { return }
        isSuspended = false
        readPath.resume()
        await updateExpiry()
        guard !isSuspended, !needsRepair, canConnect() else { return }
        await connection.start(rerace: rerace)
    }
    public func suspend() async {
        isSuspended = true
        await connection.stop()
        await resync?.stop()
        await readPath.stop()
    }
    public func dispose() async {
        await suspend(); consumer?.cancel(); consumer = nil
    }
    public func reconnect(rerace: Bool = true, reason: ReconnectReason = .userRequested) async {
        guard !needsRepair, canConnect() else { return }
        await start(rerace: rerace)
        guard !isSuspended, canConnect() else { return }
        await connection.forceReconnect(reason, rerace: rerace)
    }
    public func resume(pathChanged: Bool) async {
        let snapshot = await connection.snapshot()
        let stale = snapshot.lastResolvedAt.map { $0.duration(to: clock.now()) > .seconds(60) } ?? true
        let quiet = snapshot.lastActivity.map { $0.duration(to: clock.now()) > .seconds(20) } ?? false
        await start(rerace: pathChanged || stale)
        if quiet && !isSuspended && canConnect() { await connection.forceReconnect(.foreground, rerace: pathChanged || stale) }
    }
    public func rename(_ name: String) async throws {
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await recordChanged()
    }
    public func replaceEndpoints(_ endpoints: [EndpointRecord]) async throws {
        guard !endpoints.isEmpty else { throw ServerSetupError.lastEndpoint }
        for endpoint in endpoints { try EndpointPolicy.validate(endpoint.url) }
        await suspend()
        record.endpoints = endpoints
        try await recordChanged()
        try await configure()
        await start()
    }
    public func repair(credential: Credential, endpoints: [EndpointRecord]? = nil) async throws {
        await suspend()
        try await credentials.save(credential, headers: credentials.headers(for: id), for: id)
        if let endpoints { record.endpoints = endpoints; try await recordChanged() }
        needsRepair = false
        try await configure()
        await start()
    }
    private func configure() async throws {
        let credential = try await credentials.credential(for: id)
        let headers = try await credentials.headers(for: id)
        await connection.configure(endpoints: record.endpoints, credential: credential, headers: headers)
    }
    private func updateExpiry() async {
        if let credential = try? await credentials.credential(for: id), case .pairingToken(_, let expiry) = credential {
            tokenExpiresAt = expiry
        } else { tokenExpiresAt = nil }
    }
    private func receive(_ output: ConnectionOutput) async {
        switch output {
        case .state(let state):
            if case .connected = state { readPath.setWritesConnected(true); pushConnectionChanged() }
            else { readPath.setWritesConnected(false) }
            if state == .unauthorized { needsRepair = true }
            setState(needsRepair ? .unauthorized : state)
            readPath.offline = ConnectionNotice.isOffline(self.state)
            switch state {
            case .idle, .suspended, .resolving: return
            default: break
            }
            let snapshot = await connection.snapshot()
            if let resolution = snapshot.resolution {
                let isNew = !hasResolution || snapshot.lastResolvedAt != resolutionTime
                lastResolution = resolution
                if isNew {
                    hasResolution = true; resolutionTime = snapshot.lastResolvedAt
                    for (id, diagnosis) in resolution.diagnoses {
                        guard let index = record.endpoints.firstIndex(where: { $0.id == id }) else { continue }
                        switch diagnosis {
                        case .success(let info):
                            record.endpoints[index].stats.lastSuccess = clock.date()
                            record.endpoints[index].stats.lastFailure = nil
                            apply(info)
                        case .failure(let failure): record.endpoints[index].stats.lastFailure = failure
                        default: break
                        }
                    }
                    discover(resolution.discovered.map(\.url))
                    await connection.updateEndpoints(record.endpoints)
                    await persist()
                }
                if case .waiting(_, _, let failure) = state,
                   let index = record.endpoints.firstIndex(where: { $0.id == resolution.selected?.id }) {
                    record.endpoints[index].stats.lastFailure = failure
                    await persist()
                }
            }
        case .events(let batch): eventSink.receive(batch)
        case .resyncNeeded(let reason):
            if !isSuspended { resync?.enqueue(reason) }
        }
    }
    private func setState(_ state: ConnectionState) {
        self.state = state
        transitions.append(.init(state: state, at: clock.now()))
        if transitions.count > 50 { transitions.removeFirst(transitions.count - 50) }
    }
    private func apply(_ info: ServerInfo) {
        var safeInfo = info
        safeInfo.urls = info.urls.filter { (try? EndpointPolicy.validate($0)) != nil }
        record.lastInfo = safeInfo; capabilities = .init(info: info); readPath.projectsBusyTime = info.reportsBusyTime
        readPath.filtersArchived = info.filtersArchivedSessions
        discover(info.urls)
    }
    private func discover(_ urls: [URL]) {
        for url in urls where !EndpointPolicy.isLoopback(url) && !record.endpoints.contains(where: { $0.url == url }) {
            guard (try? EndpointPolicy.validate(url)) != nil else { continue }
            record.endpoints.append(.init(url: url, kind: EndpointPolicy.classify(url), source: .discovered))
        }
    }
    private func persist() async {
        do { try await recordChanged(); persistenceError = nil }
        catch { persistenceError = localized("Could not save server changes. Try again.") }
    }
    private func refreshInfo() async throws {
        guard let endpoint = lastResolution?.selected ?? record.endpoints.first else { return }
        do {
            let credential = try await credentials.credential(for: id)
            let headers = try await credentials.headers(for: id)
            let info = try await fetchInfo(endpoint.url, credential, headers)
            try Task.checkCancellation()
            apply(info)
            await connection.updateEndpoints(record.endpoints)
            try await recordChanged()
        } catch APIError.unauthorized {
            needsRepair = true
            await connection.stop()
            setState(.unauthorized)
            throw APIError.unauthorized
        }
    }

    /// Deliberately export only allowlisted metadata: no names, paths, headers, bodies or event payloads.
    public func diagnosticsExport() -> String {
        let rows = transitions.map { transition in
            let age = transition.at.duration(to: clock.now()).components.seconds
            return "\(age)s ago: \(transitionDescription(transition))"
        }
        let endpoints = record.endpoints.map { endpoint in
            "\(endpoint.kind.rawValue): \(endpoint.url.scheme == "https" ? "encrypted" : "unencrypted") — \(diagnosis(for: endpoint.id))"
        }
        let version = version.flatMap(SemVer.init).map { "\($0.major).\($0.minor).\($0.patch)" } ?? "unknown"
        return (["Opencode connection diagnostics", "Version: \(version)"] + endpoints + rows).joined(separator: "\n")
    }
    public func transitionDescription(_ transition: StateTransition) -> String {
        switch transition.state {
        case .idle: return localized("Idle", comment: "Connection state")
        case .resolving: return localized("Resolving endpoints")
        case .connecting(let attempt): return localized("Connecting (attempt \(attempt))", comment: "Connection history; %lld is the attempt number")
        default:
            let status = ServerStatus(state: transition.state, endpoints: record.endpoints, now: transition.at)
            return status.title + (status.detail.map { " — " + $0 } ?? "")
        }
    }
    public func diagnosis(for id: EndpointID) -> String {
        if let failure = record.endpoints.first(where: { $0.id == id })?.stats.lastFailure { return failure.message }
        guard let diagnosis = lastResolution?.diagnoses[id] else { return localized("Not checked", comment: "Endpoint health: not yet checked") }
        switch diagnosis {
        case .success: return localized("Healthy", comment: "Endpoint health")
        case .failure(let failure): return failure.message
        case .starting: return localized("Server is starting")
        case .incompatible(.v1): return localized("Needs opencode 2")
        case .incompatible: return localized("Unsupported server version")
        case .notSelected: return localized("Another endpoint won the race")
        }
    }
}
