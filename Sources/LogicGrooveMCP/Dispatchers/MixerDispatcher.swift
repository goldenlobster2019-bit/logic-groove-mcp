import Foundation
import MCP

struct MixerDispatcher {
    static let tool = Tool(
        name: "logic_mixer",
        description: """
            Mixer actions in Logic Pro. \
            Commands: strip, set_volume, set_pan, set_send, set_output, set_input, \
            set_master_volume, toggle_eq, reset_strip, bypass_plugin, insert_plugin, open_plugin, close_plugin, \
            plugin_setting, set_plugin_setting, plugin_settings_menu, plugin_popups, set_plugin_popup, plugin_params, \
            set_plugin_param. \
            Params by command: \
            strip -> { track?: Int } (JSON of the selected track's channel strip read through Accessibility: \
            instrument and effects top to bottom with bypass state, volume text, peak level text and clipping, \
            Stereo Out volume and peak; call it after building a loop to see levels); \
            set_volume -> { track?: Int, db: Float or Int (-60 to 6) } (the fader is STEPPED with read-back from the level text until it \
            is within 0.15 dB; success within 0.3 dB; may take several seconds; the message names the method and the readings) or the old { track: Int, value: Float } (normalized 0.0-1.0); \
            set_pan -> { track: Int, value: Float } (-1.0 left to +1.0 right); \
            set_send -> { track: Int, bus: Int, value: Float }; \
            set_output -> { track: Int, output: String }; \
            set_input -> { track: Int, input: String }; \
            set_master_volume -> { db: Float or Int (-60 to 6) } (Stereo Out fader of the Inspector, stepped like set_volume) or the old { value: Float }; \
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
            bypassed: Bool } (presses the bypass checkbox only when the state differs, read back); \
            PLUG-IN WINDOW COMMANDS. Common params: track?: Int (0-based, selected and read back; omit = selected track), \
            plugin?: String (name substring among instrument and effects) or slot?: Int (0 = instrument, n = n-th effect; \
            default the instrument), keep_open?: Bool (default false: a window the command opened is closed again at the end). \
            open_plugin -> {} (opens the window and leaves it open); close_plugin -> {}; \
            plugin_setting -> {} (the current setting name of Logic's settings menu); \
            set_plugin_setting -> { setting: String, a path with "/" for submenus, e.g. "Dub Delays/Dub Echo" } (verified by the \
            pop-up value; when an item is not found the error lists the titles of that menu level, which also lists the settings); \
            plugin_settings_menu -> { path?: String } (lists the items of the settings menu or of the submenu `path`); \
            plugin_popups -> {} (settings pop-up and plug-in specific pop-ups: index | value; Drum Synth: 0 = sound category, \
            1 = sound module); \
            set_plugin_popup -> { index: Int (0-based among the plug-in specific pop-ups), value: String } (verified by the value); \
            plugin_params -> { filter?: String } (switches the window to Logic's Controls view and lists every slider: \
            index | label | value text | raw (min..max) | flags v = slider value settable, t = text field settable; switches back); \
            set_plugin_param -> { param?: String (label) or index?: Int, value: Number or String, raw?: Bool } (tries the slider \
            AXValue with a linear probe, then the numeric text field, then AXIncrement / AXDecrement; read back after each; \
            success within one step of the displayed value). The Controls view structure is not verified yet: use \
            logic_system debug_plugin to see it
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
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["track_index"]) ?? -1
            let result = await router.route(operation: "mixer.strip", params: ["track_index": String(track)])
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_volume":
            if let db = InputValidation.looseDouble(params["db"]) {
                let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["track_index"]) ?? -1
                let result = await router.route(
                    operation: "mixer.set_volume_db",
                    params: ["track_index": String(track), "db": String(db)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let value = InputValidation.looseDouble(params["value"]) ?? InputValidation.looseDouble(params["volume"]) ?? 0.0
            let result = await router.route(
                operation: "mixer.set_volume",
                params: ["index": String(track), "volume": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_pan":
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let value = InputValidation.looseDouble(params["value"]) ?? InputValidation.looseDouble(params["pan"]) ?? 0.0
            let result = await router.route(
                operation: "mixer.set_pan",
                params: ["index": String(track), "pan": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_send":
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let bus = InputValidation.looseInt(params["bus"]) ?? InputValidation.looseInt(params["send_index"]) ?? 0
            let value = InputValidation.looseDouble(params["value"]) ?? InputValidation.looseDouble(params["level"]) ?? 0.0
            let result = await router.route(
                operation: "mixer.set_send",
                params: ["index": String(track), "send_index": String(bus), "level": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_output":
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let output = params["output"]?.stringValue ?? ""
            let result = await router.route(
                operation: "mixer.set_output",
                params: ["index": String(track), "output": output]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_input":
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let input = params["input"]?.stringValue ?? ""
            let result = await router.route(
                operation: "mixer.set_input",
                params: ["index": String(track), "input": input]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_master_volume":
            if let db = InputValidation.looseDouble(params["db"]) {
                let result = await router.route(operation: "mixer.set_master_volume_db", params: ["db": String(db)])
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            let value = InputValidation.looseDouble(params["value"]) ?? InputValidation.looseDouble(params["volume"]) ?? 0.0
            let result = await router.route(
                operation: "mixer.set_master_volume",
                params: ["volume": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_eq":
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let result = await router.route(
                operation: "mixer.toggle_eq",
                params: ["index": String(track)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "reset_strip":
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["index"]) ?? 0
            let result = await router.route(
                operation: "mixer.reset_strip",
                params: ["index": String(track)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "insert_plugin":
            // No track -> act on the currently selected track (recommended: select it first).
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["track_index"]) ?? -1
            // slot: "instrument"/0, "new"/"add"/"append" (default when omitted), or n >= 1 (replace the n-th effect).
            let slot = params["slot"]?.stringValue ?? InputValidation.looseInt(params["slot"]).map { String($0) } ?? "new"
            let name = params["name"]?.stringValue ?? params["plugin_name"]?.stringValue ?? ""
            var insertParams = ["track_index": String(track), "plugin_name": name, "slot": slot]
            if let resultIndex = InputValidation.looseInt(params["result_index"]) {
                insertParams["result_index"] = String(resultIndex)
            }
            if let variantIndex = InputValidation.looseInt(params["variant_index"]) {
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
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["track_index"]) ?? -1
            let bypassed = params["bypassed"]?.boolValue ?? true
            var bypassParams = ["track_index": String(track), "bypassed": String(bypassed)]
            if let plugin = params["plugin"]?.stringValue ?? params["name"]?.stringValue, !plugin.isEmpty {
                bypassParams["plugin"] = plugin
            } else if let slot = params["slot"]?.stringValue ?? InputValidation.looseInt(params["slot"]).map({ String($0) }) {
                bypassParams["slot"] = slot
            }
            let result = await router.route(operation: "plugin.bypass", params: bypassParams)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "open_plugin", "close_plugin", "plugin_setting", "set_plugin_setting", "plugin_settings_menu",
             "plugin_popups", "set_plugin_popup", "plugin_params", "set_plugin_param":
            let operations: [String: String] = [
                "open_plugin": "plugin.open", "close_plugin": "plugin.close",
                "plugin_setting": "plugin.setting_get", "set_plugin_setting": "plugin.setting_set",
                "plugin_settings_menu": "plugin.settings_menu", "plugin_popups": "plugin.popups",
                "set_plugin_popup": "plugin.popup_set", "plugin_params": "plugin.params",
                "set_plugin_param": "plugin.param_set",
            ]
            guard let operation = operations[command] else {
                return CallTool.Result(content: [.text("Unknown plug-in command: \(command)")], isError: true)
            }
            let track = InputValidation.looseInt(params["track"]) ?? InputValidation.looseInt(params["track_index"]) ?? -1
            var pluginParams: [String: String] = ["track_index": String(track)]
            if let plugin = params["plugin"]?.stringValue ?? params["name"]?.stringValue, !plugin.isEmpty {
                pluginParams["plugin"] = plugin
            } else if let slot = params["slot"]?.stringValue ?? InputValidation.looseInt(params["slot"]).map({ String($0) }) {
                pluginParams["slot"] = slot
            }
            if let keepOpen = params["keep_open"]?.boolValue { pluginParams["keep_open"] = keepOpen ? "true" : "false" }
            switch command {
            case "set_plugin_setting":
                guard let setting = params["setting"]?.stringValue, !setting.isEmpty else {
                    return CallTool.Result(content: [.text("set_plugin_setting requires 'setting' (a menu item title or a path with \"/\")")], isError: true)
                }
                pluginParams["setting"] = setting
            case "plugin_settings_menu":
                if let path = params["path"]?.stringValue, !path.isEmpty { pluginParams["path"] = path }
            case "set_plugin_popup":
                guard let index = InputValidation.looseInt(params["index"]), index >= 0 else {
                    return CallTool.Result(content: [.text("set_plugin_popup requires 'index' (0-based among the plug-in specific pop-ups)")], isError: true)
                }
                guard let value = params["value"]?.stringValue, !value.isEmpty else {
                    return CallTool.Result(content: [.text("set_plugin_popup requires 'value' (the menu item title)")], isError: true)
                }
                pluginParams["index"] = String(index)
                pluginParams["value"] = value
            case "plugin_params":
                if let filter = params["filter"]?.stringValue, !filter.isEmpty { pluginParams["filter"] = filter }
            case "set_plugin_param":
                if let name = params["param"]?.stringValue, !name.isEmpty {
                    pluginParams["param"] = name
                } else if let index = InputValidation.looseInt(params["index"]) {
                    pluginParams["index"] = String(index)
                } else {
                    return CallTool.Result(content: [.text("set_plugin_param requires 'param' (label) or 'index'")], isError: true)
                }
                if let number = InputValidation.looseDouble(params["value"]) {
                    pluginParams["value"] = String(format: "%.8f", number)
                } else if let text = params["value"]?.stringValue, !text.isEmpty {
                    pluginParams["value"] = text
                } else {
                    return CallTool.Result(content: [.text("set_plugin_param requires 'value'")], isError: true)
                }
                if let raw = params["raw"]?.boolValue { pluginParams["raw"] = raw ? "true" : "false" }
            default:
                break
            }
            let result = await router.route(operation: operation, params: pluginParams)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown mixer command: \(command). Available: strip, set_volume, set_pan, set_send, set_output, set_input, set_master_volume, toggle_eq, reset_strip, insert_plugin, bypass_plugin, open_plugin, close_plugin, plugin_setting, set_plugin_setting, plugin_settings_menu, plugin_popups, set_plugin_popup, plugin_params, set_plugin_param")],
                isError: true
            )
        }
    }
}
