import Foundation
import MCP
import MusicCore

/// `logic_sounds`: choose presets of u-he synths (default Diva) without touching the plug-in's custom UI.
/// The synth loads up to 128 presets from its "MIDI Programs" folder when the host starts (alphabetical
/// order, the first file is program 0) and selects them by MIDI Program Change.
struct SoundDispatcher {
    static let tool = Tool(
        name: "logic_sounds",
        description: """
            Choose presets of u-he synths (default plug-in "Diva") without the plug-in's custom-drawn UI, through the synth's \
            "MIDI Programs" folder: up to 128 presets that the synth loads ALPHABETICALLY when the host starts (the first file is \
            program 0) and selects by MIDI Program Change. \
            Commands: folders, presets, preset_info, bank, bank_install, set_preset, verify. \
            Params common to all commands: plugin?: String (default "Diva"; letters, digits, space, dash, underscore, max 40). \
            Preset roots: /Library/Audio/Presets/u-he/<plugin> (local) and ~/Library/Audio/Presets/u-he/<plugin> (user); the bank \
            folder is <local root>/MIDI Programs (it must be writable by the user: Finder > Get Info > Sharing & Permissions). \
            folders -> {} (existing roots, total count, preset folders with counts); \
            presets -> { query?: String, folder?: String, category?: String, limit?: Int (1-200, default 40), format?: "text" (default) | "json" } \
            (browse; the default output is COMPACT plain text: a first line `shown/total`, then one line per preset: \
            `name | folder | categories | program N` (program only when the preset is in the bank); format "json" gives the full \
            meta objects); \
            preset_info -> { preset: String (name or "folder/name") } (JSON: name, folder, author, description, usage - how the \
            preset is meant to be played, e.g. which key -, categories, features, character, program); \
            bank -> { format?: "text" (default: `program  name` per line) | "json" } (the installed bank; warns when the bank \
            changed after Logic was launched); \
            bank_install -> { presets: [String] (1-128 names, "folder/name" or absolute paths inside the roots), mode?: "replace" \
            (default: the bank holds exactly these) | "append" } (all references are resolved first, any failure writes nothing; \
            restart_required is always true: QUIT AND REOPEN LOGIC PRO, the synth reads MIDI Programs only when the host starts); \
            set_preset -> { track?: Int, preset?: String or program?: Int } (DOES NOT SEND MIDI: a live Program Change does not reach \
            the plug-in. It returns { ok: false, program, message } with the program number resolved from the bank; put `program: N` \
            on the clip written with logic_compose write, then check the track name with verify); \
            verify -> { track?: Int (0-based; omit = the selected track), preset?: String } (selects the track with read-back and \
            returns { track, track_name, bank_program (parsed from a name like "0/29 029 HS Stabz", else null), matches (only with \
            preset) }). \
            Workflow: presets / preset_info to browse, bank_install once, restart Logic, then per track: insert_plugin, \
            logic_compose write with `program`, verify.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Sound command to execute"),
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
        let plugin: String
        let rawPlugin = params["plugin"]?.stringValue ?? "Diva"
        switch ComposeSupport.validatePluginFolderName(rawPlugin) {
        case .success(let value): plugin = value
        case .failure(let message): return error(message)
        }

        switch command {
        case "folders":
            return foldersResult(plugin: plugin)
        case "presets":
            return presetsResult(plugin: plugin, params: params)
        case "preset_info":
            return presetInfoResult(plugin: plugin, params: params)
        case "bank":
            return bankResult(plugin: plugin, params: params)
        case "verify":
            return await verifyResult(plugin: plugin, params: params, router: router)
        case "bank_install":
            return bankInstallResult(plugin: plugin, params: params)
        case "set_preset":
            return await setPresetResult(plugin: plugin, params: params, router: router)
        default:
            return error("Unknown sounds command: \(command). Available: folders, presets, preset_info, bank, bank_install, set_preset, verify")
        }
    }

    // MARK: - Roots and bank state

    /// The preset roots that exist on disk (local first, then user).
    private static func existingRoots(plugin: String) -> [(label: String, url: URL)] {
        let candidates: [(label: String, url: URL)] = [
            ("local", ComposeSupport.uheLocalRoot(plugin: plugin)),
            ("user", ComposeSupport.uheUserRoot(plugin: plugin)),
        ]
        var result: [(label: String, url: URL)] = []
        for candidate in candidates {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                result.append(candidate)
            }
        }
        return result
    }

    private static func noRootsMessage(plugin: String) -> String {
        "No u-he preset folder found for \(plugin). Looked in \(ComposeSupport.uheLocalRoot(plugin: plugin).path) and \(ComposeSupport.uheUserRoot(plugin: plugin).path)"
    }

    /// true when the bank folder changed after Logic was launched (the synth has not read it yet),
    /// false when Logic started after the last change, nil when that cannot be told.
    private static func bankChangedAfterLogicLaunch(plugin: String) -> Bool? {
        guard let launch = ProcessUtils.logicProLaunchDate() else { return nil }
        guard let newest = ComposeSupport.newestModificationDate(in: ComposeSupport.uheBankFolder(plugin: plugin)) else {
            return nil
        }
        return newest > launch
    }

    private static let restartWarning = "The bank changed after Logic started; quit and reopen Logic or the program numbers will not match."

    private static func bankEntryValue(_ entry: BankEntry) -> Value {
        .object([
            "program": .int(entry.program),
            "name": .string(entry.name),
            "file": .string(entry.fileName),
        ])
    }

    private static func describe(_ failure: PresetLibraryError) -> String {
        var text = failure.description
        if case .writeFailed = failure {
            text += ". The folder must be writable by your user (Finder > Get Info > Sharing & Permissions)"
        }
        return text
    }

    // MARK: - folders

    private static func foldersResult(plugin: String) -> CallTool.Result {
        let roots = existingRoots(plugin: plugin)
        guard !roots.isEmpty else { return error(noRootsMessage(plugin: plugin)) }
        let presets = PresetLibrary.scan(roots: roots.map { $0.url }, readMeta: false)
        let folders: [Value] = PresetLibrary.folderCounts(presets).map { entry in
            Value.object(["folder": .string(entry.folder), "count": .int(entry.count)])
        }
        let rootValues: [Value] = roots.map { root in
            Value.object(["label": .string(root.label), "path": .string(root.url.path)])
        }
        return json(.object([
            "plugin": .string(plugin),
            "roots": .array(rootValues),
            "total": .int(presets.count),
            "folders": .array(folders),
        ]))
    }

    // MARK: - presets

    private static func presetsResult(plugin: String, params: [String: Value]) -> CallTool.Result {
        let roots = existingRoots(plugin: plugin)
        guard !roots.isEmpty else { return error(noRootsMessage(plugin: plugin)) }

        let limit: Int
        switch InputValidation.int(params, keys: ["limit"], default: 40, range: 1...200, label: "limit") {
        case .success(let value): limit = value
        case .failure(let message): return error(message)
        }
        let query = optionalText(params, "query")
        let folder = optionalText(params, "folder")
        let category = optionalText(params, "category")
        let readMeta = true

        let presets = PresetLibrary.scan(roots: roots.map { $0.url }, readMeta: readMeta)
        let matches = PresetLibrary.search(presets, query: query, folder: folder, category: category, limit: 0)
        let shown = Array(matches.prefix(limit))

        var programByName: [String: Int] = [:]
        for entry in PresetLibrary.readBank(folder: ComposeSupport.uheBankFolder(plugin: plugin)) {
            programByName[entry.name.lowercased()] = entry.program
        }
        let asJSON = (params["format"]?.stringValue ?? "text").lowercased() == "json"
        if !asJSON {
            var lines = ["\(shown.count)/\(matches.count)"]
            for preset in shown {
                lines.append(ComposeSupport.compactPresetLine(
                    name: preset.name, folder: preset.folder, categories: preset.categories,
                    program: programByName[preset.name.lowercased()]))
            }
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }
        let values: [Value] = shown.map { preset in
            var object: [String: Value] = [
                "name": .string(preset.name),
                "folder": .string(preset.folder),
                "categories": .array(preset.categories.map { Value.string($0) }),
                "features": .array(preset.features.map { Value.string($0) }),
                "character": .array(preset.character.map { Value.string($0) }),
                "author": preset.author.map { Value.string($0) } ?? Value.null,
            ]
            if let program = programByName[preset.name.lowercased()] {
                object["program"] = .int(program)
            }
            return Value.object(object)
        }
        return json(.object([
            "plugin": .string(plugin),
            "total_matches": .int(matches.count),
            "shown": .int(shown.count),
            "presets": .array(values),
        ]))
    }

    private static func presetInfoResult(plugin: String, params: [String: Value]) -> CallTool.Result {
        let roots = existingRoots(plugin: plugin)
        guard !roots.isEmpty else { return error(noRootsMessage(plugin: plugin)) }
        guard let reference = optionalText(params, "preset") else { return error("preset_info needs 'preset' (name or \"folder/name\")") }
        guard ComposeSupport.isSafePresetReference(reference) else {
            return error("preset is not a valid reference (too long, control characters or \"..\")")
        }
        let library = PresetLibrary.scan(roots: roots.map { $0.url }, readMeta: true)
        switch PresetLibrary.resolve(reference, in: library) {
        case .failure(let failure):
            return error("'\(reference)': \(describe(failure))")
        case .success(let preset):
            var program = Value.null
            for entry in PresetLibrary.readBank(folder: ComposeSupport.uheBankFolder(plugin: plugin))
            where entry.name.lowercased() == preset.name.lowercased() {
                program = .int(entry.program)
                break
            }
            return json(.object([
                "name": .string(preset.name),
                "folder": .string(preset.folder),
                "author": preset.author.map { Value.string($0) } ?? Value.null,
                "description": preset.description.map { Value.string($0) } ?? Value.null,
                "usage": preset.usage.map { Value.string($0) } ?? Value.null,
                "categories": .array(preset.categories.map { Value.string($0) }),
                "features": .array(preset.features.map { Value.string($0) }),
                "character": .array(preset.character.map { Value.string($0) }),
                "program": program,
            ]))
        }
    }

    private static func optionalText(_ params: [String: Value], _ key: String) -> String? {
        guard let text = params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - bank

    private static func bankResult(plugin: String, params: [String: Value]) -> CallTool.Result {
        let folder = ComposeSupport.uheBankFolder(plugin: plugin)
        let entries = PresetLibrary.readBank(folder: folder)
        let changed = bankChangedAfterLogicLaunch(plugin: plugin)
        if (params["format"]?.stringValue ?? "text").lowercased() != "json" {
            var lines: [String] = ["\(entries.count) programs in \(folder.path)"]
            if changed == true { lines.append("WARNING: \(restartWarning)") }
            if entries.isEmpty { lines.append("The bank is empty or the folder does not exist. Run bank_install, then quit and reopen Logic Pro.") }
            for entry in entries { lines.append(ComposeSupport.compactBankLine(program: entry.program, name: entry.name)) }
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
        }
        var result: [String: Value] = [
            "plugin": .string(plugin),
            "folder": .string(folder.path),
            "count": .int(entries.count),
            "entries": .array(entries.map { bankEntryValue($0) }),
            "logic_started_after_bank_change": changed.map { Value.bool(!$0) } ?? Value.null,
        ]
        var note = "Programs are the alphabetical order of the files in the folder; the synth reads them only when Logic starts."
        if entries.isEmpty {
            note = "The bank is empty or the folder does not exist. Run bank_install, then quit and reopen Logic Pro."
        }
        if changed == true {
            result["warning"] = .string(restartWarning)
        }
        result["note"] = .string(note)
        return json(.object(result))
    }

    // MARK: - bank_install

    private static func bankInstallResult(plugin: String, params: [String: Value]) -> CallTool.Result {
        var references: [String] = []
        if let array = params["presets"]?.arrayValue {
            for item in array {
                guard let text = item.stringValue else { return error("presets must be an array of strings") }
                references.append(text)
            }
        } else if let single = params["presets"]?.stringValue {
            references = [single]
        }
        guard (1...128).contains(references.count) else {
            return error("presets must list 1-128 preset references (names, \"folder/name\" or absolute paths); got \(references.count)")
        }
        let modeText = (params["mode"]?.stringValue ?? "replace").lowercased()
        guard let mode = PresetLibrary.BankMode(rawValue: modeText) else {
            return error("mode must be \"replace\" or \"append\"")
        }
        let roots = existingRoots(plugin: plugin)
        guard !roots.isEmpty else { return error(noRootsMessage(plugin: plugin)) }
        let rootURLs = roots.map { $0.url }
        let library = PresetLibrary.scan(roots: rootURLs, readMeta: false)

        // Resolve ALL references first: nothing is written when any of them fails.
        var resolved: [SynthPreset] = []
        var failures: [String] = []
        for reference in references {
            guard ComposeSupport.isSafePresetReference(reference) else {
                failures.append("'\(String(reference.prefix(80)))': not a valid reference (empty, too long, control characters or \"..\")")
                continue
            }
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~"), !ComposeSupport.path(trimmed, isInside: rootURLs) {
                failures.append("'\(trimmed)': the path is outside the preset folders")
                continue
            }
            switch PresetLibrary.resolve(trimmed, in: library) {
            case .success(let preset): resolved.append(preset)
            case .failure(let failure): failures.append("'\(trimmed)': \(describe(failure))")
            }
        }
        guard failures.isEmpty else {
            return error("Nothing was written. \(failures.count) reference(s) could not be resolved: \(failures.joined(separator: "; "))")
        }

        let folder = ComposeSupport.uheBankFolder(plugin: plugin)
        let manifest = ComposeSupport.soundBankManifestURL(plugin: plugin)
        do {
            try FileManager.default.createDirectory(at: ComposeSupport.soundsDirectory(), withIntermediateDirectories: true)
            let installed = try PresetLibrary.installBank(presets: resolved, bankFolder: folder, manifestURL: manifest, mode: mode)
            Log.info("Installed \(installed.entries.count) presets into \(folder.path)", subsystem: "sounds")
            return json(.object([
                "plugin": .string(plugin),
                "folder": .string(folder.path),
                "mode": .string(mode.rawValue),
                "entries": .array(installed.entries.map { bankEntryValue($0) }),
                "copied": .array(installed.copied.map { Value.string($0) }),
                "removed": .array(installed.removed.map { Value.string($0) }),
                "foreign_files": .array(installed.foreignFiles.map { Value.string($0) }),
                "warnings": .array(installed.warnings.map { Value.string($0) }),
                "restart_required": .bool(true),
                "note": .string("Quit and reopen Logic Pro: the synth reads MIDI Programs only when the host starts."),
            ]))
        } catch let failure as PresetLibraryError {
            return error("Bank not installed: \(describe(failure))")
        } catch {
            return Self.error("Bank not installed: \(error.localizedDescription)")
        }
    }

    // MARK: - set_preset

    private static func setPresetResult(
        plugin: String,
        params: [String: Value],
        router: ChannelRouter
    ) async -> CallTool.Result {
        var track: Int?
        if let supplied = params["track"], !isNull(supplied) {
            guard let value = InputValidation.looseInt(supplied), (0...10_000).contains(value) else {
                return error("track must be an integer between 0 and 10000 (0-based)")
            }
            track = value
        }
        var wantedProgram: Int?
        if let supplied = params["program"], !isNull(supplied) {
            guard let value = InputValidation.looseInt(supplied), (0...127).contains(value) else {
                return error("program must be an integer between 0 and 127")
            }
            wantedProgram = value
        }
        let reference = optionalText(params, "preset")
        guard wantedProgram != nil || reference != nil else {
            return error("set_preset needs 'preset' (name, number or part of a name from the bank) or 'program' (0-127)")
        }
        if let reference, !ComposeSupport.isSafePresetReference(reference) {
            return error("preset is not a valid reference (too long, control characters or \"..\")")
        }

        // (a) Resolve the program from the installed bank.
        let bank = PresetLibrary.readBank(folder: ComposeSupport.uheBankFolder(plugin: plugin))
        guard !bank.isEmpty else {
            return error("The \(plugin) MIDI Programs bank is empty or missing. Run logic_sounds bank_install, then quit and reopen Logic Pro.")
        }
        var found: BankEntry?
        if let wantedProgram {
            found = bank.first { $0.program == wantedProgram }
        } else if let reference {
            found = PresetLibrary.program(for: reference, in: bank)
        }
        guard let entry = found else {
            let wantedText = reference ?? "program \(wantedProgram ?? -1)"
            let words = wantedText.lowercased().split(separator: " ").map { String($0) }
            var close = bank.filter { item in
                let lowered = item.name.lowercased()
                return words.contains { lowered.contains($0) }
            }
            if close.isEmpty { close = bank }
            let names = close.prefix(10).map { "\($0.program): \($0.name)" }.joined(separator: ", ")
            return error("'\(wantedText)' is not in the \(plugin) bank (\(bank.count) presets). Close names: \(names). Run logic_sounds bank_install to change the bank (then quit and reopen Logic Pro).")
        }

        var trace: [String] = []
        let changedAfterLaunch = bankChangedAfterLogicLaunch(plugin: plugin) == true
        if changedAfterLaunch { trace.append(restartWarning) }

        // Keep the track and instrument checks so the message can name the current track.
        let prepared = await router.route(
            operation: "sound.prepare_instrument",
            params: ["track_index": String(track ?? -1), "plugin": plugin]
        )
        trace.append(prepared.message)
        let currentName = AXLogicProElements.selectedTrackName()
        var message = "No MIDI was sent: a live Program Change does not reach the plug-in in Logic. Preset '\(entry.name)' is program \(entry.program) of the \(plugin) bank. Write the part with logic_compose write and `program: \(entry.program)` (the Program Change inside the region loads the preset when the region start is played or chased), then check the track name with logic_sounds verify: it reads like \"0/\(entry.program) \(String(format: "%03d", entry.program)) \(entry.name)\"."
        if !prepared.isSuccess {
            message += " Note: the track/instrument check failed: \(prepared.message)"
        }
        if changedAfterLaunch {
            message += " Warning: \(restartWarning)"
        }
        return json(.object([
            "ok": .bool(false),
            "program": .int(entry.program),
            "preset": .string(entry.name),
            "current_track_name": currentName.map { Value.string($0) } ?? Value.null,
            "message": .string(message),
            "trace": .array(trace.map { Value.string($0) }),
        ]))
    }

    // MARK: - verify

    private static func verifyResult(plugin: String, params: [String: Value], router: ChannelRouter) async -> CallTool.Result {
        var track = -1
        if let supplied = params["track"], !isNull(supplied) {
            guard let value = InputValidation.looseInt(supplied), (0...10_000).contains(value) else {
                return error("track must be an integer between 0 and 10000 (0-based)")
            }
            track = value
        }
        let reference = optionalText(params, "preset")
        let result = await router.route(operation: "sound.verify", params: ["track_index": String(track)])
        guard result.isSuccess else { return error(result.message) }
        guard let data = result.message.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return error("Unreadable verify result: \(result.message)")
        }
        let trackName = (object["track_name"] as? String) ?? ""
        var fields: [String: Value] = [
            "track": (object["track"] as? Int).map { Value.int($0) } ?? Value.null,
            "track_name": .string(trackName),
        ]
        if let parsed = ComposeSupport.parseBankProgram(trackName) {
            fields["bank_program"] = .int(parsed.program)
            fields["bank"] = .int(parsed.bank)
        } else {
            fields["bank_program"] = .null
        }
        if let reference {
            let bank = PresetLibrary.readBank(folder: ComposeSupport.uheBankFolder(plugin: plugin))
            let entry = PresetLibrary.program(for: reference, in: bank)
            let lowered = trackName.lowercased()
            var matches = false
            if let entry {
                matches = lowered.contains(entry.name.lowercased())
                fields["expected_program"] = .int(entry.program)
            } else {
                matches = lowered.contains(reference.lowercased())
            }
            fields["matches"] = .bool(matches)
        }
        return json(.object(fields))
    }

    private static func isNull(_ value: Value) -> Bool {
        if case .null = value { return true }
        return false
    }

    // MARK: - Results

    private static func json(_ value: Value, isError: Bool = false) -> CallTool.Result {
        CallTool.Result(content: [.text(encodeJSON(value))], isError: isError)
    }

    private static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }
}
