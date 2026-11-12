import OCFoundation

// Payload fields follow V2Event in the reference client at d0732ea.
public struct LocationShutdownPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct ModelsDevRefreshedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct CredentialUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct CredentialSwitchedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `integrationID`: String { string("integrationID") }
    public var `credentialID`: String? { self["credentialID"]?.stringValue }
}
public struct IntegrationUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct ProviderUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct ModelUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct AgentUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct SessionCreatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `projectID`: String { string("projectID") }
    public var `location`: Location { object("location") }
    public var `subpath`: String? { self["subpath"]?.stringValue }
    public var `parentID`: String? { self["parentID"]?.stringValue }
    public var `slug`: String { string("slug") }
    public var `title`: String? { self["title"]?.stringValue }
    public var `agent`: String? { self["agent"]?.stringValue }
    public var `model`: ModelRef? { optional("model") }
    public var `metadata`: JSONValue? { self["metadata"] }
    public var `permissions`: [PermissionRule]? { self["permissions"]?.lossy(PermissionRule.self).values }
    public var `version`: String { string("version") }
}
public struct SessionAgentSelectedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `agent`: String { string("agent") }
    public var `previous`: String? { self["previous"]?.stringValue }
}
public struct SessionModelSelectedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `model`: ModelRef { object("model") }
    public var `previous`: ModelRef? { optional("previous") }
}
public struct SessionMovedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `location`: Location { object("location") }
    public var `projectID`: String { string("projectID") }
    public var `subpath`: String? { self["subpath"]?.stringValue }
}
public struct SessionRenamedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `title`: String { string("title") }
}
public struct SessionMetadataUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `metadata`: JSONValue { self["metadata"] ?? .object([:]) }
}
public struct SessionPermissionsPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `permissions`: [PermissionRule] { self["permissions"]?.lossy(PermissionRule.self).values ?? [] }
}
public struct SessionViewedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `idle`: Double { number("idle") }
}
/// Since 2.1.0. The event's `created` time is the session's new `time.archived`.
public struct SessionArchivedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
/// Since 2.1.0. Clears the session's `time.archived`.
public struct SessionUnarchivedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct SessionUsageUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `cost`: Double { number("cost") }
    public var `tokens`: TokenUsage { object("tokens") }
}
public struct SessionDeletedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct SessionForkedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `parentID`: String { string("parentID") }
    public var `boundary`: JSONValue { self["boundary"] ?? .object([:]) }
    public var `instructions`: JSONValue? { self["instructions"] }
    public var `instructionEntries`: JSONValue? { self["instructionEntries"] }
}
public struct SessionInboxDeliveredPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `inboxID`: String { string("inboxID") }
}
public struct SessionInboxEnqueuedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `inboxID`: String { string("inboxID") }
    public var `item`: InboxItem { .init(raw: self["item"] ?? .object([:])) }
}
public struct SessionInboxCancelledPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `inboxID`: String { string("inboxID") }
}
public struct SessionInboxDeliveryChangedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `inboxID`: String { string("inboxID") }
    public var `delivery`: String { string("delivery") }
}
public struct SessionExecutionStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct SessionExecutionSucceededPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct SessionExecutionFailedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `error`: StructuredError { object("error") }
}
public struct SessionExecutionInterruptedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `reason`: String { string("reason") }
}
public struct SessionInstructionsUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `delta`: JSONValue { self["delta"] ?? .object([:]) }
    public var `text`: String? { self["text"]?.stringValue }
}
public struct SessionSyntheticPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `text`: String { string("text") }
    public var `description`: String? { self["description"]?.stringValue }
    public var `metadata`: JSONValue? { self["metadata"] }
}
public struct SessionSkillActivatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `id`: String { string("id") }
    public var `name`: String { string("name") }
    public var `text`: String { string("text") }
}
public struct SessionShellStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `shell`: ShellInfo { object("shell") }
}
public struct SessionShellEndedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `shell`: ShellInfo { object("shell") }
    public var `output`: ShellOutput { object("output") }
}
public struct SessionStepStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `agent`: String { string("agent") }
    public var `model`: ModelRef { object("model") }
    public var `snapshot`: String? { self["snapshot"]?.stringValue }
    public var `started`: Double { number("started") }
}
public struct SessionStepStreamedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
}
public struct SessionStepEndedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `finish`: String { string("finish") }
    public var `rawFinish`: String? { self["rawFinish"]?.stringValue }
    public var `providerState`: JSONValue? { self["providerState"] }
    public var `cost`: Double { number("cost") }
    public var `tokens`: TokenUsage { object("tokens") }
    public var `snapshot`: String? { self["snapshot"]?.stringValue }
    public var `files`: [String]? { self["files"]?.arrayValue?.compactMap(\.stringValue) }
}
public struct SessionStepFailedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `error`: StructuredError { object("error") }
    public var `finish`: String? { self["finish"]?.stringValue }
    public var `rawFinish`: String? { self["rawFinish"]?.stringValue }
    public var `providerState`: JSONValue? { self["providerState"] }
    public var `cost`: Double? { self["cost"]?.wireNumber }
    public var `tokens`: TokenUsage? { optional("tokens") }
    public var `snapshot`: String? { self["snapshot"]?.stringValue }
    public var `files`: [String]? { self["files"]?.arrayValue?.compactMap(\.stringValue) }
}
public struct SessionTextStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `ordinal`: Double { number("ordinal") }
}
public struct SessionTextDeltaPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `ordinal`: Double { number("ordinal") }
    public var `delta`: String { string("delta") }
}
public struct SessionTextEndedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `ordinal`: Double { number("ordinal") }
    public var `text`: String { string("text") }
    public var `state`: JSONValue? { self["state"] }
}
public struct SessionReasoningStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `ordinal`: Double { number("ordinal") }
    public var `state`: JSONValue? { self["state"] }
    public var native: JSONValue? { self["native"] }
}
public struct SessionReasoningDeltaPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `ordinal`: Double { number("ordinal") }
    public var `delta`: String { string("delta") }
}
public struct SessionReasoningEndedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `ordinal`: Double { number("ordinal") }
    public var `text`: String { string("text") }
    public var `state`: JSONValue? { self["state"] }
    public var native: JSONValue? { self["native"] }
}
public struct SessionToolInputStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `name`: String { string("name") }
}
public struct SessionToolInputDeltaPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `delta`: String { string("delta") }
}
public struct SessionToolInputEndedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `text`: String { string("text") }
}
public struct SessionToolCalledPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `input`: JSONValue { self["input"] ?? .object([:]) }
    public var `executed`: Bool { self["executed"]?.boolValue ?? false }
    public var `state`: JSONValue? { self["state"] }
}
public struct SessionToolProgressPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `metadata`: JSONValue { self["metadata"] ?? .object([:]) }
}
public struct SessionToolSuccessPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `content`: [ToolContent] { self["content"]?.lossy(ToolContent.self).values ?? [] }
    public var `metadata`: JSONValue? { self["metadata"] }
    public var `executed`: Bool { self["executed"]?.boolValue ?? false }
    public var `resultState`: JSONValue? { self["resultState"] }
}
public struct SessionToolFailedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `id`: String { string("id") }
    public var `error`: StructuredError { object("error") }
    public var `content`: [ToolContent]? { self["content"]?.lossy(ToolContent.self).values }
    public var `metadata`: JSONValue? { self["metadata"] }
    public var `executed`: Bool { self["executed"]?.boolValue ?? false }
    public var `resultState`: JSONValue? { self["resultState"] }
}
public struct SessionRetryScheduledPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `assistantMessageID`: String { string("assistantMessageID") }
    public var `attempt`: Double { number("attempt") }
    public var `at`: Double { number("at") }
    public var `error`: StructuredError { object("error") }
}
public struct SessionCompactionStartedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `reason`: String { string("reason") }
    public var `recent`: String { string("recent") }
    public var `inputID`: String? { self["inputID"]?.stringValue }
}
public struct SessionCompactionDeltaPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `text`: String { string("text") }
}
public struct SessionCompactionEndedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `reason`: String { string("reason") }
    public var `model`: ModelRef? { optional("model") }
    public var `providerState`: JSONValue? { self["providerState"] }
    public var `providerContext`: JSONValue? { self["providerContext"] }
    public var `text`: String { string("text") }
    public var `recent`: String { string("recent") }
    public var `cost`: Double? { self["cost"]?.wireNumber }
    public var `tokens`: TokenUsage? { optional("tokens") }
}
public struct SessionCompactionFailedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `reason`: String { string("reason") }
    public var `error`: StructuredError { object("error") }
    public var `inputID`: String? { self["inputID"]?.stringValue }
    public var `cost`: Double? { self["cost"]?.wireNumber }
    public var `tokens`: TokenUsage? { optional("tokens") }
}
public struct SessionRevertStagedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `revert`: SessionRevert { object("revert") }
}
public struct SessionRevertClearedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct SessionRevertCommittedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `to`: String { string("to") }
}
public struct FilesystemChangedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `file`: String { string("file") }
    public var `event`: String { string("event") }
}
public struct ReferenceUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct PermissionAskedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
    public var `sessionID`: String { string("sessionID") }
    public var `action`: String { string("action") }
    public var `resources`: [String] { strings("resources") }
    public var `save`: [String]? { self["save"]?.arrayValue?.compactMap(\.stringValue) }
    public var `metadata`: JSONValue? { self["metadata"] }
    public var `source`: JSONValue? { self["source"] }
    public var `message`: String? { self["message"]?.stringValue }
}
public struct PermissionRepliedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `requestID`: String { string("requestID") }
    public var `reply`: String { string("reply") }
}
public struct PluginUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct ProjectUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
    public var `canonical`: String { string("canonical") }
    public var `vcs`: String? { self["vcs"]?.stringValue }
    public var `name`: String? { self["name"]?.stringValue }
    public var `icon`: JSONValue? { self["icon"] }
    public var `commands`: JSONValue? { self["commands"] }
    public var `time`: JSONValue { self["time"] ?? .object([:]) }
    public var `sandboxes`: [String] { strings("sandboxes") }
}
public struct WorktreeUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `projectID`: String { string("projectID") }
}
public struct WorktreeResolvedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `projectID`: String { string("projectID") }
    public var `directory`: String { string("directory") }
    public var `previous`: String { string("previous") }
    public var `adopted`: [String]? { self["adopted"]?.arrayValue?.compactMap(\.stringValue) }
}
public struct CommandUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct ConfigUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct SkillUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct PtyCreatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `info`: JSONValue { self["info"] ?? .object([:]) }
}
public struct PtyUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `info`: JSONValue { self["info"] ?? .object([:]) }
}
public struct PtyExitedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
    public var `exitCode`: Double { number("exitCode") }
}
public struct PtyDeletedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
}
public struct PersistentPtyAddedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `terminal`: JSONValue { self["terminal"] ?? .object([:]) }
}
public struct PersistentPtyRemovedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `ptyID`: String { string("ptyID") }
}
/// Since 2.2.4: a session terminal was renamed or changed.
public struct PersistentPtyUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `terminal`: JSONValue { self["terminal"] ?? .object([:]) }
}
public struct ShellCreatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `info`: ShellInfo { object("info") }
}
public struct ShellExitedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
    public var `exit`: Double? { self["exit"]?.wireNumber }
    public var `status`: String { string("status") }
}
public struct ShellDeletedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
}
public struct FormCreatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `form`: FormInfo { object("form") }
}
public struct FormRepliedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
    public var `sessionID`: String { string("sessionID") }
    public var `answer`: JSONValue { self["answer"] ?? .object([:]) }
}
public struct FormCancelledPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `id`: String { string("id") }
    public var `sessionID`: String { string("sessionID") }
}
public struct WebsearchUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
/// Since 2.2.4, for the experimental artifacts the app does not show.
public struct ArtifactUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
}
public struct SessionStatusUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
    public var `status`: JSONValue { self["status"] ?? .object([:]) }
}
public struct SessionIdlePayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct TuiPromptAppendPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `text`: String { string("text") }
}
public struct TuiCommandExecutePayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `command`: String { string("command") }
}
public struct TuiToastShowPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `title`: String? { self["title"]?.stringValue }
    public var `message`: String { string("message") }
    public var `variant`: String { string("variant") }
    public var `duration`: Double? { self["duration"]?.wireNumber }
}
public struct TuiSessionSelectPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `sessionID`: String { string("sessionID") }
}
public struct InstallationUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `version`: String { string("version") }
}
public struct InstallationUpdateAvailablePayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `version`: String { string("version") }
}
public struct VcsBranchUpdatedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `branch`: String? { self["branch"]?.stringValue }
}
public struct McpStatusChangedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `server`: String { string("server") }
}
public struct McpResourcesChangedPayload: WireValue {
    public var raw: JSONValue
    public init(raw: JSONValue) { self.raw = raw }
    public var `server`: String { string("server") }
}
