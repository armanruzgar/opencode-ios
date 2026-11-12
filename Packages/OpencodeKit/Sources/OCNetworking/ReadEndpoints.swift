import Foundation
import OCFoundation
import OCModels

public struct DataResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    public let data: Value
}
public struct Page<Value: Decodable & Sendable>: Decodable, Sendable {
    public let entries: LossyArray<Value>
    public let cursor: Cursor
    public var data: [Value] { entries.values }
    public func nextCursor(limit: Int) -> String? {
        // Count wire entries, including undecodable rows, so tolerant decoding
        // cannot turn a full page into a false end of history.
        entries.entries.count < limit ? nil : cursor.next
    }
    public struct Cursor: Codable, Sendable, Equatable {
        public var previous: String?
        public var next: String?
        public init(previous: String? = nil, next: String? = nil) { self.previous = previous; self.next = next }
    }
    public init(data: [Value], cursor: Cursor = .init()) {
        entries = .init(entries: data.map { .value($0) }); self.cursor = cursor
    }
    private enum CodingKeys: String, CodingKey { case data, cursor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode(LossyArray<Value>.self, forKey: .data, default: .init())
        cursor = try c.decode(Cursor.self, forKey: .cursor, default: .init())
    }
}
public enum PageOrder: String, Sendable { case asc, desc }
public struct SessionFilter: Sendable {
    public var search: String?
    public var parentID: String?
    public var directory: String?
    public var project: String?
    public var subpath: String?
    /// `true` lists only archived sessions and `false` leaves them out (2.1.0 and later); `nil` lists both.
    public var archived: Bool?
    public init(search: String? = nil, parentID: String? = "null", directory: String? = nil,
                project: String? = nil, subpath: String? = nil, archived: Bool? = nil) {
        self.search = search; self.parentID = parentID; self.directory = directory; self.project = project; self.subpath = subpath
        self.archived = archived
    }
}
public enum ReadEndpoints {
    public static func sessions(filter: SessionFilter = .init(), limit: Int = 50, order: PageOrder = .desc,
                                cursor: String? = nil) -> Endpoint<Page<SessionInfo>> {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        else {
            // A cursor carries the filters of its first page.
            q += query([("order", order.rawValue), ("search", filter.search), ("parentID", filter.parentID),
                        ("directory", filter.directory), ("project", filter.project), ("subpath", filter.subpath),
                        ("archived", filter.archived.map(String.init))])
        }
        return .json(path: "/api/session", query: q)
    }
    public static let active = Endpoint<DataResponse<[String: WireObject]>>.json(path: "/api/session/active")
    public static let projects = Endpoint<[Project]>.json(path: "/api/project")
    public static func location(_ directory: String) -> Endpoint<Location> {
        .json(path: "/api/location", scope: .location(directory: directory))
    }
    public static func session(_ id: String) -> Endpoint<DataResponse<SessionInfo>> { .json(path: path(id)) }
    public static func messages(_ id: String, limit: Int = 50, order: PageOrder = .desc,
                                cursor: String? = nil, type: String? = nil) -> Endpoint<Page<SessionMessage>> {
        .json(path: path(id, "message"), query: query([("limit", String(min(200, max(1, limit)))),
              ("cursor", cursor), ("order", cursor == nil ? order.rawValue : nil), ("type", type)]))
    }
    public static func inbox(_ id: String) -> Endpoint<DataResponse<[InboxItem]>> { .json(path: path(id, "inbox")) }
    public static func permissions(_ id: String) -> Endpoint<DataResponse<[PermissionRequest]>> { .json(path: path(id, "permission")) }
    public static func permission(_ id: String, request: String) -> Endpoint<DataResponse<PermissionRequest>> {
        .json(path: path(id, "permission", request))
    }
    public static func forms(_ id: String, directory: String? = nil) -> Endpoint<DataResponse<[FormInfo]>> {
        .json(path: path(id, "form"), scope: directory.map { .location(directory: $0) } ?? .session)
    }
    public static func form(_ id: String, form: String, directory: String? = nil) -> Endpoint<DataResponse<FormInfo>> {
        .json(path: path(id, "form", form), scope: directory.map { .location(directory: $0) } ?? .session)
    }
    public static func locationPermissions(_ directory: String) -> Endpoint<Located<[PermissionRequest]>> {
        .json(path: "/api/permission/request", scope: .location(directory: directory))
    }
    public static func locationForms(_ directory: String) -> Endpoint<Located<[FormInfo]>> {
        .json(path: "/api/form", scope: .location(directory: directory))
    }
    public static func diff(_ id: String, from: String? = nil, to: String? = nil, context: Int? = nil) -> Endpoint<DataResponse<[FileDiff]>> {
        .init(path: path(id, "diff"), query: query([("from", from), ("to", to), ("context", context.map(String.init))])) { data, _ in
            let result = try JSONDecoder().decode(DataResponse<LossyArray<FileDiff>>.self, from: data)
            return DataResponse(data: result.data.values)
        }
    }
    public static func shellOutput(_ id: String, directory: String, cursor: Int? = nil, limit: Int? = nil) -> Endpoint<Located<ShellOutput>> {
        .json(path: "/api/shell/\(id)/output", query: query([("cursor", cursor.map(String.init)), ("limit", limit.map(String.init))]),
              scope: .location(directory: directory))
    }
    public static func viewed(_ id: String, idle: Double) throws -> Endpoint<Void> {
        .init(method: .post, path: path(id, "view"), body: try JSONEncoder().encode(["idle": idle])) { _, _ in () }
    }
    public static func agents(_ directory: String) -> Endpoint<Located<[AgentInfo]>> { .json(path: "/api/agent", scope: .location(directory: directory)) }
    public static func models(_ directory: String) -> Endpoint<Located<[ModelInfo]>> { .json(path: "/api/model", scope: .location(directory: directory)) }
    public static func providers(_ directory: String) -> Endpoint<Located<[ProviderInfo]>> { .json(path: "/api/provider", scope: .location(directory: directory)) }
    public static func defaultModel(_ directory: String) -> Endpoint<Located<ModelInfo?>> { .json(path: "/api/model/default", scope: .location(directory: directory)) }
    public static func mcp(_ directory: String) -> Endpoint<Located<[MCPServer]>> { .json(path: "/api/mcp", scope: .location(directory: directory)) }
    public static func catalog(_ kind: String, directory: String) -> Endpoint<Located<JSONValue>> {
        .json(path: "/api/\(kind)", scope: .location(directory: directory))
    }
    private static func path(_ id: String, _ suffix: String...) -> String { (["", "api", "session", id] + suffix).joined(separator: "/") }
    private static func query(_ pairs: [(String, String?)]) -> [URLQueryItem] { pairs.compactMap { key, value in value.map { .init(name: key, value: $0) } } }
}
