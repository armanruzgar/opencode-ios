import Foundation
import Observation
import OCFoundation
import OCModels
import OCNetworking
import OCPersistence

extension ReadStore {
    public func markViewed(_ id: String) async throws {
        guard let idle = sessions[id]?.info.time.idle, let client else { return }
        let api = try await client()
        try await api.send(ReadEndpoints.viewed(id, idle: idle))
        // A turn finishing during the request must remain unread.
        if let session = sessions[id] {
            session.info.raw.set(["time", "viewed"], .number(max(session.info.time.viewed ?? 0, idle)))
            dirty.insert(id); updateAttention(); schedulePersistence()
        }
    }
    public func setLocalMeta(_ value: SessionLocalMeta, sessionID: String) async throws {
        try await cache?.writer.setSessionLocalMeta(value, serverID: serverID, sessionID: sessionID)
        localMeta[sessionID] = value
    }
    /// The family API returns immediate children; walk it to include nested subagents too.
    public func loadFamily(_ root: String) async throws {
        guard let client else { return }
        let api = try await client()
        var queue = [root], seen: Set<String> = []
        while let id = queue.popLast() {
            guard seen.insert(id).inserted else { continue }
            var cursor: String?
            repeat {
                let token = UUID(), overlay = FetchOverlay(); overlays[token] = overlay
                defer { overlays.removeValue(forKey: token) }
                let page = try await api.send(ReadEndpoints.sessions(filter: .init(parentID: id), limit: 200, cursor: cursor))
                try Task.checkCancellation()
                for info in page.data {
                    guard !hiddenSessions.contains(info.id), !overlay.events.contains(where: { $0.header?.type == "session.deleted" && $0.sessionID == info.id }) else { continue }
                    let model = sessions[info.id] ?? SessionModel(info: info)
                    model.info = overlay.apply(to: info); sessions[info.id] = model; dirty.insert(info.id)
                    if let title = pendingTitles[info.id] { model.info["title"] = .string(title) }
                    if !seen.contains(info.id) { queue.append(info.id) }
                }
                let next = page.cursor.next
                cursor = next == cursor ? nil : next
            } while cursor != nil
        }
        updateAttention(); schedulePersistence()
    }
    @discardableResult public func listSessions(search: String? = nil, project: String? = nil, cursor: String? = nil) async throws -> String? {
        guard let client else { return nil }
        let api = try await client(), token = UUID(), overlay = FetchOverlay()
        overlays[token] = overlay; defer { overlays.removeValue(forKey: token) }
        let page = try await api.send(ReadEndpoints.sessions(filter: .init(search: search, project: project, archived: filtersArchived ? false : nil), limit: 200, cursor: cursor))
        try Task.checkCancellation()
        for info in page.data {
            guard !hiddenSessions.contains(info.id), !overlay.events.contains(where: { $0.header?.type == "session.deleted" && $0.sessionID == info.id }) else { continue }
            let model = sessions[info.id] ?? SessionModel(info: info)
            model.info = overlay.apply(to: info); sessions[info.id] = model; dirty.insert(info.id)
                    if let title = pendingTitles[info.id] { model.info["title"] = .string(title) }
        }
        let next = page.nextCursor(limit: 200)
        if search == nil && project == nil { rootCursor = next }
        updateAttention(); schedulePersistence()
        return next
    }
    public func family(_ root: String) -> [SessionModel] {
        var result: [SessionModel] = [], ids: Set<String> = [], queue = [root]
        let children = Dictionary(grouping: sessions.values.filter { $0.info.parentID != nil }, by: { $0.info.parentID ?? "" })
        while let id = queue.popLast() {
            guard ids.insert(id).inserted else { continue }
            if let model = sessions[id] { result.append(model) }
            queue += (children[id] ?? []).map(\.id).filter { !ids.contains($0) }
        }
        return result
    }
    public func shellOutput(_ shellID: String, directory: String, cursor: Int?) async throws -> ShellOutput? {
        guard let client, !stopped else { return nil }
        return try await client().send(ReadEndpoints.shellOutput(shellID, directory: directory, cursor: cursor, limit: 65_536)).data
    }
}

/// A visible shell row owns this model. stop() is called on invisibility, backgrounding and disposal.
@MainActor @Observable public final class ShellOutputModel {
    public private(set) var output = ""
    public private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var cursor: Int?
    private var identity: String?
    public init() {}
    deinit { task?.cancel() }
    public func start(store: ReadStore, shellID: String, directory: String, running: Bool) {
        stop()
        let next = store.serverID + ":" + directory + ":" + shellID
        if identity != next { identity = next; cursor = nil; output = ""; error = nil }
        task = Task { [weak self] in
            do {
                repeat {
                    guard let self else { return }
                    let page = try await store.shellOutput(shellID, directory: directory, cursor: self.cursor)
                    try Task.checkCancellation()
                    guard let page else {
                        // Scene activation may arrive before the owning server resumes.
                        if running { try await store.clock.sleep(.seconds(1)); continue }
                        return
                    }
                    self.output += page.output
                    // Bound the retained live tail independently of the server's cursor.
                    if self.output.utf8.count > 65_536 { self.output = String(self.output.suffix(32_768)) }
                    self.cursor = page.cursor >= 0 && page.cursor < Double(Int.max) ? Int(page.cursor) : nil
                    self.error = nil
                    if running { try await store.clock.sleep(.seconds(1)) }
                } while running && !Task.isCancelled
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self?.error = localized("Could not load shell output.") }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
}
