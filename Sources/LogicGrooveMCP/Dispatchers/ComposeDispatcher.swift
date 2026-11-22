import Foundation
import MCP
import MusicCore

struct ComposeDispatcher {
    static let tool = Tool(
        name: "logic_compose",
        description: """
            Generate, analyze and import MIDI for house, deep house and dub techno. \
            Writes .mid files to ~/Music/LogicGrooveMCP/Generated and imports them through \
            Logic's File > Import > MIDI File menu (no pixel clicking). \
            Commands: styles, generate, write, analyze_region, analyze_file, complement, \
            import_midi, set_loop. \
            Params by command: \
            styles -> { genre?: String, part?: String }; \
            generate -> { genre: "house"|"deep_house"|"dub_techno", \
            part: "drums"|"kick"|"hats"|"bass"|"stabs"|"chords"|"pad", key?: String, scale?: String, \
            bars?: Int (1-64, default 4), style?: String, density?: Float (0-1, default 0.5), \
            swing?: Float (0-1), humanize?: Float (0-1, default 0.2), octave?: Int, seed?: Int \
            (random if omitted, always echoed back), name?: String, import?: Bool (default true), \
            at_bar?: Int (default 1), loop?: Bool (default false), tempo?: Float (written to the file only if given) }; \
            write -> free-form clip from exact notes, chords and step patterns: \
            { name?, bars?: Int (1-256, derived from content if omitted), pattern_bars?: Int (1-64, notes and chords \
            describe this many bars and are tiled to fill bars), grid?: Int (steps per bar: 4, 8, 12, 16, 24, 32, 48; default 16), \
            channel?: Int (1-16), transpose?: Int (semitones, not applied to drum names), swing?: Float (0-1), \
            humanize?: Float (0-1), seed?: Int, \
            notes?: [{ pos|step, pitch, len?, vel? }], \
            chords?: [{ pos|step, chord|pitches, octave?: Int (-1..6, default 2), \
            voicing?: "close"|"dub"|"spread"|"shell"|"rootless", inversion?: Int (0-4), strum?: Int (ticks), len?, vel?, vel_top? }], \
            steps?: { lane: pattern | { pattern, vel?, len? } }, \
            kit?: "gm"|"ultrabeat_init" (drum name map; default gm), program?: Int (0-127, Program Change at the clip start), \
            cc?: [{ cc: Int (0-127, 1 = mod wheel), points: [{ pos|step, value: Int 0-127 }] (2-512, any order), \
            curve?: "linear"|"step", resolution?: Float (16ths between events, 0.25-4, default 0.5) }] (max 16 lanes, over the whole clip), \
            import?: Bool (default true), at_bar?: Int (default 1), loop?: Bool (default false), track?: Int, tempo?: Float }. \
            Syntax: pos is "bar.beat.16th" (1-based, e.g. "2.3.3"; optional 4th field = extra ticks; "bar.beat" and "bar" also work), \
            step is a 0-based index in grid steps (fractions allowed); pitch is a MIDI number, a note name in Logic octaves \
            (C3 = 60, "F1", "Bb2") or a drum name (kick, snare, clap, closed_hat, open_hat, rim, shaker, ...); \
            len is in 16ths (0.5, 6) or "1/8", "1/8." (dotted), "1/8t" (triplet), "2bars"; vel 1-127; \
            chord is a symbol such as "Fm9", "Bbmaj7", "C7#9", "Fm7/C" (slash = bass note one octave below the root octave); \
            steps lane keys are drum names, note names or MIDI numbers, pattern chars: x hit, X accent, o soft, g ghost, \
            . or - rest, _ tie (extends the previous hit); spaces and | are ignored and the pattern repeats to fill bars. \
            kit "ultrabeat_init" maps drum names to Ultrabeat's init kit (kick 37, snare 38, closed_hat 39, open_hat 40, tom 41, \
            clap 42, perc/rim 43, shaker 44; ride and crash are an error); example { "kit": "ultrabeat_init", "steps": { "kick": "x...x..." } }. \
            program example { "program": 12, "notes": [...] }. cc example for a filter sweep (many Diva presets map CC 1 to cutoff): \
            { "cc": [{ "cc": 1, "points": [{ "pos": "1.1.1", "value": 20 }, { "pos": "5.1.1", "value": 110 }] }], "notes": [...] }. \
            track (generate, write, complement, import_midi) puts the imported clip on an EXISTING track (0-based, same indexing as \
            logic_system state) instead of the new track every import creates: cut, delete the empty new track, select the target \
            (read back), go to at_bar, paste; a region already there is replaced where they overlap. \
            The result lists warnings (dropped, shortened or trimmed notes), the note range and an analysis (key, chords) to sanity-check. \
            analyze_region -> {} (exports the selected MIDI region, then analyzes it); \
            analyze_file -> { path: String }; \
            complement -> same params as generate; analyzes the selected region first and generates a part that fits it; \
            import_midi -> { path: String, at_bar?: Int, loop?: Bool, track?: Int }; \
            set_loop -> { enabled: Bool } (Region inspector Loop checkbox). \
            Results include undo_label (the Edit menu's Undo title) so you can verify what Logic did.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Compose command to execute"),
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
        case "styles":
            return stylesResult(params: params)

        case "generate":
            return await generateResult(params: params, router: router, complement: false)

        case "complement":
            return await generateResult(params: params, router: router, complement: true)

        case "write":
            return await writeResult(params: params, router: router)

        case "analyze_region":
            switch await exportAndAnalyze(router: router) {
            case .success(let region):
                return json(analysisValue(region.analysis, path: region.path))
            case .failure(let message):
                return error(message)
            }

        case "analyze_file":
            let path: String
            switch ComposeSupport.validateMIDIPath(params["path"]?.stringValue ?? "") {
            case .success(let value): path = value
            case .failure(let message): return error(message)
            }
            switch analyzeFile(path: path) {
            case .success(let region):
                return json(analysisValue(region.analysis, path: region.path))
            case .failure(let message):
                return error(message)
            }

        case "import_midi":
            let path: String
            let atBar: Int?
            switch ComposeSupport.validateMIDIPath(params["path"]?.stringValue ?? "") {
            case .success(let value): path = value
            case .failure(let message): return error(message)
            }
            if params["at_bar"] != nil {
                switch InputValidation.int(params, keys: ["at_bar"], range: 1...100_000, label: "at_bar") {
                case .success(let value): atBar = value
                case .failure(let message): return error(message)
                }
            } else {
                atBar = nil
            }
            let loop = boolParam(params, "loop", default: false)
            let track: Int?
            do {
                track = try parseTrack(params)
            } catch let failure as ParamError {
                return error(failure.message)
            } catch {
                return Self.error("Invalid parameters")
            }
            let outcome = await performImport(path: path, atBar: atBar, loop: loop, track: track, router: router)
            return json(
                .object(["path": .string(path), "import": outcome.value]),
                isError: !outcome.ok
            )

        case "set_loop":
            let enabled = boolParam(params, "enabled", default: true)
            let result = await router.route(
                operation: "region.set_loop",
                params: ["enabled": enabled ? "true" : "false"]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return error("Unknown compose command: \(command). Available: styles, generate, write, analyze_region, analyze_file, complement, import_midi, set_loop")
        }
    }

    // MARK: - Parameter parsing

    private struct ParamError: Error {
        let message: String
    }

    private static func unwrap<T>(_ validation: Validation<T>) throws -> T {
        switch validation {
        case .success(let value): return value
        case .failure(let message): throw ParamError(message: message)
        }
    }

    private static func boolParam(_ params: [String: Value], _ key: String, default defaultValue: Bool) -> Bool {
        if let value = params[key]?.boolValue { return value }
        if let text = params[key]?.stringValue {
            let lowered = text.lowercased()
            if lowered == "true" || lowered == "1" || lowered == "yes" { return true }
            if lowered == "false" || lowered == "0" || lowered == "no" { return false }
        }
        return defaultValue
    }

    /// Optional 0-based target track.
    private static func parseTrack(_ params: [String: Value]) throws -> Int? {
        guard isSupplied(params, "track") else { return nil }
        return try unwrap(InputValidation.int(params, keys: ["track"], range: 0...10_000, label: "track"))
    }

    private static func isSupplied(_ params: [String: Value], _ key: String) -> Bool {
        guard let value = params[key] else { return false }
        if case .null = value { return false }
        return true
    }

    private static func optionalString(_ params: [String: Value], _ key: String, maxLength: Int) throws -> String? {
        guard isSupplied(params, key) else { return nil }
        let value: String = try unwrap(
            InputValidation.string(params, keys: [key], maxLength: maxLength, label: key)
        )
        return value
    }

    private static func normalizedEnumText(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func parseGenre(_ params: [String: Value]) throws -> Genre {
        let valid = Genre.allCases.map { $0.rawValue }.joined(separator: ", ")
        guard let raw = params["genre"]?.stringValue else {
            throw ParamError(message: "genre is required. Valid genres: \(valid)")
        }
        guard let genre = Genre(rawValue: normalizedEnumText(raw)) else {
            throw ParamError(message: "Unknown genre '\(raw)'. Valid genres: \(valid)")
        }
        return genre
    }

    private static func parsePart(_ params: [String: Value]) throws -> Part {
        let valid = Part.allCases.map { $0.rawValue }.joined(separator: ", ")
        guard let raw = params["part"]?.stringValue else {
            throw ParamError(message: "part is required. Valid parts: \(valid)")
        }
        guard let part = Part(rawValue: normalizedEnumText(raw)) else {
            throw ParamError(message: "Unknown part '\(raw)'. Valid parts: \(valid)")
        }
        return part
    }

    private static func buildRequest(_ params: [String: Value]) throws -> GenerationRequest {
        let genre = try parseGenre(params)
        let part = try parsePart(params)

        var key: String?
        if let rawKey = try optionalString(params, "key", maxLength: 8) {
            guard NoteName.pitchClass(rawKey) != nil else {
                throw ParamError(message: "Invalid key '\(rawKey)'. Use a note name such as F, A#, Db")
            }
            key = rawKey
        }

        var scale: String?
        if let rawScale = try optionalString(params, "scale", maxLength: 40) {
            guard Scale.named(rawScale) != nil else {
                let valid = Scale.all.map { $0.name }.joined(separator: ", ")
                throw ParamError(message: "Unknown scale '\(rawScale)'. Valid scales: \(valid)")
            }
            scale = rawScale
        }

        let bars: Int = try unwrap(
            InputValidation.int(params, keys: ["bars"], default: 4, range: 1...64, label: "bars")
        )

        var style: String?
        if let rawStyle = try optionalString(params, "style", maxLength: 60) {
            let available = Generator.styles(genre: genre, part: part).map { $0.name }
            if !available.isEmpty {
                guard let match = available.first(where: { $0.lowercased() == rawStyle.lowercased() }) else {
                    throw ParamError(
                        message: "Unknown style '\(rawStyle)' for \(genre.rawValue)/\(part.rawValue). Valid styles: \(available.joined(separator: ", "))"
                    )
                }
                style = match
            } else {
                style = rawStyle
            }
        }

        let density: Double = try unwrap(
            InputValidation.double(params, keys: ["density"], default: 0.5, range: 0...1, label: "density")
        )
        let swing: Double = try unwrap(
            InputValidation.double(params, keys: ["swing"], default: 0, range: 0...1, label: "swing")
        )
        let humanize: Double = try unwrap(
            InputValidation.double(params, keys: ["humanize"], default: 0.2, range: 0...1, label: "humanize")
        )

        var octave: Int?
        if isSupplied(params, "octave") {
            octave = try unwrap(
                InputValidation.int(params, keys: ["octave"], range: -2...8, label: "octave")
            )
        }

        // JSON-safe integer range so the seed round-trips through the client.
        let maxSeed = 9_007_199_254_740_991
        let seed: UInt64
        if isSupplied(params, "seed") {
            let value: Int = try unwrap(
                InputValidation.int(params, keys: ["seed"], range: 0...maxSeed, label: "seed")
            )
            seed = UInt64(value)
        } else {
            seed = UInt64.random(in: 1...UInt64(maxSeed))
        }

        return GenerationRequest(
            genre: genre, part: part, key: key, scale: scale, bars: bars,
            style: style, density: density, swing: swing, humanize: humanize,
            octave: octave, seed: seed
        )
    }

    // MARK: - styles

    private static func stylesResult(params: [String: Value]) -> CallTool.Result {
        let genres: [Genre]
        let parts: [Part]
        do {
            if isSupplied(params, "genre") {
                genres = [try parseGenre(params)]
            } else {
                genres = Genre.allCases
            }
            if isSupplied(params, "part") {
                parts = [try parsePart(params)]
            } else {
                parts = Part.allCases
            }
        } catch let failure as ParamError {
            return error(failure.message)
        } catch {
            return Self.error("Invalid parameters")
        }

        var combos: [Value] = []
        for genre in genres {
            for part in parts {
                let styles: [Value] = Generator.styles(genre: genre, part: part).map { info in
                    Value.object([
                        "name": Value.string(info.name),
                        "description": Value.string(info.description),
                    ])
                }
                combos.append(.object([
                    "genre": .string(genre.rawValue),
                    "part": .string(part.rawValue),
                    "styles": .array(styles),
                ]))
            }
        }
        return json(.object([
            "genres": .array(Genre.allCases.map { Value.string($0.rawValue) }),
            "parts": .array(Part.allCases.map { Value.string($0.rawValue) }),
            "styles": .array(combos),
        ]))
    }

    // MARK: - generate / complement

    private static func generateResult(
        params: [String: Value],
        router: ChannelRouter,
        complement: Bool
    ) async -> CallTool.Result {
        let request: GenerationRequest
        let customName: String?
        let tempo: Double?
        let atBar: Int
        let track: Int?
        do {
            track = try parseTrack(params)
            request = try buildRequest(params)
            customName = try optionalString(params, "name", maxLength: 80)
            if isSupplied(params, "tempo") {
                tempo = try unwrap(
                    InputValidation.double(params, keys: ["tempo"], range: 20...999, label: "tempo")
                )
            } else {
                tempo = nil
            }
            atBar = try unwrap(
                InputValidation.int(params, keys: ["at_bar"], default: 1, range: 1...100_000, label: "at_bar")
            )
        } catch let failure as ParamError {
            return error(failure.message)
        } catch {
            return Self.error("Invalid parameters")
        }
        let doImport = boolParam(params, "import", default: true)
        let loop = boolParam(params, "loop", default: false)

        var clip: Clip
        var analysisSummary: Value?
        if complement {
            switch await exportAndAnalyze(router: router) {
            case .success(let region):
                clip = Generator.complement(region.analysis, request: request)
                analysisSummary = analysisValue(region.analysis, path: region.path)
            case .failure(let message):
                return error(message)
            }
        } else {
            clip = Generator.generate(request)
        }
        if let customName {
            clip.name = customName
        }

        // Write the MIDI file.
        let directory = ComposeSupport.generatedDirectory()
        let baseName = ComposeSupport.sanitizeFileName(
            clip.name, fallback: "\(request.genre.rawValue)-\(request.part.rawValue)"
        )
        let fileURL = directory.appendingPathComponent("\(ComposeSupport.timestamp())-\(baseName).mid")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = MIDIFileIO.write(clip: clip, tempoBPM: tempo)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return Self.error("Failed to write \(fileURL.path): \(error.localizedDescription)")
        }
        Log.info("Generated \(clip.notes.count) notes -> \(fileURL.path)", subsystem: "compose")

        let defaults = Generator.resolvedDefaults(request)
        // 4/4 at 480 PPQ (the MusicCore time base).
        let ticksPerBar = 1_920
        let preview: [Value] = clip.notes
            .filter { $0.start < ticksPerBar }
            .prefix(48)
            .map { note in
                Value.object([
                    "pos": Value.string(ComposeSupport.positionString(tick: note.start)),
                    "note": Value.string(NoteName.name(note.pitch)),
                    "vel": Value.int(note.velocity),
                ])
            }

        var result: [String: Value] = [
            "path": .string(fileURL.path),
            "clip_name": .string(clip.name),
            "genre": .string(request.genre.rawValue),
            "part": .string(request.part.rawValue),
            "resolved": .object([
                "key": .string(defaults.key),
                "scale": .string(defaults.scale),
                "octave": .int(defaults.octave),
                "style": .string(defaults.style),
            ]),
            "seed": .int(Int(request.seed)),
            "bars": .int(request.bars),
            "note_count": .int(clip.notes.count),
            "preview_bar1": .array(preview),
            "tempo_written": tempo.map { Value.double($0) } ?? Value.null,
        ]
        if let analysisSummary {
            result["analysis"] = analysisSummary
        }

        var isFailure = false
        if doImport {
            let outcome = await performImport(path: fileURL.path, atBar: atBar, loop: loop, track: track, router: router)
            result["import"] = outcome.value
            if !outcome.ok { isFailure = true }
        } else {
            result["import"] = .string("skipped (import=false); use import_midi with the path to import it")
        }
        return json(.object(result), isError: isFailure)
    }

    // MARK: - write

    private static func writeResult(
        params: [String: Value],
        router: ChannelRouter
    ) async -> CallTool.Result {
        let seed: UInt64
        let tempo: Double?
        let atBar: Int
        let track: Int?
        do {
            track = try parseTrack(params)
            // JSON-safe integer range so the seed round-trips through the client.
            let maxSeed = 9_007_199_254_740_991
            if isSupplied(params, "seed") {
                let value: Int = try unwrap(
                    InputValidation.int(params, keys: ["seed"], range: 0...maxSeed, label: "seed")
                )
                seed = UInt64(value)
            } else {
                seed = UInt64.random(in: 1...UInt64(maxSeed))
            }
            if isSupplied(params, "tempo") {
                tempo = try unwrap(
                    InputValidation.double(params, keys: ["tempo"], range: 20...999, label: "tempo")
                )
            } else {
                tempo = nil
            }
            atBar = try unwrap(
                InputValidation.int(params, keys: ["at_bar"], default: 1, range: 1...100_000, label: "at_bar")
            )
        } catch let failure as ParamError {
            return error(failure.message)
        } catch {
            return Self.error("Invalid parameters")
        }
        let doImport = boolParam(params, "import", default: true)
        let loop = boolParam(params, "loop", default: false)

        // The tool params are the clip spec; ClipWriter ignores keys it does not know (import, at_bar, ...).
        let specData = Data(encodeJSON(Value.object(params)).utf8)
        let written: WrittenClip
        do {
            written = try ClipWriter.write(json: specData, seed: seed)
        } catch let failure as ClipWriterError {
            return error(failure.message)
        } catch {
            return Self.error("Invalid clip spec: \(error.localizedDescription)")
        }
        let clip = written.clip

        // Write the MIDI file.
        let directory = ComposeSupport.generatedDirectory()
        let baseName = ComposeSupport.sanitizeFileName(clip.name, fallback: "written-clip")
        let fileURL = directory.appendingPathComponent("\(ComposeSupport.timestamp())-\(baseName).mid")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = MIDIFileIO.write(clip: clip, tempoBPM: tempo)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return Self.error("Failed to write \(fileURL.path): \(error.localizedDescription)")
        }
        Log.info("Wrote \(clip.notes.count) notes -> \(fileURL.path)", subsystem: "compose")

        // 4/4 at 480 PPQ (the MusicCore time base).
        let ticksPerBar = 1_920
        let preview: [Value] = clip.notes
            .filter { $0.start < ticksPerBar }
            .prefix(48)
            .map { note in
                Value.object([
                    "pos": Value.string(ComposeSupport.positionString(tick: note.start)),
                    "note": Value.string(NoteName.name(note.pitch)),
                    "vel": Value.int(note.velocity),
                ])
            }
        let lowest = clip.notes.map { $0.pitch }.min() ?? 0
        let highest = clip.notes.map { $0.pitch }.max() ?? 0
        let warningValues: [Value] = written.warnings.map { Value.string($0) }

        var result: [String: Value] = [
            "path": .string(fileURL.path),
            "clip_name": .string(clip.name),
            "bars": .int(clip.lengthTicks / ticksPerBar),
            "note_count": .int(clip.notes.count),
            "seed": .int(Int(seed)),
            "range": .object([
                "lowest": .string(NoteName.name(lowest)),
                "highest": .string(NoteName.name(highest)),
            ]),
            "preview_bar1": .array(preview),
            "warnings": .array(warningValues),
            "cc_event_count": .int(clip.controls.count),
            "program": clip.program.map { Value.int($0) } ?? Value.null,
            "tempo_written": tempo.map { Value.double($0) } ?? Value.null,
        ]
        result["analysis"] = analysisValue(Analyzer.analyze(clip), path: fileURL.path)

        var isFailure = false
        if doImport {
            let outcome = await performImport(path: fileURL.path, atBar: atBar, loop: loop, track: track, router: router)
            result["import"] = outcome.value
            if !outcome.ok { isFailure = true }
        } else {
            result["import"] = .string("skipped (import=false); use import_midi with the path to import it")
        }
        return json(.object(result), isError: isFailure)
    }

    // MARK: - Import

    /// Move the playhead, import the file, optionally put the region on an existing track, optionally
    /// enable Loop on the region.
    private static func performImport(
        path: String,
        atBar: Int?,
        loop: Bool,
        track: Int? = nil,
        router: ChannelRouter
    ) async -> (ok: Bool, value: Value) {
        var steps: [String: Value] = [:]

        // The new track an import creates has index == the track count before the import.
        let tracksBefore = AXLogicProElements.trackHeaderCount()
        if let track {
            guard tracksBefore > 0 else {
                steps["place"] = stepValue(.error("Cannot read the track list (0 track headers); nothing was imported. Open the project window and retry"))
                return (false, .object(steps))
            }
            guard track < tracksBefore else {
                steps["place"] = stepValue(.error("track \(track) does not exist (the project has \(tracksBefore) tracks, indexes 0-\(tracksBefore - 1)); nothing was imported"))
                return (false, .object(steps))
            }
        }

        if let atBar {
            let nav = await router.route(
                operation: "transport.goto_position",
                params: ["position": "\(atBar).1.1.1"]
            )
            steps["goto_bar"] = stepValue(nav)
            if !nav.isSuccess {
                return (false, .object(steps))
            }
            await pause(400)
        }

        var importParams = ["path": path]
        if let atBar {
            importParams["at_bar"] = String(atBar)
        }
        let imported = await router.route(operation: "midi.import_file", params: importParams)
        steps["import"] = stepValue(imported)
        if !imported.isSuccess {
            return (false, .object(steps))
        }

        if let track {
            let bar = atBar ?? 1
            var place: [String: Value] = [:]
            func placeResult(_ ok: Bool, _ message: String) -> (ok: Bool, value: Value) {
                place["ok"] = .bool(ok)
                place["status"] = .string(ok ? "unverified" : "error")
                place["message"] = .string(message)
                steps["place"] = .object(place)
                return (ok, .object(steps))
            }
            await pause(300)
            let moved = await router.route(
                operation: "region.move_selected_to_track",
                params: ["new_index": String(tracksBefore), "track": String(track)]
            )
            place["cut_and_select"] = stepValue(moved)
            guard moved.isSuccess else {
                return placeResult(false, "The region stays on the new track \(tracksBefore) (or is on the clipboard): \(moved.message)")
            }
            let nav = await router.route(
                operation: "transport.goto_position",
                params: ["position": "\(bar).1.1.1"]
            )
            place["goto_bar"] = stepValue(nav)
            guard nav.isSuccess else {
                return placeResult(false, "The region is on the clipboard and was NOT pasted: could not move the playhead to bar \(bar): \(nav.message)")
            }
            await pause(300)
            let pasted = await router.route(
                operation: "region.paste_on_track",
                params: ["track": String(track), "bar": String(bar)]
            )
            place["paste"] = stepValue(pasted)
            guard pasted.isSuccess else {
                return placeResult(false, pasted.message)
            }
            _ = placeResult(true, pasted.message)
        }

        if loop {
            await pause(300)
            let looped = await router.route(operation: "region.set_loop", params: ["enabled": "true"])
            steps["loop"] = stepValue(looped)
        }

        await pause(300)
        steps["undo_label"] = undoLabel()
        return (true, .object(steps))
    }

    private static func stepValue(_ result: ChannelResult) -> Value {
        let status: String
        switch result {
        case .success: status = "success"
        case .unverified: status = "unverified"
        case .error: status = "error"
        }
        return .object([
            "ok": .bool(result.isSuccess),
            "status": .string(status),
            "message": .string(result.message),
        ])
    }

    private static func undoLabel() -> Value {
        if let title = AXLogicProElements.undoMenuTitle() {
            return .string(title)
        }
        return .null
    }

    private static func pause(_ ms: Int) async {
        _ = try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Analysis

    private struct RegionAnalysis {
        let analysis: ClipAnalysis
        let path: String
    }

    private static func exportAndAnalyze(router: ChannelRouter) async -> Validation<RegionAnalysis> {
        let exported = await router.route(operation: "region.export_selected_midi")
        guard exported.isSuccess else {
            return .failure(exported.message)
        }
        let path: String
        switch ComposeSupport.validateMIDIPath(exported.message) {
        case .success(let value): path = value
        case .failure(let message):
            return .failure("Export reported '\(exported.message)' but it is not a usable .mid path: \(message)")
        }
        return analyzeFile(path: path)
    }

    private static func analyzeFile(path: String) -> Validation<RegionAnalysis> {
        let contents: MIDIFileContents
        do {
            contents = try MIDIFileIO.read(url: URL(fileURLWithPath: path))
        } catch {
            return .failure("Cannot read MIDI file \(path): \(error)")
        }
        let noteTotal = contents.clips.reduce(0) { $0 + $1.notes.count }
        guard noteTotal > 0 else {
            return .failure("The MIDI file contains no notes: \(path)")
        }
        return .success(RegionAnalysis(analysis: Analyzer.analyze(contents.clips), path: path))
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func analysisValue(_ analysis: ClipAnalysis, path: String) -> Value {
        let chords: [Value] = analysis.chords.map { chord in
            Value.object([
                "name": Value.string(chord.name),
                "pitches": Value.array(chord.pitches.map { Value.string(NoteName.name($0)) }),
                "occurrences": Value.int(chord.occurrences),
            ])
        }
        let onsets: [Value] = analysis.mainOnsetSteps.map { step in
            Value.string(ComposeSupport.positionString(step16: step))
        }
        return .object([
            "path": .string(path),
            "key": .string(analysis.keyName),
            "key_confidence": .double(round2(analysis.keyConfidence)),
            "chords": .array(chords),
            "main_onsets": .array(onsets),
            "range": .object([
                "lowest": .string(NoteName.name(analysis.lowestPitch)),
                "highest": .string(NoteName.name(analysis.highestPitch)),
            ]),
            "length_bars": .double(round2(analysis.lengthBars)),
            "note_count": .int(analysis.noteCount),
        ])
    }

    // MARK: - Results

    private static func json(_ value: Value, isError: Bool = false) -> CallTool.Result {
        CallTool.Result(content: [.text(encodeJSON(value))], isError: isError)
    }

    private static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }
}
