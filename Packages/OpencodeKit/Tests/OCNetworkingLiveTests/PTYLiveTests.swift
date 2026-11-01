import Foundation
import Testing
import OCFoundation
import OCModels
import OCNetworking

private let environment = ProcessInfo.processInfo.environment
private let liveEnabled = ["OPENCODE_LIVE_URL", "OPENCODE_LIVE_PASSWORD", "OPENCODE_LIVE_DIRECTORY"].allSatisfy { environment[$0] != nil }

/// The app's socket client against the sandbox: URLSessionWebSocketTask with the Basic header on the upgrade, frames,
/// the UTF-16 cursor across a reconnection, a stale cursor's gap, and how URLSession reports the server's close codes and a
/// missing PTY. Part of the serialized suite, so it never overlaps the test that stops the server for a minute.
extension LiveContracts {
@Test(.enabled(if: liveEnabled, "Requires sandbox environment supplied by Tools/contract"), .timeLimit(.minutes(2)))
func ptySocketAgainstTheSandbox() async throws {
    let base = try #require(environment["OPENCODE_LIVE_URL"]), password = try #require(environment["OPENCODE_LIVE_PASSWORD"])
    let url = try #require(URL(string: base))
    let directory = try #require(environment["OPENCODE_LIVE_DIRECTORY"])
    let api = APIClient(baseURL: url, credential: .password(password))
    let sockets = URLSessionWebSockets()
    let pty = try await api.send(TerminalEndpoints.create(directory, command: "/bin/bash", title: "Live socket")).data
    func open(_ cursor: Int) throws -> any WebSocketConnection {
        sockets.open(try api.webSocketRequest(path: "/api/pty/\(pty.id)/connect", query: [.init(name: "cursor", value: String(cursor))], scope: .location(directory: directory)))
    }
    /// Events until `stop` says enough, with the cursor counted the app's way.
    func read(_ socket: any WebSocketConnection, start: Int?, until stop: (String, Int?) -> Bool) async -> (text: String, cursor: Int?, events: [PTYEvent]) {
        var text = "", cursor = start, events: [PTYEvent] = []
        for await event in socket.events {
            events.append(event)
            switch event {
            case .frame(.control(let value)): cursor = value
            case .frame(.output(let output)): text += output; cursor = cursor.map { $0 + output.utf16.count }
            default: break
            }
            if stop(text, cursor) { break }
            if case .closed = event { break }
        }
        return (text, cursor, events)
    }
    let first = try open(0)
    let opened = await read(first, start: nil) { _, cursor in cursor != nil }
    #expect(opened.events.first == .opened, "The Basic header authenticates the upgrade")
    try await first.send("printf '\\360\\237\\230\\200\\346\\274\\242-live\\n'\n")
    _ = await read(first, start: nil) { text, _ in text.contains("😀漢-live") }
    try await Task.sleep(for: .milliseconds(300))
    first.close()
    // The resumed connection's control frame lands exactly where the app's count says it should.
    let tail = try open(-1)
    let end = await read(tail, start: nil) { _, cursor in cursor != nil }.cursor
    tail.close()
    let resumed = try open(try #require(end))
    let replay = await read(resumed, start: nil) { _, cursor in cursor != nil }
    #expect(replay.cursor == end && replay.text.isEmpty)
    // A saved cursor the 2 MiB buffer no longer reaches, through the app's socket and reducer: the server replays what
    // it kept, and the gap is what its control frame says is missing. printf keeps the marker out of the echoed line.
    try await resumed.send("head -c 3000000 /dev/zero | tr '\\0' a; echo; printf 'buffer-%s\\n' done\n")
    _ = await read(resumed, start: end) { text, _ in text.suffix(256).contains("buffer-done") }
    resumed.close()
    let saved = try #require(end)
    var link = TerminalLink(), effects: [TerminalLink.Effect] = []
    #expect(link.start(cursor: saved, restoredScreen: true) == [.connect(seek: saved)])
    let stale = try open(saved)
    reading: for await event in stale.events {
        switch event {
        case .opened: effects += link.opened()
        case .frame(.output(let text)): effects += link.text(text)
        case .frame(.control(let cursor)): effects += link.control(cursor: cursor); break reading
        case .frame(.ignored): break
        case .closed: break reading
        }
    }
    stale.close()
    let current = try #require(link.cursor)
    #expect(current - saved > 3_000_000, "The control frame counts every byte written")
    guard effects.count == 5, effects[0] == .pushSize, effects[1] == .reset, case .replay(let kept) = effects[2] else {
        Issue.record("Unexpected effects for a stale cursor: \(effects.count)"); return
    }
    #expect(kept.utf16.count == 2_097_152, "The server keeps 2,097,152 UTF-16 code units")
    #expect(Array(effects[3...]) == [.gap(.lost(units: current - saved - 2_097_152)), .persist])
    // Exit: the open socket closes normally, and a new one gets 4404, as URLSession reports it.
    let exiting = try open(-1)
    _ = await read(exiting, start: nil) { _, cursor in cursor != nil }
    try await exiting.send("exit 3\n")
    let exited = await read(exiting, start: nil) { _, _ in false }
    guard case .closed(let code, _, _)? = exited.events.last else { Issue.record("No close"); return }
    #expect(code == 1000)
    let late = try open(0)
    let refused = await read(late, start: nil) { _, _ in false }
    guard case .closed(let lateCode, let reason, _)? = refused.events.last else { Issue.record("No close"); return }
    #expect(lateCode == 4404 && reason == "session exited")
    let missing = sockets.open(try api.webSocketRequest(path: "/api/pty/pty_missing/connect", query: [], scope: .location(directory: directory)))
    let unknown = await read(missing, start: nil) { _, _ in false }
    guard case .closed(_, _, let status)? = unknown.events.last else { Issue.record("No close"); return }
    #expect(status == 404)
    _ = try? await api.send(TerminalEndpoints.delete(pty.id, directory: directory))
    print("PASS PTY socket: Basic upgrade, UTF-16 resume at \(end ?? -1), stale resume losing \(current - saved - 2_097_152), close 1000, close \(lateCode ?? -1) \(reason ?? ""), unknown PTY \(status ?? -1)")
}
}
