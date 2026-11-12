import Foundation
import Testing
import OCModels
import OCFoundation
@testable import OCRender

enum TimelineFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var files: [URL] {
        let enumerator = FileManager.default.enumerator(at: root.appending(path: "Fixtures/v2"), includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "snapshots" }.sorted { $0.path < $1.path }
    }
    static let expected: [String: [TimelineRow.Kind]] = [
        "compaction": [.userPrompt, .assistantText, .toolGroup],
        "final-error": [.userPrompt, .error],
        "fork": [.userPrompt, .assistantText],
        "interrupt-resume": [.userPrompt, .assistantText, .notice, .userPrompt, .assistantText],
        "interrupt": [.userPrompt, .assistantText, .notice],
        "pairing": [], "pty": [], "v1-probe": [],
        "permission-allow": [.userPrompt, .toolGroup, .assistantText, .turnEnd],
        "permission-reject": [.userPrompt, .toolGroup, .tool, .assistantText],
        "plain-text": [.userPrompt, .assistantText],
        "question-form": [.userPrompt, .toolGroup, .assistantText],
        "read-glob-grep": [.userPrompt, .toolGroup, .assistantText],
        "reasoning-text": [.userPrompt, .toolGroup, .assistantText],
        "retry-429": [.userPrompt, .assistantText],
        "retry-500": [.userPrompt, .assistantText],
        "revert": [.userPrompt, .assistantText],
        "shell-output": [.userPrompt, .toolGroup, .assistantText],
        "steer-queue": [.userPrompt, .assistantText, .userPrompt, .assistantText, .userPrompt, .assistantText],
        "subagent": [.userPrompt, .toolGroup, .assistantText],
    ]
}
@Test func recordedScenariosAreCovered() {
    // Every recorded release has the same 20 scenarios.
    let releases = Dictionary(grouping: TimelineFixtures.files) { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
    #expect(!releases.isEmpty)
    for (release, files) in releases {
        #expect(files.count == 20, "\(release)")
        #expect(Set(files.map { $0.deletingPathExtension().lastPathComponent }) == Set(TimelineFixtures.expected.keys), "\(release)")
    }
}
@Test(arguments: TimelineFixtures.files) func recordedTimeline(file: URL) async throws {
    let snapshots = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)).arrayValue ?? []
    let rows = try snapshots.last?["messages"]?.decoded([SessionMessage].self) ?? []
    let result = await TimelineRowBuilder().build(rows)
    #expect(result.map(\.kind) == TimelineFixtures.expected[file.deletingPathExtension().lastPathComponent])
}
func message(_ id: String, _ type: String, _ fields: [String: JSONValue] = [:]) -> SessionMessage {
    .init(raw: .object(fields.merging(["id": .string(id), "type": .string(type)], uniquingKeysWith: { _, new in new })))
}
func tool(_ name: String, status: String = "completed", input: JSONValue = .object([:]), metadata: JSONValue = .object([:])) -> JSONValue {
    .object(["type": .string("tool"), "id": .string(name), "name": .string(name), "state": .object(["status": .string(status), "input": input, "metadata": metadata])])
}
@Test func frozenTurnsOnlyRebuildOnCorrectionsOrPresetChanges() async {
    let builder = TimelineRowBuilder()
    let frozen = [message("u", "user", ["text": .string("Voice delegation. Check the build")]), message("a", "assistant", ["content": .array([.object(["type": .string("text"), "text": .string("Done")])])]), message("i", "idle")]
    let first = await builder.build(frozen)
    #expect(first.first?.badge == "Voice")
    _ = await builder.build(frozen + [message("open", "user")])
    #expect(await builder.rebuiltTurns == 2)
    var corrected = frozen; corrected[0] = message("u", "user", ["text": .string("Corrected")])
    let result = await builder.build(corrected)
    #expect(result.first?.text == "Corrected")
    #expect(await builder.rebuiltTurns == 3)
    _ = await builder.build(corrected, detail: .everything)
    #expect(await builder.rebuiltTurns == 4)
}
@Test func presetsPreserveRequiredErrorsAndStablePartIdentity() async {
    let content: [JSONValue] = [.object(["type": .string("reasoning"), "text": .string("Thinking")]), tool("read"), tool("edit"), tool("shell"), tool("subagent")]
    let rows = [message("u", "user"), message("a", "assistant", ["content": .array(content)]), message("i", "idle")]
    let builder = TimelineRowBuilder()
    let everything = await builder.build(rows, detail: .everything)
    #expect(everything.map(\.kind) == [.userPrompt, .reasoning, .tool, .tool, .shell, .subagent, .turnEnd])
    let detailed = await builder.build(rows, detail: .detailed)
    #expect(detailed.map(\.kind) == [.userPrompt, .toolGroup, .tool, .shell, .subagent, .turnEnd])
    let quiet = await builder.build(rows, detail: .quiet)
    #expect(quiet[1].children.map(\.kind) == [.tool, .subagent])
    let text = await builder.build(rows, detail: .messagesOnly)
    #expect(text.map(\.kind) == [.userPrompt, .turnEnd])
    let error = [message("a", "assistant", ["content": .array([tool("shell", metadata: .object(["exit": .integer(1)]))])])]
    #expect(await builder.build(error, detail: .messagesOnly).map(\.kind) == [.shell])
    let truncated = await builder.build(Array(rows.dropFirst()), detail: .everything)
    #expect(truncated.first?.id == everything[1].id)
}
@Test func pendingQuestionAndChangedFiles() async {
    let rows = [message("a", "assistant", ["content": .array([tool("question", status: "running")]), "snapshot": .object(["files": .array([.string("a.swift"), .string("a.swift")])]), "retry": .object(["attempt": .integer(2), "error": .object(["message": .string("Busy")])])]), message("i", "idle")]
    let pending = TimelineRow(id: "request", kind: .pendingInput, text: "Choose a color")
    let result = await TimelineRowBuilder().build(rows, pending: [pending])
    #expect(result.map(\.kind) == [.retry, .turnEnd, .pendingInput])
    #expect(result[1].files == ["a.swift"])
}

@Test func idleErrorIsVisibleWhenItsAssistantIsOutsideThePage() async {
    let error: JSONValue = .object(["message": .string("Provider unavailable")])
    let idle = message("idle", "idle", ["error": error, "outcome": .string("failed")])
    let builder = TimelineRowBuilder()
    #expect(await builder.build([idle], detail: .messagesOnly).map(\.kind) == [.error, .turnEnd])
    let assistant = message("a", "assistant", ["error": error])
    #expect(await builder.build([assistant, idle]).map(\.kind) == [.error])
}

@Test(arguments: ["aborted", "ABORT", "ExecutionInterrupted", "compaction.interrupted"])
func interruptedStepsAreNeutralAtEveryDetailLevel(type: String) async {
    let error: JSONValue = .object(["type": .string(type), "message": .string("Step interrupted")])
    for detail in TimelineDetail.allCases {
        let rows = await TimelineRowBuilder().build([
            message("a", "assistant", ["error": error]),
            message("i", "idle", ["error": error, "outcome": .string("interrupted")])
        ], detail: detail)
        #expect(!rows.contains { $0.kind == .error })
        #expect(rows.filter { $0.kind == .notice }.map(\.text) == ["Interrupted"])
    }
}
@Test func interruptedIdleOutsideThePageIsNeutral() async {
    let rows = await TimelineRowBuilder().build([message("i", "idle", [
        "error": .object(["message": .string("Stopped")]), "outcome": .string("interrupted")
    ])])
    #expect(rows.map(\.kind) == [.notice])
    #expect(rows.first?.text == "Interrupted")
}
