import Foundation
import OCFoundation
import OCModels
import OCNetworking
import OCPersistence

extension ReadStore {
    func handle(_ event: ServerEvent) {
        guard let header = event.header else { return }
        let type = header.type, p = WireObject(raw: event.payload), created = header.created ?? 0
        let id = event.sessionID ?? ""
        if type == "project.updated" {
            let project = Project(raw: event.payload)
            projects.removeAll { $0.id == project.id }; projects.append(project); schedulePersistence(); return
        }
        if type == "session.created" {
            acknowledgedSessions.insert(id); acknowledgeEvent(id)
            var info = p.raw
            for key in ["sessionID", "slug", "version"] { info.set(key, nil) }
            info.set("id", .string(id)); info.set("time", .object(["created": .number(created), "updated": .number(created)]))
            info.set("cost", .integer(0)); info.set("tokens", .object(["input": .integer(0), "output": .integer(0), "reasoning": .integer(0), "cache": .object(["read": .integer(0), "write": .integer(0)])]))
            if sessions[id] == nil { sessions[id] = SessionModel(info: .init(raw: info)) }
            scheduleRefresh(id); return
        }
        if type == "session.forked" { scheduleRefresh(id); return }
        if type == "session.inbox.enqueued" {
            admittedInputs.insert(p.string("inboxID")); acknowledgeEvent(p.string("inboxID"))
        }
        if type == "session.inbox.delivered" || type == "session.inbox.cancelled" {
            consumedInputs.insert(p.string("inboxID"))
            pendingDeliveries.removeValue(forKey: p.string("inboxID"))
            if type == "session.inbox.cancelled" { cancelledInputs.insert(p.string("inboxID")) }
            else { cancelledInputs.remove(p.string("inboxID")) }
        }
        if type == "session.compaction.started", let input = p["inputID"]?.stringValue { consumedInputs.insert(input) }
        if type == "session.deleted" {
            deletedSessions.insert(id)
            sessions.removeValue(forKey: id); running.remove(id); permissions.removeValue(forKey: id)
            forms.removeValue(forKey: .session(id)); openSessions.remove(id); openCounts[id] = nil; lru.removeAll { $0 == id }
            if let cache { owned { try await cache.writer.deleteSession(serverID: self.serverID, sessionID: id) } }
            updateAttention(); return
        }
        if type == "permission.asked" {
            let request = PermissionRequest(raw: p.raw)
            guard !hiddenPermissions.contains(request.id) else { return }
            permissions[id, default: []].removeAll { $0.id == request.id }; permissions[id, default: []].append(request)
            updateAttention(); return
        }
        if type == "permission.replied" {
            settledPermissions.insert(p.string("requestID"))
            permissions[id]?.removeAll { $0.id == p.string("requestID") }; updateAttention(); return
        }
        if type.hasPrefix("form.") {
            let ownerID = type == "form.created" ? p["form"]?["sessionID"]?.stringValue ?? id : id
            let owner: FormOwner = ownerID == "global" ? .global(location: Location(raw: header.location ?? .object([:])).key) : .session(ownerID)
            let formID = type == "form.created" ? p["form"]?["id"]?.stringValue ?? "" : p.string("id")
            if type == "form.replied", let start = answerStarts.removeValue(forKey: formID) {
                let duration = start.duration(to: clock.now()).components
                lastAnswerRoundTrip = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            }
            if type != "form.created" { settledForms[owner, default: []].insert(formID) }
            forms[owner, default: []].removeAll { $0.id == formID }
            if type == "form.created", !(hiddenForms[owner]?.contains(formID) ?? false), let raw = p["form"] { forms[owner, default: []].append(.init(raw: raw)) }
            updateAttention(); return
        }
        if type.hasPrefix("pty.") {
            terminalLists[Location(raw: header.location ?? .object([:])).directory]?.handle(type: type, payload: event.payload)
            return
        }
        if type.hasPrefix("shell.") {
            shellRuns[Location(raw: header.location ?? .object([:])).directory]?.handle(type: type, payload: event.payload)
            let key = Location(raw: header.location ?? .object([:])).key
            if type == "shell.created", let raw = p["info"] {
                let shell = ShellInfo(raw: raw); shells[key, default: [:]][shell.id] = shell
                if let owner = shell.metadata?["sessionID"]?.stringValue, let start = approvalStarts.removeValue(forKey: owner) {
                    let duration = start.duration(to: clock.now()).components
                    lastApprovalRoundTrip = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                }
            } else { shells[key]?.removeValue(forKey: p.string("id")) }
            return
        }
        if type == "worktree.resolved" { adoptWorktree(p); for model in liveAdminModels { model.handle(type: type, payload: event.payload) }; return }
        if hiddenSessions.contains(id) { return }
        if type == "session.execution.started" { running.insert(id) }
        if ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].contains(type) { running.remove(id) }
        guard let session = sessions[id] else {
            if !id.isEmpty { scheduleRefresh(id) }
            handleCatalog(event); return
        }
        let transcript = session.transcript
        let eventRowID = header.id.replacingOccurrences(of: "evt_", with: "msg_", options: .anchored)
        let assistant = transcript?.messages[p.string("assistantMessageID")]
        let touchTypes: Set<String> = ["session.moved", "session.agent.selected", "session.model.selected", "session.renamed",
            "session.metadata.updated", "session.permissions", "session.inbox.enqueued", "session.step.started", "session.step.ended",
            "session.step.failed", "session.revert.staged", "session.revert.cleared", "session.revert.committed",
            "session.archived", "session.unarchived"]
        if touchTypes.contains(type) { session.info.raw.set(["time", "updated"], .number(created)) }
        func protect(_ rowID: String) {
            guard event.sequence != nil else { return }
            for overlay in overlays.values { overlay.changed[id, default: []].insert(rowID) }
        }
        func insert(_ rowType: String, _ fields: [String: JSONValue?] = [:], rowID: String? = nil) {
            var raw: JSONValue = .object(["id": .string(rowID ?? eventRowID), "type": .string(rowType), "time": .object(["created": .number(created)])])
            raw.set("metadata", header.metadata)
            for (key, value) in fields { raw.set(key, value) }
            transcript?.upsert(.init(raw: raw))
            protect(rowID ?? eventRowID)
            if let seq = event.sequence { session.rowSequences[rowID ?? eventRowID] = seq }
        }
        switch type {
        case "session.renamed": session.info["title"] = p["title"]
        case "session.metadata.updated": session.info["metadata"] = p["metadata"]
        case "session.permissions": session.info["permissions"] = p["permissions"]
        case "session.usage.updated": session.info["cost"] = p["cost"]; session.info["tokens"] = p["tokens"]
        case "session.viewed":
            session.info.raw.set(["time", "viewed"], .number(max(session.info.time.viewed ?? 0, p.number("idle"))))
            updateAttention()
        // 2.1.0 and later: archived from another client, or by `opencode run --archived`. Home leaves it out.
        case "session.archived": session.info.raw.set(["time", "archived"], .number(created))
        case "session.unarchived": session.info.raw.set(["time", "archived"], nil)
        case "session.agent.selected", "session.model.selected":
            let field = type == "session.agent.selected" ? "agent" : "model"
            let previous = p["previous"] ?? session.info[field]
            insert("\(field)-switched", [field: p[field], "previous": previous])
            session.info[field] = p[field]
            composers["session:" + id]?.reconcileSelection()
        case "session.moved":
            let previous = JSONValue.object(["location": session.info.location.raw, "projectID": .string(session.info.projectID), "subpath": session.info["subpath"] ?? .null]).omittingNullFields
            insert("location-switched", ["location": p["location"], "projectID": p["projectID"], "subpath": p["subpath"], "previous": previous])
            for key in ["location", "projectID", "subpath"] { session.info[key] = p[key] }
            sessionMoved(id)
        case "session.inbox.enqueued":
            var raw = p["item"] ?? .object([:]); raw.set("id", p["inboxID"]); raw.set("sessionID", .string(id))
            raw.set("time", .object(["created": .number(created)]))
            let item = InboxItem(raw: raw)
            guard !cancelledInputs.contains(item.id) else { break }
            session.pending.removeAll { $0.id == item.id }; session.pending.append(item)
            session.pendingSequences[item.id] = event.sequence
            materialize(item, session: session)
        case "session.inbox.delivered":
            let inboxID = p.string("inboxID")
            let admitted = session.pending.contains { $0.id == inboxID }
            session.pending.removeAll { $0.id == inboxID }
            if admitted, let row = transcript?.messages[inboxID] {
                row.fields.raw.set(["time", "created"], .number(created)); row.acknowledged = true
                transcript?.moveToEnd(inboxID)
                session.rowSequences[inboxID] = event.sequence
            } else if transcript != nil && transcript?.messages[inboxID] == nil { scheduleRefresh(id) }
        case "session.inbox.cancelled":
            session.pending.removeAll { $0.id == p.string("inboxID") }; transcript?.remove(p.string("inboxID"))
            for overlay in overlays.values { overlay.removed[id, default: []].insert(p.string("inboxID")) }
        case "session.inbox.delivery.changed":
            pendingDeliveries.removeValue(forKey: p.string("inboxID"))
            if let index = session.pending.firstIndex(where: { $0.id == p.string("inboxID") }) {
                var raw = session.pending[index].raw; raw.set("delivery", p["delivery"]); session.pending[index] = .init(raw: raw)
            }
        case "session.execution.started":
            running.insert(id); session.status = .running(since: created); session.turnStartedAt = created
            if projectsBusyTime { session.info.raw.set(["time", "busy"], .number(created)) }
            session.executionID = header.id
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            running.remove(id); session.status = .idle
            for row in transcript?.messages.values ?? [:].values where row.fields.type == "assistant" && row.fields["retry"] != nil {
                row.fields["retry"] = nil; protect(row.id)
            }
            if type == "session.execution.interrupted", p.string("reason") == "shutdown" { return }
            let outcome = String(type.split(separator: ".").last ?? "interrupted")
            insert("idle", ["outcome": .string(outcome), "error": type == "session.execution.failed" ? p["error"] : nil])
            session.info["outcome"] = .string(outcome)
            session.info.raw.set(["time", "idle"], .number(max(created, (session.info.time.idle ?? (created - 1)) + 1)))
            if transcript?.messages.values.contains(where: { $0.items.contains { ["running", "streaming"].contains($0.fields.toolState.type) } }) == true { scheduleRefresh(id) }
            updateAttention()
        case "session.synthetic": insert("synthetic", ["text": p["text"], "description": p["description"], "metadata": p["metadata"]])
        case "session.instructions.updated":
            if let text = p["text"] {
                let keys = p["delta"]?.objectValue?.keys.sorted() ?? []
                insert("system", ["text": text, "description": .string("Instructions updated: " + keys.joined(separator: ", "))])
            }
        case "session.skill.activated": insert("skill", ["skill": p["id"], "name": p["name"], "text": p["text"]])
        case "session.shell.started":
            let shell = p.object("shell", as: ShellInfo.self)
            var metadata = header.metadata
            if shell.metadata?["background"]?.boolValue == true { var raw = metadata ?? .object([:]); raw.set("background", .bool(true)); metadata = raw }
            insert("shell", ["shellID": .string(shell.id), "command": .string(shell.command), "status": .string(shell.status), "exit": shell["exit"], "metadata": metadata])
        case "session.shell.ended":
            if let row = transcript?.messages.values.first(where: { $0.fields.shellID == p["shell"]?["id"]?.stringValue }) {
                row.fields["status"] = p["shell"]?["status"]; row.fields["exit"] = p["shell"]?["exit"]; row.fields["output"] = p["output"]
                row.fields.raw.set(["time", "completed"], .number(created))
                protect(row.id)
            }
        case "session.step.started":
            if let previous = transcript?.order.reversed().compactMap({ transcript?.messages[$0] }).first(where: { $0.fields.type == "assistant" }), previous.fields.time.completed == nil, previous.id != p.string("assistantMessageID") {
                previous.fields["retry"] = nil; previous.fields.raw.set(["time", "completed"], .number(created))
                protect(previous.id)
            }
            if let assistant {
                for key in ["retry", "error", "finish", "rawFinish", "providerState", "native"] { assistant.fields[key] = nil }
                assistant.fields["agent"] = p["agent"]; assistant.fields["model"] = p["model"]
                assistant.fields["time"] = .object(["created": p["started"] ?? .number(created)])
                if let snapshot = p["snapshot"] { assistant.fields.raw.set(["snapshot", "start"], snapshot) }
            } else {
                insert("assistant", ["agent": p["agent"], "model": p["model"], "content": .array([]),
                    "snapshot": p["snapshot"].map { .object(["start": $0]) }, "time": .object(["created": p["started"] ?? .number(created)])], rowID: p.string("assistantMessageID"))
            }
            session.status = .running(since: created)
        case "session.step.streamed": assistant?.fields.raw.set(["time", "streamed"], .number(created))
        case "session.step.ended", "session.step.failed":
            assistant?.fields.raw.set(["time", "completed"], .number(created))
            for key in ["finish", "rawFinish", "providerState", "native"] { assistant?.fields[key] = p[key] }
            if type == "session.step.ended" || (p["cost"] != nil && p["tokens"] != nil) {
                assistant?.fields["cost"] = p["cost"]; assistant?.fields["tokens"] = p["tokens"]
            }
            if type == "session.step.failed" {
                assistant?.fields["finish"] = p["finish"] ?? .string("error"); assistant?.fields["error"] = p["error"]; assistant?.fields["retry"] = nil
            }
            if let snapshot = p["snapshot"] { assistant?.fields.raw.set(["snapshot", "end"], snapshot) }
            if let files = p["files"] { assistant?.fields.raw.set(["snapshot", "files"], files) }
        case "session.retry.scheduled":
            assistant?.fields["retry"] = .object(["attempt": p["attempt"] ?? .integer(0), "at": p["at"] ?? .integer(0), "error": p["error"] ?? .object([:])])
            session.status = .retrying(attempt: p.number("attempt"), at: p.number("at"))
        case "session.text.started", "session.text.delta", "session.text.ended", "session.reasoning.started", "session.reasoning.delta", "session.reasoning.ended":
            applyText(type, p: p, assistant: assistant, created: created)
        case let type where type.hasPrefix("session.tool."):
            applyTool(type, p: p, assistant: assistant, created: created)
        case "session.compaction.started":
            let input = p["inputID"]?.stringValue
            session.pending.removeAll { $0.id == input }
            // `recent` is gone from 2.1.0 on.
            insert("compaction", ["status": .string("running"), "reason": p["reason"], "summary": .string(""), "recent": p["recent"]], rowID: input)
        case "session.compaction.delta":
            if let row = activeCompaction(transcript) { row.fields["summary"] = .string((row.fields.summary ?? "") + p.string("text")) }
        case "session.compaction.ended", "session.compaction.failed":
            let current = activeCompaction(transcript), failed = type.hasSuffix("failed")
            let rowID = current?.id ?? p["inputID"]?.stringValue ?? eventRowID
            var fields: [String: JSONValue?] = ["status": .string(failed ? "failed" : "completed"), "reason": p["reason"] ?? .string("manual"),
                "cost": p["cost"], "tokens": p["tokens"]]
            if failed { fields["error"] = p["error"] }
            else {
                fields["summary"] = p["text"]; fields["recent"] = p["recent"]
                for key in ["model", "providerState", "providerContext", "native"] { fields[key] = p[key] }
            }
            if let current {
                fields["time"] = current.fields["time"]
                let metadata: JSONValue? = current.fields.metadata ?? header.metadata
                fields["metadata"] = metadata
                if !failed, let update = header.metadata?.objectValue {
                    fields["metadata"] = .object((current.fields.metadata?.objectValue ?? [:]).merging(update) { _, new in new })
                }
            }
            insert("compaction", fields, rowID: rowID)
            if let input = p["inputID"]?.stringValue { session.pending.removeAll { $0.id == input } }
        case "session.revert.staged": session.info["revert"] = p["revert"]
        case "session.revert.cleared": session.info["revert"] = nil
        case "session.revert.committed":
            session.info["revert"] = nil
            let boundary = p.string("to"), seq = session.rowSequences[boundary]
            let removed = transcript?.truncate(at: boundary) ?? []
            session.pending.removeAll { item in
                if let seq, let enqueued = session.pendingSequences[item.id] { return enqueued >= seq }
                return removed.contains(item.id) || item.id >= boundary
            }
            for overlay in overlays.values { overlay.removed[id, default: []].formUnion(removed) }
        default: handleCatalog(event)
        }
    }
    func materialize(_ item: InboxItem, session: SessionModel, acknowledged: Bool = true) {
        guard item.type == "user" || item.type == "synthetic" else { return }
        var raw = item.fields.payload.raw
        raw.set("id", .string(item.id)); raw.set("type", .string(item.type)); raw.set("time", item.fields.time.raw)
        session.transcript?.upsert(.init(raw: raw), acknowledged: acknowledged)
    }
    private func activeCompaction(_ transcript: TranscriptModel?) -> MessageModel? {
        transcript?.order.reversed().compactMap { transcript?.messages[$0] }.first { $0.fields.type == "compaction" && $0.fields.status == "running" }
    }
    private func adoptWorktree(_ p: WireObject) {
        for session in sessions.values {
            let info = session.info
            guard info.location.workspaceID == nil else { continue }
            let adopted = p.strings("adopted").contains(info.projectID)
            guard adopted || info.projectID == p.string("previous") || info.projectID == "global" else { continue }
            let directory = adopted ? projects.first { $0.id == info.projectID }?.canonical : info.location.directory
            guard let directory else { scheduleRefresh(info.id); continue }
            let root = p.string("directory").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let path = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path == root || path.hasPrefix(root + "/") else { continue }
            session.info["projectID"] = p["projectID"]
            session.info["subpath"] = .string(path == root ? "" : String(path.dropFirst(root.count + 1)))
            for overlay in overlays.values { overlay.recordInfo(info.id, before: info.raw, after: session.info.raw) }
            dirty.insert(info.id)
        }
        schedulePersistence()
    }
}
