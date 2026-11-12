import OCFoundation
import OCModels

extension ReadStore {
    func applyText(_ type: String, p: WireObject, assistant: MessageModel?, created: Double) {
        guard let assistant else { return }
        let reasoning = type.hasPrefix("session.reasoning."), kind = reasoning ? "reasoning" : "text"
        let ordinal = p["ordinal"]?.wireInt ?? 0
        let key: ContentKey = reasoning ? .reasoning(ordinal) : .text(ordinal)
        var item = assistant.item(key)
        if type.hasSuffix("started") {
            guard item == nil else { return }
            var raw: JSONValue = .object(["type": .string(kind), "text": .string("")])
            raw.set("state", p["state"])
            if reasoning { raw.set("native", p["native"]) }
            if reasoning { raw.set("time", .object(["created": .number(created)])) }
            assistant.upsert(key, value: .init(raw: raw)); return
        }
        if item == nil {
            // The row is held, but this fragment's start was missed. An end repairs it.
            item = assistant.upsert(key, value: .init(raw: .object(["type": .string(kind), "text": .string("")])), joinedMidStream: true)
        }
        guard let item else { return }
        if type.hasSuffix("delta") { item.append(p.string("delta")); return }
        item.end(p.string("text"))
        // Provider state is `state` up to 2.0.x and `native` from 2.1.0; the app only carries it.
        if reasoning {
            if let state = p["state"] { item.fields["state"] = state }
            if let native = p["native"] { item.fields["native"] = native }
        } else { item.fields["state"] = p["state"]; item.fields["native"] = p["native"] }
        if reasoning {
            item.fields["time"] = .object(["created": item.fields["time"]?["created"] ?? .number(created), "completed": .number(created)])
        }
    }
    func applyTool(_ type: String, p: WireObject, assistant: MessageModel?, created: Double) {
        guard let assistant else { return }
        let key = ContentKey.tool(p.string("id"))
        var item = assistant.item(key)
        if type == "session.tool.input.started" {
            guard item == nil else { return }
            assistant.upsert(key, value: .init(raw: .object(["type": .string("tool"), "id": p["id"] ?? .string(""),
                "name": p["name"] ?? .string(""), "time": .object(["created": .number(created)]),
                "state": .object(["status": .string("streaming"), "input": .string("")])])))
            return
        }
        if item == nil {
            guard !type.hasSuffix("delta"), type != "session.tool.progress" else { return }
            item = assistant.upsert(key, value: .init(raw: .object(["type": .string("tool"), "id": p["id"] ?? .string(""),
                "name": p["name"] ?? .string(""), "time": .object(["created": .number(created)]),
                "state": .object(["status": .string("streaming"), "input": .string("")])])), joinedMidStream: true)
        }
        guard let item else { return }
        var state = item.fields.toolState.fields
        switch type {
        case "session.tool.input.delta":
            if state.status == "streaming" { state["input"] = .string((state.input.stringValue ?? "") + p.string("delta")) }
        case "session.tool.input.ended":
            if state.status == "streaming" { state["input"] = p["text"] }
            item.joinedMidStream = false
        case "session.tool.called":
            item.fields.raw.set(["time", "ran"], .number(created)); item.fields["executed"] = p["executed"]
            item.fields["providerState"] = p["state"]; item.fields["native"] = p["native"]
            state.raw = .object(["status": .string("running"), "input": p["input"] ?? .object([:]), "metadata": .object([:])])
        case "session.tool.progress":
            if state.status == "running" { state["metadata"] = p["metadata"] }
        case "session.tool.success", "session.tool.failed":
            let input = state.input.objectValue == nil ? JSONValue.object([:]) : state.input
            state.raw = .object(["status": .string(type.hasSuffix("success") ? "completed" : "error"), "input": input])
            for field in ["metadata", "content", "error"] { state[field] = p[field] }
            item.fields["executed"] = .bool(p["executed"]?.boolValue == true || item.fields.executed == true)
            item.fields["providerResultState"] = p["resultState"]
            if let native = p["native"]?.objectValue {
                item.fields["native"] = .object((item.fields["native"]?.objectValue ?? [:]).merging(native) { _, new in new })
            }
            item.fields.raw.set(["time", "completed"], .number(created)); item.joinedMidStream = false
        default: return
        }
        item.fields["state"] = state.raw
    }
}
