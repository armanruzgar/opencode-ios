import Foundation
import OCFoundation

public struct EventHeader: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let created: Double?
    public let location: JSONValue?
    public let metadata: JSONValue?
    public let durable: JSONValue?
    public init(id: String, type: String, created: Double? = nil, location: JSONValue? = nil, durable: JSONValue? = nil, metadata: JSONValue? = nil) {
        self.id = id; self.type = type; self.created = created; self.location = location; self.durable = durable; self.metadata = metadata
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type)
        try c.encodeIfNotNull(created.map(JSONValue.number), forKey: .created)
        try c.encodeIfNotNull(location, forKey: .location); try c.encodeIfNotNull(durable, forKey: .durable)
        try c.encodeIfNotNull(metadata, forKey: .metadata)
    }
    private enum CodingKeys: String, CodingKey { case id, type, created, location, durable, metadata }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        created = try c.decodeNumberIfPresent(forKey: .created)
        location = try c.decodeIfPresent(JSONValue.self, forKey: .location)
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        durable = try c.decodeIfPresent(JSONValue.self, forKey: .durable)
    }
}

public enum ServerEvent: Sendable, Equatable {
    case connected(EventHeader)
    case rpc(EventHeader, JSONValue)
    case locationShutdown(EventHeader, LocationShutdownPayload)
    case modelsDevRefreshed(EventHeader, ModelsDevRefreshedPayload)
    case credentialUpdated(EventHeader, CredentialUpdatedPayload)
    case credentialSwitched(EventHeader, CredentialSwitchedPayload)
    case integrationUpdated(EventHeader, IntegrationUpdatedPayload)
    case providerUpdated(EventHeader, ProviderUpdatedPayload)
    case modelUpdated(EventHeader, ModelUpdatedPayload)
    case agentUpdated(EventHeader, AgentUpdatedPayload)
    case sessionCreated(EventHeader, SessionCreatedPayload)
    case sessionAgentSelected(EventHeader, SessionAgentSelectedPayload)
    case sessionModelSelected(EventHeader, SessionModelSelectedPayload)
    case sessionMoved(EventHeader, SessionMovedPayload)
    case sessionRenamed(EventHeader, SessionRenamedPayload)
    case sessionMetadataUpdated(EventHeader, SessionMetadataUpdatedPayload)
    case sessionPermissions(EventHeader, SessionPermissionsPayload)
    case sessionViewed(EventHeader, SessionViewedPayload)
    case sessionArchived(EventHeader, SessionArchivedPayload)
    case sessionUnarchived(EventHeader, SessionUnarchivedPayload)
    case sessionUsageUpdated(EventHeader, SessionUsageUpdatedPayload)
    case sessionDeleted(EventHeader, SessionDeletedPayload)
    case sessionForked(EventHeader, SessionForkedPayload)
    case sessionInboxDelivered(EventHeader, SessionInboxDeliveredPayload)
    case sessionInboxEnqueued(EventHeader, SessionInboxEnqueuedPayload)
    case sessionInboxCancelled(EventHeader, SessionInboxCancelledPayload)
    case sessionInboxDeliveryChanged(EventHeader, SessionInboxDeliveryChangedPayload)
    case sessionExecutionStarted(EventHeader, SessionExecutionStartedPayload)
    case sessionExecutionSucceeded(EventHeader, SessionExecutionSucceededPayload)
    case sessionExecutionFailed(EventHeader, SessionExecutionFailedPayload)
    case sessionExecutionInterrupted(EventHeader, SessionExecutionInterruptedPayload)
    case sessionInstructionsUpdated(EventHeader, SessionInstructionsUpdatedPayload)
    case sessionSynthetic(EventHeader, SessionSyntheticPayload)
    case sessionSkillActivated(EventHeader, SessionSkillActivatedPayload)
    case sessionShellStarted(EventHeader, SessionShellStartedPayload)
    case sessionShellEnded(EventHeader, SessionShellEndedPayload)
    case sessionStepStarted(EventHeader, SessionStepStartedPayload)
    case sessionStepStreamed(EventHeader, SessionStepStreamedPayload)
    case sessionStepEnded(EventHeader, SessionStepEndedPayload)
    case sessionStepFailed(EventHeader, SessionStepFailedPayload)
    case sessionTextStarted(EventHeader, SessionTextStartedPayload)
    case sessionTextDelta(EventHeader, SessionTextDeltaPayload)
    case sessionTextEnded(EventHeader, SessionTextEndedPayload)
    case sessionReasoningStarted(EventHeader, SessionReasoningStartedPayload)
    case sessionReasoningDelta(EventHeader, SessionReasoningDeltaPayload)
    case sessionReasoningEnded(EventHeader, SessionReasoningEndedPayload)
    case sessionToolInputStarted(EventHeader, SessionToolInputStartedPayload)
    case sessionToolInputDelta(EventHeader, SessionToolInputDeltaPayload)
    case sessionToolInputEnded(EventHeader, SessionToolInputEndedPayload)
    case sessionToolCalled(EventHeader, SessionToolCalledPayload)
    case sessionToolProgress(EventHeader, SessionToolProgressPayload)
    case sessionToolSuccess(EventHeader, SessionToolSuccessPayload)
    case sessionToolFailed(EventHeader, SessionToolFailedPayload)
    case sessionRetryScheduled(EventHeader, SessionRetryScheduledPayload)
    case sessionCompactionStarted(EventHeader, SessionCompactionStartedPayload)
    case sessionCompactionDelta(EventHeader, SessionCompactionDeltaPayload)
    case sessionCompactionEnded(EventHeader, SessionCompactionEndedPayload)
    case sessionCompactionFailed(EventHeader, SessionCompactionFailedPayload)
    case sessionRevertStaged(EventHeader, SessionRevertStagedPayload)
    case sessionRevertCleared(EventHeader, SessionRevertClearedPayload)
    case sessionRevertCommitted(EventHeader, SessionRevertCommittedPayload)
    case filesystemChanged(EventHeader, FilesystemChangedPayload)
    case referenceUpdated(EventHeader, ReferenceUpdatedPayload)
    case permissionAsked(EventHeader, PermissionAskedPayload)
    case permissionReplied(EventHeader, PermissionRepliedPayload)
    case pluginUpdated(EventHeader, PluginUpdatedPayload)
    case projectUpdated(EventHeader, ProjectUpdatedPayload)
    case worktreeUpdated(EventHeader, WorktreeUpdatedPayload)
    case worktreeResolved(EventHeader, WorktreeResolvedPayload)
    case commandUpdated(EventHeader, CommandUpdatedPayload)
    case configUpdated(EventHeader, ConfigUpdatedPayload)
    case skillUpdated(EventHeader, SkillUpdatedPayload)
    case ptyCreated(EventHeader, PtyCreatedPayload)
    case ptyUpdated(EventHeader, PtyUpdatedPayload)
    case ptyExited(EventHeader, PtyExitedPayload)
    case ptyDeleted(EventHeader, PtyDeletedPayload)
    case persistentPtyAdded(EventHeader, PersistentPtyAddedPayload)
    case persistentPtyRemoved(EventHeader, PersistentPtyRemovedPayload)
    case persistentPtyUpdated(EventHeader, PersistentPtyUpdatedPayload)
    case shellCreated(EventHeader, ShellCreatedPayload)
    case shellExited(EventHeader, ShellExitedPayload)
    case shellDeleted(EventHeader, ShellDeletedPayload)
    case formCreated(EventHeader, FormCreatedPayload)
    case formReplied(EventHeader, FormRepliedPayload)
    case formCancelled(EventHeader, FormCancelledPayload)
    case websearchUpdated(EventHeader, WebsearchUpdatedPayload)
    case artifactUpdated(EventHeader, ArtifactUpdatedPayload)
    case sessionStatusUpdated(EventHeader, SessionStatusUpdatedPayload)
    case sessionIdle(EventHeader, SessionIdlePayload)
    case tuiPromptAppend(EventHeader, TuiPromptAppendPayload)
    case tuiCommandExecute(EventHeader, TuiCommandExecutePayload)
    case tuiToastShow(EventHeader, TuiToastShowPayload)
    case tuiSessionSelect(EventHeader, TuiSessionSelectPayload)
    case installationUpdated(EventHeader, InstallationUpdatedPayload)
    case installationUpdateAvailable(EventHeader, InstallationUpdateAvailablePayload)
    case vcsBranchUpdated(EventHeader, VcsBranchUpdatedPayload)
    case mcpStatusChanged(EventHeader, McpStatusChangedPayload)
    case mcpResourcesChanged(EventHeader, McpResourcesChangedPayload)
    case unknown(EventHeader, raw: JSONValue)
    case undecodable(EventHeader?, raw: JSONValue, error: String)
    public var header: EventHeader? {
        switch self {
        case .connected(let h), .rpc(let h, _), .unknown(let h, _): h
        case .undecodable(let h, _, _): h
        case .locationShutdown(let h, _): h
        case .modelsDevRefreshed(let h, _): h
        case .credentialUpdated(let h, _): h
        case .credentialSwitched(let h, _): h
        case .integrationUpdated(let h, _): h
        case .providerUpdated(let h, _): h
        case .modelUpdated(let h, _): h
        case .agentUpdated(let h, _): h
        case .sessionCreated(let h, _): h
        case .sessionAgentSelected(let h, _): h
        case .sessionModelSelected(let h, _): h
        case .sessionMoved(let h, _): h
        case .sessionRenamed(let h, _): h
        case .sessionMetadataUpdated(let h, _): h
        case .sessionPermissions(let h, _): h
        case .sessionViewed(let h, _): h
        case .sessionArchived(let h, _): h
        case .sessionUnarchived(let h, _): h
        case .sessionUsageUpdated(let h, _): h
        case .sessionDeleted(let h, _): h
        case .sessionForked(let h, _): h
        case .sessionInboxDelivered(let h, _): h
        case .sessionInboxEnqueued(let h, _): h
        case .sessionInboxCancelled(let h, _): h
        case .sessionInboxDeliveryChanged(let h, _): h
        case .sessionExecutionStarted(let h, _): h
        case .sessionExecutionSucceeded(let h, _): h
        case .sessionExecutionFailed(let h, _): h
        case .sessionExecutionInterrupted(let h, _): h
        case .sessionInstructionsUpdated(let h, _): h
        case .sessionSynthetic(let h, _): h
        case .sessionSkillActivated(let h, _): h
        case .sessionShellStarted(let h, _): h
        case .sessionShellEnded(let h, _): h
        case .sessionStepStarted(let h, _): h
        case .sessionStepStreamed(let h, _): h
        case .sessionStepEnded(let h, _): h
        case .sessionStepFailed(let h, _): h
        case .sessionTextStarted(let h, _): h
        case .sessionTextDelta(let h, _): h
        case .sessionTextEnded(let h, _): h
        case .sessionReasoningStarted(let h, _): h
        case .sessionReasoningDelta(let h, _): h
        case .sessionReasoningEnded(let h, _): h
        case .sessionToolInputStarted(let h, _): h
        case .sessionToolInputDelta(let h, _): h
        case .sessionToolInputEnded(let h, _): h
        case .sessionToolCalled(let h, _): h
        case .sessionToolProgress(let h, _): h
        case .sessionToolSuccess(let h, _): h
        case .sessionToolFailed(let h, _): h
        case .sessionRetryScheduled(let h, _): h
        case .sessionCompactionStarted(let h, _): h
        case .sessionCompactionDelta(let h, _): h
        case .sessionCompactionEnded(let h, _): h
        case .sessionCompactionFailed(let h, _): h
        case .sessionRevertStaged(let h, _): h
        case .sessionRevertCleared(let h, _): h
        case .sessionRevertCommitted(let h, _): h
        case .filesystemChanged(let h, _): h
        case .referenceUpdated(let h, _): h
        case .permissionAsked(let h, _): h
        case .permissionReplied(let h, _): h
        case .pluginUpdated(let h, _): h
        case .projectUpdated(let h, _): h
        case .worktreeUpdated(let h, _): h
        case .worktreeResolved(let h, _): h
        case .commandUpdated(let h, _): h
        case .configUpdated(let h, _): h
        case .skillUpdated(let h, _): h
        case .ptyCreated(let h, _): h
        case .ptyUpdated(let h, _): h
        case .ptyExited(let h, _): h
        case .ptyDeleted(let h, _): h
        case .persistentPtyAdded(let h, _): h
        case .persistentPtyRemoved(let h, _): h
        case .persistentPtyUpdated(let h, _): h
        case .shellCreated(let h, _): h
        case .shellExited(let h, _): h
        case .shellDeleted(let h, _): h
        case .formCreated(let h, _): h
        case .formReplied(let h, _): h
        case .formCancelled(let h, _): h
        case .websearchUpdated(let h, _): h
        case .artifactUpdated(let h, _): h
        case .sessionStatusUpdated(let h, _): h
        case .sessionIdle(let h, _): h
        case .tuiPromptAppend(let h, _): h
        case .tuiCommandExecute(let h, _): h
        case .tuiToastShow(let h, _): h
        case .tuiSessionSelect(let h, _): h
        case .installationUpdated(let h, _): h
        case .installationUpdateAvailable(let h, _): h
        case .vcsBranchUpdated(let h, _): h
        case .mcpStatusChanged(let h, _): h
        case .mcpResourcesChanged(let h, _): h
        }
    }
    public var payload: JSONValue {
        switch self {
        case .connected: .object([:])
        case .rpc(_, let raw): raw
        case .unknown(_, let raw), .undecodable(_, let raw, _): raw["data"] ?? .object([:])
        case .locationShutdown(_, let p): p.raw
        case .modelsDevRefreshed(_, let p): p.raw
        case .credentialUpdated(_, let p): p.raw
        case .credentialSwitched(_, let p): p.raw
        case .integrationUpdated(_, let p): p.raw
        case .providerUpdated(_, let p): p.raw
        case .modelUpdated(_, let p): p.raw
        case .agentUpdated(_, let p): p.raw
        case .sessionCreated(_, let p): p.raw
        case .sessionAgentSelected(_, let p): p.raw
        case .sessionModelSelected(_, let p): p.raw
        case .sessionMoved(_, let p): p.raw
        case .sessionRenamed(_, let p): p.raw
        case .sessionMetadataUpdated(_, let p): p.raw
        case .sessionPermissions(_, let p): p.raw
        case .sessionViewed(_, let p): p.raw
        case .sessionArchived(_, let p): p.raw
        case .sessionUnarchived(_, let p): p.raw
        case .sessionUsageUpdated(_, let p): p.raw
        case .sessionDeleted(_, let p): p.raw
        case .sessionForked(_, let p): p.raw
        case .sessionInboxDelivered(_, let p): p.raw
        case .sessionInboxEnqueued(_, let p): p.raw
        case .sessionInboxCancelled(_, let p): p.raw
        case .sessionInboxDeliveryChanged(_, let p): p.raw
        case .sessionExecutionStarted(_, let p): p.raw
        case .sessionExecutionSucceeded(_, let p): p.raw
        case .sessionExecutionFailed(_, let p): p.raw
        case .sessionExecutionInterrupted(_, let p): p.raw
        case .sessionInstructionsUpdated(_, let p): p.raw
        case .sessionSynthetic(_, let p): p.raw
        case .sessionSkillActivated(_, let p): p.raw
        case .sessionShellStarted(_, let p): p.raw
        case .sessionShellEnded(_, let p): p.raw
        case .sessionStepStarted(_, let p): p.raw
        case .sessionStepStreamed(_, let p): p.raw
        case .sessionStepEnded(_, let p): p.raw
        case .sessionStepFailed(_, let p): p.raw
        case .sessionTextStarted(_, let p): p.raw
        case .sessionTextDelta(_, let p): p.raw
        case .sessionTextEnded(_, let p): p.raw
        case .sessionReasoningStarted(_, let p): p.raw
        case .sessionReasoningDelta(_, let p): p.raw
        case .sessionReasoningEnded(_, let p): p.raw
        case .sessionToolInputStarted(_, let p): p.raw
        case .sessionToolInputDelta(_, let p): p.raw
        case .sessionToolInputEnded(_, let p): p.raw
        case .sessionToolCalled(_, let p): p.raw
        case .sessionToolProgress(_, let p): p.raw
        case .sessionToolSuccess(_, let p): p.raw
        case .sessionToolFailed(_, let p): p.raw
        case .sessionRetryScheduled(_, let p): p.raw
        case .sessionCompactionStarted(_, let p): p.raw
        case .sessionCompactionDelta(_, let p): p.raw
        case .sessionCompactionEnded(_, let p): p.raw
        case .sessionCompactionFailed(_, let p): p.raw
        case .sessionRevertStaged(_, let p): p.raw
        case .sessionRevertCleared(_, let p): p.raw
        case .sessionRevertCommitted(_, let p): p.raw
        case .filesystemChanged(_, let p): p.raw
        case .referenceUpdated(_, let p): p.raw
        case .permissionAsked(_, let p): p.raw
        case .permissionReplied(_, let p): p.raw
        case .pluginUpdated(_, let p): p.raw
        case .projectUpdated(_, let p): p.raw
        case .worktreeUpdated(_, let p): p.raw
        case .worktreeResolved(_, let p): p.raw
        case .commandUpdated(_, let p): p.raw
        case .configUpdated(_, let p): p.raw
        case .skillUpdated(_, let p): p.raw
        case .ptyCreated(_, let p): p.raw
        case .ptyUpdated(_, let p): p.raw
        case .ptyExited(_, let p): p.raw
        case .ptyDeleted(_, let p): p.raw
        case .persistentPtyAdded(_, let p): p.raw
        case .persistentPtyRemoved(_, let p): p.raw
        case .persistentPtyUpdated(_, let p): p.raw
        case .shellCreated(_, let p): p.raw
        case .shellExited(_, let p): p.raw
        case .shellDeleted(_, let p): p.raw
        case .formCreated(_, let p): p.raw
        case .formReplied(_, let p): p.raw
        case .formCancelled(_, let p): p.raw
        case .websearchUpdated(_, let p): p.raw
        case .artifactUpdated(_, let p): p.raw
        case .sessionStatusUpdated(_, let p): p.raw
        case .sessionIdle(_, let p): p.raw
        case .tuiPromptAppend(_, let p): p.raw
        case .tuiCommandExecute(_, let p): p.raw
        case .tuiToastShow(_, let p): p.raw
        case .tuiSessionSelect(_, let p): p.raw
        case .installationUpdated(_, let p): p.raw
        case .installationUpdateAvailable(_, let p): p.raw
        case .vcsBranchUpdated(_, let p): p.raw
        case .mcpStatusChanged(_, let p): p.raw
        case .mcpResourcesChanged(_, let p): p.raw
        }
    }
    public var raw: JSONValue {
        switch self {
        case .unknown(_, let raw), .undecodable(_, let raw, _): return raw
        default: break
        }
        guard let header else { return .null }
        var raw = (try? JSONEncoder().encode(header)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
        raw.set("data", payload)
        return raw
    }
    public var sessionID: String? { payload["sessionID"]?.stringValue ?? payload["form"]?["sessionID"]?.stringValue }
    public var sequence: Int? { header?.durable?["seq"]?.wireInt }
    public var isFallback: Bool { switch self { case .unknown, .undecodable: true; default: false } }
    public var needsImmediateDelivery: Bool {
        guard let type = header?.type else { return false }
        return ["permission.", "form.", "session.execution."].contains { type.hasPrefix($0) }
    }
    @concurrent public static func decodeBatch(_ frames: [Data]) async -> [Self] { frames.map(Self.decode) }
    public static func decode(_ data: Data) -> Self {
        let decoder = JSONDecoder()
        let raw = (try? decoder.decode(JSONValue.self, from: data)) ?? .string(String(decoding: data, as: UTF8.self))
        guard let header = try? decoder.decode(EventHeader.self, from: data) else {
            return .undecodable(nil, raw: raw, error: "Invalid event header")
        }
        if !knownTypes.contains(header.type), !header.type.hasPrefix("rpc.") {
            return .unknown(header, raw: raw)
        }
        guard let payload = raw["data"], payload.objectValue != nil else {
            return .undecodable(header, raw: raw, error: "Expected an event payload object")
        }
        if let error = validate(type: header.type, payload: payload) {
            return .undecodable(header, raw: raw, error: error)
        }
        switch header.type {
        case "server.connected": return .connected(header)
        case "location.shutdown": return .locationShutdown(header, .init(raw: payload))
        case "models-dev.refreshed": return .modelsDevRefreshed(header, .init(raw: payload))
        case "credential.updated": return .credentialUpdated(header, .init(raw: payload))
        case "credential.switched": return .credentialSwitched(header, .init(raw: payload))
        case "integration.updated": return .integrationUpdated(header, .init(raw: payload))
        case "provider.updated": return .providerUpdated(header, .init(raw: payload))
        case "model.updated": return .modelUpdated(header, .init(raw: payload))
        case "agent.updated": return .agentUpdated(header, .init(raw: payload))
        case "session.created": return .sessionCreated(header, .init(raw: payload))
        case "session.agent.selected": return .sessionAgentSelected(header, .init(raw: payload))
        case "session.model.selected": return .sessionModelSelected(header, .init(raw: payload))
        case "session.moved": return .sessionMoved(header, .init(raw: payload))
        case "session.renamed": return .sessionRenamed(header, .init(raw: payload))
        case "session.metadata.updated": return .sessionMetadataUpdated(header, .init(raw: payload))
        case "session.permissions": return .sessionPermissions(header, .init(raw: payload))
        case "session.viewed": return .sessionViewed(header, .init(raw: payload))
        case "session.archived": return .sessionArchived(header, .init(raw: payload))
        case "session.unarchived": return .sessionUnarchived(header, .init(raw: payload))
        case "session.usage.updated": return .sessionUsageUpdated(header, .init(raw: payload))
        case "session.deleted": return .sessionDeleted(header, .init(raw: payload))
        case "session.forked": return .sessionForked(header, .init(raw: payload))
        case "session.inbox.delivered": return .sessionInboxDelivered(header, .init(raw: payload))
        case "session.inbox.enqueued": return .sessionInboxEnqueued(header, .init(raw: payload))
        case "session.inbox.cancelled": return .sessionInboxCancelled(header, .init(raw: payload))
        case "session.inbox.delivery.changed": return .sessionInboxDeliveryChanged(header, .init(raw: payload))
        case "session.execution.started": return .sessionExecutionStarted(header, .init(raw: payload))
        case "session.execution.succeeded": return .sessionExecutionSucceeded(header, .init(raw: payload))
        case "session.execution.failed": return .sessionExecutionFailed(header, .init(raw: payload))
        case "session.execution.interrupted": return .sessionExecutionInterrupted(header, .init(raw: payload))
        case "session.instructions.updated": return .sessionInstructionsUpdated(header, .init(raw: payload))
        case "session.synthetic": return .sessionSynthetic(header, .init(raw: payload))
        case "session.skill.activated": return .sessionSkillActivated(header, .init(raw: payload))
        case "session.shell.started": return .sessionShellStarted(header, .init(raw: payload))
        case "session.shell.ended": return .sessionShellEnded(header, .init(raw: payload))
        case "session.step.started": return .sessionStepStarted(header, .init(raw: payload))
        case "session.step.streamed": return .sessionStepStreamed(header, .init(raw: payload))
        case "session.step.ended": return .sessionStepEnded(header, .init(raw: payload))
        case "session.step.failed": return .sessionStepFailed(header, .init(raw: payload))
        case "session.text.started": return .sessionTextStarted(header, .init(raw: payload))
        case "session.text.delta": return .sessionTextDelta(header, .init(raw: payload))
        case "session.text.ended": return .sessionTextEnded(header, .init(raw: payload))
        case "session.reasoning.started": return .sessionReasoningStarted(header, .init(raw: payload))
        case "session.reasoning.delta": return .sessionReasoningDelta(header, .init(raw: payload))
        case "session.reasoning.ended": return .sessionReasoningEnded(header, .init(raw: payload))
        case "session.tool.input.started": return .sessionToolInputStarted(header, .init(raw: payload))
        case "session.tool.input.delta": return .sessionToolInputDelta(header, .init(raw: payload))
        case "session.tool.input.ended": return .sessionToolInputEnded(header, .init(raw: payload))
        case "session.tool.called": return .sessionToolCalled(header, .init(raw: payload))
        case "session.tool.progress": return .sessionToolProgress(header, .init(raw: payload))
        case "session.tool.success": return .sessionToolSuccess(header, .init(raw: payload))
        case "session.tool.failed": return .sessionToolFailed(header, .init(raw: payload))
        case "session.retry.scheduled": return .sessionRetryScheduled(header, .init(raw: payload))
        case "session.compaction.started": return .sessionCompactionStarted(header, .init(raw: payload))
        case "session.compaction.delta": return .sessionCompactionDelta(header, .init(raw: payload))
        case "session.compaction.ended": return .sessionCompactionEnded(header, .init(raw: payload))
        case "session.compaction.failed": return .sessionCompactionFailed(header, .init(raw: payload))
        case "session.revert.staged": return .sessionRevertStaged(header, .init(raw: payload))
        case "session.revert.cleared": return .sessionRevertCleared(header, .init(raw: payload))
        case "session.revert.committed": return .sessionRevertCommitted(header, .init(raw: payload))
        case "filesystem.changed": return .filesystemChanged(header, .init(raw: payload))
        case "reference.updated": return .referenceUpdated(header, .init(raw: payload))
        case "permission.asked": return .permissionAsked(header, .init(raw: payload))
        case "permission.replied": return .permissionReplied(header, .init(raw: payload))
        case "plugin.updated": return .pluginUpdated(header, .init(raw: payload))
        case "project.updated": return .projectUpdated(header, .init(raw: payload))
        case "worktree.updated": return .worktreeUpdated(header, .init(raw: payload))
        case "worktree.resolved": return .worktreeResolved(header, .init(raw: payload))
        case "command.updated": return .commandUpdated(header, .init(raw: payload))
        case "config.updated": return .configUpdated(header, .init(raw: payload))
        case "skill.updated": return .skillUpdated(header, .init(raw: payload))
        case "pty.created": return .ptyCreated(header, .init(raw: payload))
        case "pty.updated": return .ptyUpdated(header, .init(raw: payload))
        case "pty.exited": return .ptyExited(header, .init(raw: payload))
        case "pty.deleted": return .ptyDeleted(header, .init(raw: payload))
        case "persistent-pty.added": return .persistentPtyAdded(header, .init(raw: payload))
        case "persistent-pty.removed": return .persistentPtyRemoved(header, .init(raw: payload))
        case "persistent-pty.updated": return .persistentPtyUpdated(header, .init(raw: payload))
        case "shell.created": return .shellCreated(header, .init(raw: payload))
        case "shell.exited": return .shellExited(header, .init(raw: payload))
        case "shell.deleted": return .shellDeleted(header, .init(raw: payload))
        case "form.created": return .formCreated(header, .init(raw: payload))
        case "form.replied": return .formReplied(header, .init(raw: payload))
        case "form.cancelled": return .formCancelled(header, .init(raw: payload))
        case "websearch.updated": return .websearchUpdated(header, .init(raw: payload))
        case "artifact.updated": return .artifactUpdated(header, .init(raw: payload))
        case "session.status": return .sessionStatusUpdated(header, .init(raw: payload))
        case "session.idle": return .sessionIdle(header, .init(raw: payload))
        case "tui.prompt.append": return .tuiPromptAppend(header, .init(raw: payload))
        case "tui.command.execute": return .tuiCommandExecute(header, .init(raw: payload))
        case "tui.toast.show": return .tuiToastShow(header, .init(raw: payload))
        case "tui.session.select": return .tuiSessionSelect(header, .init(raw: payload))
        case "installation.updated": return .installationUpdated(header, .init(raw: payload))
        case "installation.update-available": return .installationUpdateAvailable(header, .init(raw: payload))
        case "vcs.branch.updated": return .vcsBranchUpdated(header, .init(raw: payload))
        case "mcp.status.changed": return .mcpStatusChanged(header, .init(raw: payload))
        case "mcp.resources.changed": return .mcpResourcesChanged(header, .init(raw: payload))
        default:
            if header.type.hasPrefix("rpc.") { return .rpc(header, payload) }
            return .unknown(header, raw: raw)
        }
    }
    public static let knownTypes: Set<String> = [
        "location.shutdown",
        "models-dev.refreshed",
        "credential.updated",
        "credential.switched",
        "integration.updated",
        "provider.updated",
        "model.updated",
        "agent.updated",
        "session.created",
        "session.agent.selected",
        "session.model.selected",
        "session.moved",
        "session.renamed",
        "session.metadata.updated",
        "session.permissions",
        "session.viewed",
        "session.archived",
        "session.unarchived",
        "session.usage.updated",
        "session.deleted",
        "session.forked",
        "session.inbox.delivered",
        "session.inbox.enqueued",
        "session.inbox.cancelled",
        "session.inbox.delivery.changed",
        "session.execution.started",
        "session.execution.succeeded",
        "session.execution.failed",
        "session.execution.interrupted",
        "session.instructions.updated",
        "session.synthetic",
        "session.skill.activated",
        "session.shell.started",
        "session.shell.ended",
        "session.step.started",
        "session.step.streamed",
        "session.step.ended",
        "session.step.failed",
        "session.text.started",
        "session.text.delta",
        "session.text.ended",
        "session.reasoning.started",
        "session.reasoning.delta",
        "session.reasoning.ended",
        "session.tool.input.started",
        "session.tool.input.delta",
        "session.tool.input.ended",
        "session.tool.called",
        "session.tool.progress",
        "session.tool.success",
        "session.tool.failed",
        "session.retry.scheduled",
        "session.compaction.started",
        "session.compaction.delta",
        "session.compaction.ended",
        "session.compaction.failed",
        "session.revert.staged",
        "session.revert.cleared",
        "session.revert.committed",
        "filesystem.changed",
        "reference.updated",
        "permission.asked",
        "permission.replied",
        "plugin.updated",
        "project.updated",
        "worktree.updated",
        "worktree.resolved",
        "command.updated",
        "config.updated",
        "skill.updated",
        "pty.created",
        "pty.updated",
        "pty.exited",
        "pty.deleted",
        "persistent-pty.added",
        "persistent-pty.removed",
        "persistent-pty.updated",
        "shell.created",
        "shell.exited",
        "shell.deleted",
        "form.created",
        "form.replied",
        "form.cancelled",
        "websearch.updated",
        "artifact.updated",
        "session.status",
        "session.idle",
        "tui.prompt.append",
        "tui.command.execute",
        "tui.toast.show",
        "tui.session.select",
        "installation.updated",
        "installation.update-available",
        "vcs.branch.updated",
        "mcp.status.changed",
        "mcp.resources.changed",
        "server.connected",
    ]
    private static func validate(type: String, payload: JSONValue) -> String? {
        if knownTypes.contains(type), type.hasPrefix("session."), payload["sessionID"]?.stringValue?.isEmpty != false {
            return "Missing sessionID"
        }
        let fields: [(String, String)]
        switch type {
        case "location.shutdown": fields = []
        case "models-dev.refreshed": fields = []
        case "credential.updated": fields = []
        case "credential.switched": fields = [("integrationID", "string"), ("credentialID", "string")]
        case "integration.updated": fields = []
        case "provider.updated": fields = []
        case "model.updated": fields = []
        case "agent.updated": fields = []
        case "session.created": fields = [("sessionID", "string"), ("projectID", "string"), ("location", "model"), ("subpath", "string"), ("parentID", "string"), ("slug", "string"), ("title", "string"), ("agent", "string"), ("model", "model"), ("version", "string")]
        case "session.agent.selected": fields = [("sessionID", "string"), ("agent", "string"), ("previous", "string")]
        case "session.model.selected": fields = [("sessionID", "string"), ("model", "model"), ("previous", "model")]
        case "session.moved": fields = [("sessionID", "string"), ("location", "model"), ("projectID", "string"), ("subpath", "string")]
        case "session.renamed": fields = [("sessionID", "string"), ("title", "string")]
        case "session.metadata.updated": fields = [("sessionID", "string")]
        case "session.permissions": fields = [("sessionID", "string")]
        case "session.viewed": fields = [("sessionID", "string"), ("idle", "number")]
        case "session.archived": fields = [("sessionID", "string")]
        case "session.unarchived": fields = [("sessionID", "string")]
        case "session.usage.updated": fields = [("sessionID", "string"), ("cost", "number"), ("tokens", "model")]
        case "session.deleted": fields = [("sessionID", "string")]
        case "session.forked": fields = [("sessionID", "string"), ("parentID", "string")]
        case "session.inbox.delivered": fields = [("sessionID", "string"), ("inboxID", "string")]
        case "session.inbox.enqueued": fields = [("sessionID", "string"), ("inboxID", "string")]
        case "session.inbox.cancelled": fields = [("sessionID", "string"), ("inboxID", "string")]
        case "session.inbox.delivery.changed": fields = [("sessionID", "string"), ("inboxID", "string"), ("delivery", "string")]
        case "session.execution.started": fields = [("sessionID", "string")]
        case "session.execution.succeeded": fields = [("sessionID", "string")]
        case "session.execution.failed": fields = [("sessionID", "string"), ("error", "model")]
        case "session.execution.interrupted": fields = [("sessionID", "string"), ("reason", "string")]
        case "session.instructions.updated": fields = [("sessionID", "string"), ("text", "string")]
        case "session.synthetic": fields = [("sessionID", "string"), ("text", "string"), ("description", "string")]
        case "session.skill.activated": fields = [("sessionID", "string"), ("id", "string"), ("name", "string"), ("text", "string")]
        case "session.shell.started": fields = [("sessionID", "string"), ("shell", "model")]
        case "session.shell.ended": fields = [("sessionID", "string"), ("shell", "model")]
        case "session.step.started": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("agent", "string"), ("model", "model"), ("snapshot", "string"), ("started", "number")]
        case "session.step.streamed": fields = [("sessionID", "string"), ("assistantMessageID", "string")]
        case "session.step.ended": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("finish", "string"), ("rawFinish", "string"), ("cost", "number"), ("tokens", "model"), ("snapshot", "string")]
        case "session.step.failed": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("error", "model"), ("finish", "string"), ("rawFinish", "string"), ("cost", "number"), ("tokens", "model"), ("snapshot", "string")]
        case "session.text.started": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("ordinal", "number")]
        case "session.text.delta": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("ordinal", "number"), ("delta", "string")]
        case "session.text.ended": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("ordinal", "number"), ("text", "string")]
        case "session.reasoning.started": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("ordinal", "number")]
        case "session.reasoning.delta": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("ordinal", "number"), ("delta", "string")]
        case "session.reasoning.ended": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("ordinal", "number"), ("text", "string")]
        case "session.tool.input.started": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string"), ("name", "string")]
        case "session.tool.input.delta": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string"), ("delta", "string")]
        case "session.tool.input.ended": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string"), ("text", "string")]
        case "session.tool.called": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string"), ("executed", "bool")]
        case "session.tool.progress": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string")]
        case "session.tool.success": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string"), ("executed", "bool")]
        case "session.tool.failed": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("id", "string"), ("error", "model"), ("executed", "bool")]
        case "session.retry.scheduled": fields = [("sessionID", "string"), ("assistantMessageID", "string"), ("attempt", "number"), ("at", "number"), ("error", "model")]
        case "session.compaction.started": fields = [("sessionID", "string"), ("reason", "string"), ("recent", "string"), ("inputID", "string")]
        case "session.compaction.delta": fields = [("sessionID", "string"), ("text", "string")]
        case "session.compaction.ended": fields = [("sessionID", "string"), ("reason", "string"), ("model", "model"), ("text", "string"), ("recent", "string"), ("cost", "number"), ("tokens", "model")]
        case "session.compaction.failed": fields = [("sessionID", "string"), ("reason", "string"), ("error", "model"), ("inputID", "string"), ("cost", "number"), ("tokens", "model")]
        case "session.revert.staged": fields = [("sessionID", "string"), ("revert", "model")]
        case "session.revert.cleared": fields = [("sessionID", "string")]
        case "session.revert.committed": fields = [("sessionID", "string"), ("to", "string")]
        case "filesystem.changed": fields = [("file", "string"), ("event", "string")]
        case "reference.updated": fields = []
        case "permission.asked": fields = [("id", "string"), ("sessionID", "string"), ("action", "string"), ("message", "string")]
        case "permission.replied": fields = [("sessionID", "string"), ("requestID", "string"), ("reply", "string")]
        case "plugin.updated": fields = []
        case "project.updated": fields = [("id", "string"), ("canonical", "string"), ("vcs", "string"), ("name", "string")]
        case "worktree.updated": fields = [("projectID", "string")]
        case "worktree.resolved": fields = [("projectID", "string"), ("directory", "string"), ("previous", "string")]
        case "command.updated": fields = []
        case "config.updated": fields = []
        case "skill.updated": fields = []
        case "pty.created": fields = []
        case "pty.updated": fields = []
        case "pty.exited": fields = [("id", "string"), ("exitCode", "number")]
        case "pty.deleted": fields = [("id", "string")]
        case "persistent-pty.added": fields = [("sessionID", "string")]
        case "persistent-pty.removed": fields = [("sessionID", "string"), ("ptyID", "string")]
        case "persistent-pty.updated": fields = [("sessionID", "string"), ("terminal", "model")]
        case "shell.created": fields = [("info", "model")]
        case "shell.exited": fields = [("id", "string"), ("exit", "number"), ("status", "string")]
        case "shell.deleted": fields = [("id", "string")]
        case "form.created": fields = [("form", "model")]
        case "form.replied": fields = [("id", "string"), ("sessionID", "string")]
        case "form.cancelled": fields = [("id", "string"), ("sessionID", "string")]
        case "websearch.updated": fields = []
        case "artifact.updated": fields = []
        case "session.status": fields = [("sessionID", "string")]
        case "session.idle": fields = [("sessionID", "string")]
        case "tui.prompt.append": fields = [("text", "string")]
        case "tui.command.execute": fields = [("command", "string")]
        case "tui.toast.show": fields = [("title", "string"), ("message", "string"), ("variant", "string"), ("duration", "number")]
        case "tui.session.select": fields = [("sessionID", "string")]
        case "installation.updated": fields = [("version", "string")]
        case "installation.update-available": fields = [("version", "string")]
        case "vcs.branch.updated": fields = [("branch", "string")]
        case "mcp.status.changed": fields = [("server", "string")]
        case "mcp.resources.changed": fields = [("server", "string")]
        default: return nil
        }
        for (key, kind) in fields {
            guard let value = payload[key], !value.isNull else { continue }
            let valid: Bool
            switch kind {
            case "string": valid = value.stringValue != nil
            case "number": valid = value.wireNumber != nil
            case "bool": valid = value.boolValue != nil
            default: valid = value.objectValue != nil
            }
            if !valid { return "Invalid field: \(key)" }
        }
        return nil
    }
}
