import Foundation
import MCP

struct TrackDispatcher {
    static let tool = Tool(
        name: "logic_tracks",
        description: """
            Track actions in Logic Pro. \
            Commands: select, create_audio, create_instrument, create_drummer, \
            create_external_midi, delete, duplicate, rename, mute, solo, arm, set_color. \
            Params by command: \
            select -> { index: Int } or { name: String }; \
            rename -> { index: Int, name: String (1-80 characters) } (verified: reads the header name back; tries the header \
            field, then selects the track and uses the Rename key command; error with a step trace when the name does not change); \
            mute/solo -> { index: Int, enabled: Bool } (verified: reads the header's M / S state, presses it, falls back to the \
            key M / S on the verified selected track; success only when the read-back matches); \
            arm -> { index: Int, enabled: Bool }; \
            set_color -> { index: Int, color: Int } (Logic color index 0-24); \
            create_* -> {} (creates at current position); \
            delete -> { index: Int } (REQUIRED; selects the track with read-back, posts Cmd+Delete, confirms Logic's alert, \
            success only when the track count dropped by exactly one); \
            duplicate -> { index: Int }
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Track command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "select":
            if let index = InputValidation.looseInt(params["index"]) {
                let result = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            if let name = params["name"]?.stringValue {
                // Find track by name in cache
                let tracks = await cache.getTracks()
                if let track = tracks.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "track.select",
                        params: ["index": String(track.id)]
                    )
                    return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
                }
                return CallTool.Result(content: [.text("No track found matching '\(name)'")], isError: true)
            }
            return CallTool.Result(content: [.text("select requires 'index' or 'name' param")], isError: true)

        case "create_audio":
            let result = await router.route(operation: "track.create_audio")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_instrument":
            let result = await router.route(operation: "track.create_instrument")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_drummer":
            let result = await router.route(operation: "track.create_drummer")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_external_midi":
            let result = await router.route(operation: "track.create_external_midi")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "delete":
            // The index is required: the channel selects the track with read-back before it deletes.
            guard let index = InputValidation.looseInt(params["index"]) else {
                return CallTool.Result(content: [.text("delete requires 'index' (0-based); nothing was deleted")], isError: true)
            }
            let result = await router.route(
                operation: "track.delete",
                params: ["index": String(index)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "duplicate":
            if let index = InputValidation.looseInt(params["index"]) {
                let selectResult = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                guard selectResult.isSuccess else {
                    return CallTool.Result(content: [.text(selectResult.message)], isError: true)
                }
            }
            let result = await router.route(operation: "track.duplicate")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "rename":
            guard let index = InputValidation.looseInt(params["index"]) else {
                return CallTool.Result(content: [.text("rename requires 'index' (0-based) and 'name'")], isError: true)
            }
            let name = params["name"]?.stringValue ?? ""
            let result = await router.route(
                operation: "track.rename",
                params: ["index": String(index), "name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mute":
            guard let index = InputValidation.looseInt(params["index"]) else {
                return CallTool.Result(content: [.text("mute requires 'index' (0-based)")], isError: true)
            }
            let enabled = params["enabled"]?.boolValue ?? true
            let result = await router.route(
                operation: "track.set_mute",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "solo":
            guard let index = InputValidation.looseInt(params["index"]) else {
                return CallTool.Result(content: [.text("solo requires 'index' (0-based)")], isError: true)
            }
            let enabled = params["enabled"]?.boolValue ?? true
            let result = await router.route(
                operation: "track.set_solo",
                params: ["index": String(index), "enabled": String(enabled)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "arm":
            let index = InputValidation.looseInt(params["index"]) ?? 0
            let enabled = params["enabled"]?.boolValue ?? true
            let result = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "armed": String(enabled)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_color":
            let index = InputValidation.looseInt(params["index"]) ?? 0
            let color = InputValidation.looseInt(params["color"]) ?? 0
            let result = await router.route(
                operation: "track.set_color",
                params: ["index": String(index), "color": String(color)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown track command: \(command). Available: select, create_audio, create_instrument, create_drummer, create_external_midi, delete, duplicate, rename, mute, solo, arm, set_color")],
                isError: true
            )
        }
    }
}
