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
            Commands: folders, presets, bank, bank_install, set_preset. \
            Params common to all commands: plugin?: String (default "Diva"; letters, digits, space, dash, underscore, max 40). \
            Preset roots: /Library/Audio/Presets/u-he/<plugin> (local) and ~/Library/Audio/Presets/u-he/<plugin> (user); the bank \
            folder is <local root>/MIDI Programs (it must be writable by the user: Finder > Get Info > Sharing & Permissions). \
            folders -> {} (existing roots, total count, preset folders with counts); \
            presets -> { query?: String, folder?: String, category?: String, limit?: Int (1-200, default 40), meta?: Bool (default true: \
            read categories, features and character from the files) } (browse; `program` is shown when the preset is in the bank); \
            bank -> {} (the installed bank: program, name, file; warns when the bank changed after Logic was launched); \
            bank_install -> { presets: [String] (1-128 names, "folder/name" or absolute paths inside the roots), mode?: "replace" \
            (default: the bank holds exactly these) | "append" } (all references are resolved first, any failure writes nothing; \
            restart_required is always true: QUIT AND REOPEN LOGIC PRO, the synth reads MIDI Programs only when the host starts); \
            set_preset -> { track?: Int (0-based; omit = the selected track), preset?: String (name, number or unique part of a name \
            in the bank) or program?: Int (0-127), channel?: Int (1-16, default 1) } (selects the track with read-back, requires the \
            instrument to be the plug-in (insert it first with logic_mixer insert_plugin slot "instrument"), sends Bank Select CC 0 = 0 \
            and the Program Change, then reads the track name back; verified is true only when the name now contains the preset name; \
            otherwise the Program Change was sent but the plug-in display cannot be read through Accessibility). \
            Workflow: presets / folders to browse, bank_install once, restart Logic, then per track insert_plugin + set_preset.
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
        case "bank":
            return bankResult(plugin: plugin)
        case "bank_install":
            return bankInstallResult(plugin: plugin, params: params)
        case "set_preset":
            return await setPresetResult(plugin: plugin, params: params, router: router)
        default:
            return error("Unknown sounds command: \(command). Available: folders, presets, bank, bank_install, set_preset")
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
        let wantMeta = params["meta"]?.boolValue ?? true
        let readMeta = wantMeta || query != nil || category != nil

        let presets = PresetLibrary.scan(roots: roots.map { $0.url }, readMeta: readMeta)
        let matches = PresetLibrary.search(presets, query: query, folder: folder, category: category, limit: 0)
        let shown = Array(matches.prefix(limit))

        var programByName: [String: Int] = [:]
        for entry in PresetLibrary.readBank(folder: ComposeSupport.uheBankFolder(plugin: plugin)) {
            programByName[entry.name.lowercased()] = entry.program
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

    private static func optionalText(_ params: [String: Value], _ key: String) -> String? {
        guard let text = params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - bank

    private static func bankResult(plugin: String) -> CallTool.Result {
        let folder = ComposeSupport.uheBankFolder(plugin: plugin)
        let entries = PresetLibrary.readBank(folder: folder)
        let changed = bankChangedAfterLogicLaunch(plugin: plugin)
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
        let channel: Int
        switch InputValidation.int(params, keys: ["channel"], default: 1, range: 1...16, label: "channel") {
        case .success(let value): channel = value
        case .failure(let message): return error(message)
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

        // (b-c) Select the track with read-back and require the plug-in as instrument.
        let prepared = await router.route(
            operation: "sound.prepare_instrument",
            params: ["track_index": String(track ?? -1), "plugin": plugin]
        )
        guard prepared.isSuccess else {
            return error("Nothing was sent. \(prepared.message)")
        }
        trace.append(prepared.message)

        // (d) The header name before.
        let selectedIndex = AXLogicProElements.selectedTrackIndex()
        let nameBefore = AXLogicProElements.selectedTrackName()

        // (e) Bank Select MSB 0, then the Program Change.
        let midiChannel = String(channel - 1)
        let bankSelect = await router.route(
            operation: "midi.send_cc",
            params: ["controller": "0", "value": "0", "channel": midiChannel]
        )
        guard bankSelect.isSuccess else {
            return error("Bank Select could not be sent: \(bankSelect.message). Trace: \(trace.joined(separator: "; "))")
        }
        _ = try? await Task.sleep(for: .milliseconds(60))
        let programChange = await router.route(
            operation: "midi.send_program_change",
            params: ["program": String(entry.program), "channel": midiChannel]
        )
        guard programChange.isSuccess else {
            return error("Program Change could not be sent: \(programChange.message). Trace: \(trace.joined(separator: "; "))")
        }
        trace.append("sent Bank Select CC 0 = 0 and Program Change \(entry.program) on channel \(channel)")

        // (f) Wait, then read the header name again.
        _ = try? await Task.sleep(for: .milliseconds(600))
        let nameAfter: String?
        if let selectedIndex {
            nameAfter = AXLogicProElements.trackHeaderName(index: selectedIndex)
        } else {
            nameAfter = AXLogicProElements.selectedTrackName()
        }
        let verified = nameAfter.map { $0.lowercased().contains(entry.name.lowercased()) } ?? false

        var message: String
        if verified {
            message = "Program Change \(entry.program) sent; the track is now named '\(nameAfter ?? "")' (preset '\(entry.name)')."
        } else {
            message = "Bank Select and Program Change \(entry.program) ('\(entry.name)') were sent, but the plug-in display cannot be read through Accessibility, so the preset is not verified (track name: '\(nameAfter ?? "?")'). Listen to confirm."
        }
        if changedAfterLaunch {
            message += " Warning: \(restartWarning)"
        }
        return json(.object([
            "ok": .bool(true),
            "program": .int(entry.program),
            "preset": .string(entry.name),
            "track": selectedIndex.map { Value.int($0) } ?? Value.null,
            "track_name_before": nameBefore.map { Value.string($0) } ?? Value.null,
            "track_name_after": nameAfter.map { Value.string($0) } ?? Value.null,
            "verified": .bool(verified),
            "restart_hint": .bool(changedAfterLaunch),
            "message": .string(message),
            "trace": .array(trace.map { Value.string($0) }),
        ]))
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
