import Foundation
import OCFoundation

public struct ServerInfo: Codable, Equatable, Sendable {
    public var version: String
    public var pid: Int?
    public var urls: [URL]
    public var paths: [String: String]
    public var capabilities: Capabilities

    public struct Capabilities: Codable, Equatable, Sendable {
        public var persistentPty: Bool?
        public init(persistentPty: Bool? = nil) { self.persistentPty = persistentPty }
    }

    public init(version: String, pid: Int? = nil, urls: [URL] = [], paths: [String: String] = [:],
                capabilities: Capabilities = .init()) {
        self.version = version
        self.pid = pid
        self.urls = urls
        self.paths = paths
        self.capabilities = capabilities
    }

    /// The oldest opencode server the app accepts: 2.0.25 added pairing, which the app relies on. Older 2.x servers
    /// get the update screen, which names this version.
    public static let minimumVersion = "2.0.25"
    public var supportsPairing: Bool { isAtLeast(Self.minimumVersion) }
    /// Session info carries `time.busy`, the start of the latest turn, from 2.2.2 on.
    public var reportsBusyTime: Bool { isAtLeast("2.2.2") }
    /// `GET /api/session` takes `archived=true|false` from 2.1.0 on; older servers ignore it and list both.
    public var filtersArchivedSessions: Bool { isAtLeast("2.1.0") }
    public var isSupported: Bool { isAtLeast(Self.minimumVersion) && SemVer(version)?.major == 2 }
    private func isAtLeast(_ minimum: String) -> Bool {
        guard let version = SemVer(version), let minimum = SemVer(minimum) else { return false }
        return version >= minimum
    }

    private enum CodingKeys: String, CodingKey { case version, pid, urls, paths, capabilities }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version, default: "unknown")
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        let raw = try c.decode([JSONValue].self, forKey: .urls, default: [])
        urls = raw.compactMap { value in
            guard case .string(let text) = value, let url = URL(string: text), url.host != nil,
                  ["http", "https"].contains(url.scheme) else { return nil }
            return url
        }
        paths = try c.decode([String: JSONValue].self, forKey: .paths, default: [:]).compactMapValues {
            if case .string(let text) = $0 { text } else { nil }
        }
        capabilities = try c.decode(Capabilities.self, forKey: .capabilities, default: .init())
    }
}

public enum ServerGeneration: String, Sendable, Equatable { case v1, v2, unknown }

public enum ProbeOutcome: Sendable, Equatable {
    case v2(ServerInfo)
    case unsupportedV2(ServerInfo)
    case v2Starting(retryAfter: Duration)
    case unauthorized(ServerGeneration)
    case v1(String)
    case notOpencode
    case failure(ConnectionFailure)
}
