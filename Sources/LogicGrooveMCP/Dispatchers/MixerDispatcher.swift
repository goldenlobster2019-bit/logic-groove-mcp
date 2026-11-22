import Foundation
import MCP

struct MixerDispatcher {
    static let tool = Tool(
        name: "logic_mixer",
        description: """
            Mixer actions in Logic Pro. \
            Commands: strip, set_volume, set_pan, set_send, set_output, set_input, \
            set_master_volume, toggle_eq, reset_strip, bypass_plugin, insert_plugin. \
            Params by command: \
            strip -> { track?: Int } (JSON of the selected track's channel strip read through Accessibility: \
            instrument and effects top to bottom with bypass state, volume text, peak level text and clipping, \
            Stereo Out volume and peak; call it after building a loop to see levels); \
            set_volume -> { track?: Int, db: Float (-60 to 6) } (the fader is searched until the read-back level \
            is within 0.15 dB; success within 0.3 dB) or the old { track: Int, value: Float } (normalized 0.0-1.0); \
            set_pan -> { track: Int, value: Float } (-1.0 left to +1.0 right); \
            set_send -> { track: Int, bus: Int, value: Float }; \
            set_output -> { track: Int, output: String }; \
            set_input -> { track: Int, input: String }; \
            set_master_volume -> { db: Float (-60 to 6) } (Stereo Out fader of the Inspector) or the old { value: Float }; \
            toggle_eq -> { track: Int }; \
            reset_strip -> { track: Int }; \
            insert_plugin -> { track?: Int (0-based; omit = currently selected track), \
            slot?: "instrument" or 0 = the instrument; "new" / "add" / "append" or omitted = ADD an effect in the empty slot; \
            n >= 1 = REPLACE the n-th existing effect (top to bottom; n beyond the effect count means "new"), \
            name: String, result_index?: Int (default 1: how many times Down is pressed in the menu search results), \
            variant_index?: Int (default 1: entry of the submenu, 1 = first, e.g. Stereo), close_window?: Bool (default true) }. \
            The slot menu is driven with the keyboard (type the name in the menu search field, Down, Right, Return); the \
            insert is confirmed by the new plug-in window AND by the channel strip structure (the message ends with \
            `chain: <instrument> | <effects>`). `track` is selected AND read back through Accessibility first: \
            if the track cannot be selected the command refuses to act (nothing is changed). The message carries a step trace; \
            the result returns undo_label; \
            bypass_plugin -> { track?: Int, plugin?: String (name substring) or slot?: Int (0 = instrument, n = n-th effect), \
            bypassed: Bool } (presses the bypass checkbox only when the state differs, read back)
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Mixer command to execute"),
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
        case "strip":
            let track = params["track"]?.intValue ?? params["track_index"]?.intValue ?? -1
            let result = await router.route(operation: "mixer.strip", params: ["track_index": String(track)])
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_volume":
            if let db = params["db"]?.doubleValue {
                let track = params["track"]?.intValue ?? params["track_index"]?.intValue ?? -1
                let result = await router.route(
                    operation: "mixer.set_volume_db",
                    params: ["track_index": String(track), "db": String(db)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? params["volume"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_volume",
                params: ["index": String(track), "volume": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_pan":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? params["pan"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_pan",
                params: ["index": String(track), "pan": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_send":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let bus = params["bus"]?.intValue ?? params["send_index"]?.intValue ?? 0
            let value = params["value"]?.doubleValue ?? params["level"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_send",
                params: ["index": String(track), "send_index": String(bus), "level": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_output":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let output = params["output"]?.stringValue ?? ""
            let result = await router.route(
                operation: "mixer.set_output",
                params: ["index": String(track), "output": output]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_input":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let input = params["input"]?.stringValue ?? ""
            let result = await router.route(
                operation: "mixer.set_input",
                params: ["index": String(track), "input": input]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_master_volume":
            if let db = params["db"]?.doubleValue {
                let result = await router.route(operation: "mixer.set_master_volume_db", params: ["db": String(db)])
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let value = params["value"]?.doubleValue ?? params["volume"]?.doubleValue ?? 0.0
            let result = await router.route(
                operation: "mixer.set_master_volume",
                params: ["volume": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_eq":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "mixer.toggle_eq",
                params: ["index": String(track)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "reset_strip":
            let track = params["track"]?.intValue ?? params["index"]?.intValue ?? 0
            let result = await router.route(
                operation: "mixer.reset_strip",
                params: ["index": String(track)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "insert_plugin":
            // No track -> act on the currently selected track (recommended: select it first).
            let track = params["track"]?.intValue ?? params["track_index"]?.intValue ?? -1
            // slot: "instrument"/0, "new"/"add"/"append" (default when omitted), or n >= 1 (replace the n-th effect).
            let slot = params["slot"]?.stringValue ?? params["slot"]?.intValue.map { String($0) } ?? "new"
            let name = params["name"]?.stringValue ?? params["plugin_name"]?.stringValue ?? ""
            var insertParams = ["track_index": String(track), "plugin_name": name, "slot": slot]
            if let resultIndex = params["result_index"]?.intValue {
                insertParams["result_index"] = String(resultIndex)
            }
            if let variantIndex = params["variant_index"]?.intValue {
                insertParams["variant_index"] = String(variantIndex)
            }
            if let closeWindow = params["close_window"]?.boolValue {
                insertParams["close_window"] = closeWindow ? "true" : "false"
            }
            let result = await router.route(operation: "plugin.insert", params: insertParams)
            var undoLabel = Value.null
            if result.isSuccess {
                _ = try? await Task.sleep(for: .milliseconds(300))
                if let title = AXLogicProElements.undoMenuTitle() {
                    undoLabel = Value.string(title)
                }
            }
            let payload = Value.object([
                "ok": Value.bool(result.isSuccess),
                "message": Value.string(result.message),
                "undo_label": undoLabel,
            ])
            return CallTool.Result(content: [.text(encodeJSON(payload))], isError: !result.isSuccess)

        case "bypass_plugin":
            // No track -> act on the currently selected track (recommended: select it first).
            let track = params["track"]?.intValue ?? params["track_index"]?.intValue ?? -1
            let bypassed = params["bypassed"]?.boolValue ?? true
            var bypassParams = ["track_index": String(track), "bypassed": String(bypassed)]
            if let plugin = params["plugin"]?.stringValue ?? params["name"]?.stringValue, !plugin.isEmpty {
                bypassParams["plugin"] = plugin
            } else if let slot = params["slot"]?.stringValue ?? params["slot"]?.intValue.map({ String($0) }) {
                bypassParams["slot"] = slot
            }
            let result = await router.route(operation: "plugin.bypass", params: bypassParams)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown mixer command: \(command). Available: strip, set_volume, set_pan, set_send, set_output, set_input, set_master_volume, toggle_eq, reset_strip, insert_plugin, bypass_plugin")],
                isError: true
            )
        }
    }
}
