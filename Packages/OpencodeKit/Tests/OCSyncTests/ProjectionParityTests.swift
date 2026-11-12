import Foundation
import Testing
import OCFoundation
import OCModels
import OCNetworking
@testable import OCSync

enum ProjectionFixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "Fixtures/v2")
    }()
    static var snapshots: [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "snapshots" }.sorted { $0.path < $1.path }
    }
    static func events(_ url: URL) throws -> [ServerEvent] {
        let version = url.deletingLastPathComponent().deletingLastPathComponent()
        let sse = version.appending(path: "sse/\(url.deletingPathExtension().lastPathComponent).sse")
        guard FileManager.default.fileExists(atPath: sse.path) else { return [] }
        return try String(contentsOf: sse, encoding: .utf8).components(separatedBy: "\n\n").compactMap { frame in
            let data = frame.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            return data.isEmpty ? nil : ServerEvent.decode(Data(data.utf8))
        }
    }
}

@Test @MainActor func projectionFixturesExist() {
    #expect(ProjectionFixtures.snapshots.count >= 20)
}
@Test(arguments: ProjectionFixtures.snapshots)
@MainActor func projectionParity(file: URL) throws {
    let raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    let snapshots = raw.arrayValue ?? []
    let events = try ProjectionFixtures.events(file)
    for event in events { #expect(!event.isFallback, "\(file.lastPathComponent): \(event.header?.type ?? "invalid")") }
    guard let start = snapshots.first, let end = snapshots.last else {
        #expect(["pairing", "pty", "v1-probe"].contains(file.deletingPathExtension().lastPathComponent)); return
    }
    let store = ReadStore(serverID: "fixture")
    // Project what the recording's server reports, as ServerStore does after its probe (2.2.2 adds `time.busy`).
    let server = file.deletingLastPathComponent().deletingLastPathComponent().appending(path: "info.json")
    store.projectsBusyTime = try JSONDecoder().decode(ServerInfo.self, from: Data(contentsOf: server)).reportsBusyTime
    let info = try #require(start["session"]).decoded(SessionInfo.self)
    let messages = try #require(start["messages"]).decoded([SessionMessage].self)
    store.seed(info: info, messages: messages,
               pending: try #require(start["inbox"]).decoded([InboxItem].self),
               permissions: try #require(start["permissions"]).decoded([PermissionRequest].self),
               forms: try #require(start["forms"]).decoded([FormInfo].self))
    let from = try #require(start["eventOffset"]?.wireInt), to = try #require(end["eventOffset"]?.wireInt)
    for event in events[from..<to] { store.apply(event); store.apply(event) }
    let session = try #require(store.sessions[info.id]), actual = try #require(session.transcript).snapshot
    let expected = try #require(end["messages"]).decoded([SessionMessage].self)
    #expect(actual.map(\.id) == expected.map(\.id), "\(file.lastPathComponent): row ordering")
    for row in expected {
        let match = actual.first { $0.id == row.id }
        let detail = "\(file.lastPathComponent) \(row.type): expected \(try row.raw.prettyPrinted()); actual \(try match?.raw.prettyPrinted() ?? "missing")"
        #expect(match?.raw.omittingNullFields == row.raw.omittingNullFields, "\(detail)")
    }
    let detail = "\(file.lastPathComponent) session: \(try session.info.raw.prettyPrinted()) expected \(try end["session"]?.prettyPrinted() ?? "missing")"
    #expect(session.info.raw.omittingNullFields == end["session"]?.omittingNullFields, "\(detail)")
    #expect(session.pending.map(\.raw) == end["inbox"]?.arrayValue)
    #expect(store.permissions[info.id]?.map(\.raw) == end["permissions"]?.arrayValue)
    #expect(store.forms[.session(info.id)]?.map(\.raw) == end["forms"]?.arrayValue)
    #expect(!session.status.isRunning)
}
