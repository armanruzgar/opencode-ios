import Foundation
import OCModels

public struct HomeSection: Identifiable {
    public let title: String
    public let items: [SessionSummary]
    public var id: String { title }
}

/// Home's lists: "Needs you" and "Running" from every server, then the filtered sessions by day. ⌘1–9, the session
/// commands and the switcher follow this same order.
public enum HomeOrdering {
    /// Root sessions that are not archived, pinned first, then by latest activity.
    public static func all(_ servers: [ServerStore], hidden: Bool = false, search: String = "") -> [SessionSummary] {
        var values: [SessionSummary] = []
        for server in servers {
            for session in server.sessions.values where session.info.parentID == nil && session.info.time.archived == nil {
                let item = SessionSummary(server: server, session: session)
                guard hidden == item.meta.hidden else { continue }
                let title = session.info.title ?? localized("Untitled session")
                guard search.isEmpty || title.localizedCaseInsensitiveContains(search) else { continue }
                values.append(item)
            }
        }
        values.sort { a, b in
            if a.meta.pinned != b.meta.pinned { return a.meta.pinned }
            if a.activity != b.activity { return a.activity > b.activity }
            return a.id < b.id
        }
        return values
    }
    public static func sections(_ servers: [ServerStore], server: ServerID?, project: String?, hidden: Bool = false, search: String = "") -> [HomeSection] {
        let all = all(servers, hidden: hidden, search: search)
        let recent = all.filter { item in
            !item.needsYou && item.runningCount == 0 && (server == nil || server == item.server.id) &&
                (project == nil || project == item.server.id.rawValue.uuidString + ":" + item.session.info.projectID)
        }
        let date = { (item: SessionSummary) in Date(timeIntervalSince1970: item.activity / 1_000) }
        let days = Set(recent.map { Calendar.current.startOfDay(for: date($0)) }).sorted(by: >)
        return [HomeSection(title: localized("Needs you", comment: "Home section: sessions waiting for the user"), items: all.filter(\.needsYou)),
                HomeSection(title: localized("Running", comment: "Home section: sessions that are running"), items: all.filter { !$0.needsYou && $0.runningCount > 0 })]
            + days.map { day in HomeSection(title: dayTitle(day), items: recent.filter { Calendar.current.isDate(date($0), inSameDayAs: day) }) }
    }
    public static func ordered(_ servers: [ServerStore], server: ServerID?, project: String?, hidden: Bool = false, search: String = "") -> [SessionSummary] {
        sections(servers, server: server, project: project, hidden: hidden, search: search).flatMap(\.items)
    }
    /// Each pending permission and question, as the session and request to open, in Home's order.
    public static func approvals(_ items: [SessionSummary]) -> [SessionRef] {
        items.filter(\.needsYou).flatMap { item in
            item.family.flatMap { model in
                (item.server.permissions[model.id] ?? []).map { SessionRef(serverID: item.server.id, sessionID: model.id, requestID: $0.id) }
                    + (item.server.forms[.session(model.id)] ?? []).map { SessionRef(serverID: item.server.id, sessionID: model.id, requestID: $0.id) }
            }
        }
    }
    public static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return localized("Today") }
        if Calendar.current.isDateInYesterday(day) { return localized("Yesterday") }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}
