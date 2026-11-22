import Foundation
import MCP

private struct LiveState: Encodable {
    let track_header_count: Int
    let undo_title: String?
    let file_panel_open: Bool
    let windows: [String]

    /// Hand-written so that a missing undo title is encoded as null, not omitted.
    func encode(to encoder: Encoder) throws {
        enum Keys: String, CodingKey {
            case track_header_count, undo_title, file_panel_open, windows
        }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(track_header_count, forKey: .track_header_count)
        try container.encode(undo_title, forKey: .undo_title)
        try container.encode(file_panel_open, forKey: .file_panel_open)
        try container.encode(windows, forKey: .windows)
    }
}

private struct StateReport: Encodable {
    let project: ProjectInfo
    let transport: TransportState
    let tracks: [TrackState]
    let regions: [RegionState]
    let live: LiveState
}

struct SystemDispatcher {
    static let tool = Tool(
        name: "logic_system",
        description: """
            Diagnostics and help for the Logic Groove MCP server. \
            Commands: health, permissions, refresh_cache, debug_windows, debug_panel, debug_strip, debug_focus, state, help. \
            Params by command: \
            help -> { category: String } (returns full param docs for a dispatcher); \
            refresh_cache -> {} (force AX re-poll); \
            state -> {} (JSON: project, transport, tracks, regions from the cache, plus live: \
            track_header_count, undo_title, file_panel_open, windows; use it to verify results); \
            debug_panel -> { window?: String (case-insensitive part of a window title: dump that window instead), \
            max_lines?: Int (50-1500, default 300) } (AX subtree dump of the open file panel, or of the focused window); \
            debug_strip -> { max_lines?: Int (50-1500, default 300) } (Inspector channel strip: selected track index, \
            plug-in slot candidates with frames and the AX subtree); \
            debug_focus -> {} (focused element and focused window); \
            Others -> {}
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("System command to execute"),
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
        case "health":
            let report = await router.healthReport()
            var entries: [[String: String]] = []
            for (id, health) in report.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                entries.append([
                    "channel": id.rawValue,
                    "available": String(health.available),
                    "latency_ms": health.latencyMs.map { String(format: "%.1f", $0) } ?? "N/A",
                    "detail": health.detail,
                ])
            }
            let snap = await cache.snapshot()
            let cacheInfo: [String: String] = [
                "poll_mode": snap.pollMode,
                "transport_age_sec": String(format: "%.1f", snap.transportAge),
                "track_count": String(snap.trackCount),
                "project": snap.projectName,
            ]
            // Manual JSON since mixed types
            let channelsJSON = encodeJSON(entries)
            let cacheJSON = encodeJSON(cacheInfo)
            let json = """
                {
                  "logic_pro_running": \(ProcessUtils.isLogicProRunning),
                  "channels": \(channelsJSON),
                  "cache": \(cacheJSON)
                }
                """
            return CallTool.Result(content: [.text(json)], isError: false)

        case "permissions":
            let status = PermissionChecker.check()
            return CallTool.Result(content: [.text(status.summary)], isError: false)

        case "debug_windows":
            let lines = AXLogicProElements.debugWindowSummary()
            return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)

        case "debug_panel":
            let maxLines = min(max(params["max_lines"]?.intValue ?? 300, 50), 1_500)
            let window = params["window"]?.stringValue
            return CallTool.Result(
                content: [.text(AXLogicProElements.debugPanelDump(maxLines: maxLines, windowTitle: window))],
                isError: false
            )

        case "debug_strip":
            let maxLines = min(max(params["max_lines"]?.intValue ?? 300, 50), 1_500)
            return CallTool.Result(content: [.text(AXLogicProElements.debugStripDump(maxLines: maxLines))], isError: false)

        case "debug_focus":
            let focus = AXLogicProElements.focusedFieldSummary() ?? "none"
            let text = "focused element: \(focus)\nfocused window: \(AXLogicProElements.focusedWindowSummary())"
            return CallTool.Result(content: [.text(text)], isError: false)

        case "state":
            let report = StateReport(
                project: await cache.getProject(),
                transport: await cache.getTransport(),
                tracks: await cache.getTracks(),
                regions: await cache.getRegions(),
                live: LiveState(
                    track_header_count: AXLogicProElements.trackHeaderCount(),
                    undo_title: AXLogicProElements.undoMenuTitle(),
                    file_panel_open: AXLogicProElements.strictFilePanel() != nil,
                    windows: AXLogicProElements.allWindows().map { AXHelpers.getTitle($0) ?? "" }
                )
            )
            return CallTool.Result(content: [.text(encodeJSON(report))], isError: false)

        case "refresh_cache":
            await cache.recordToolAccess()
            return CallTool.Result(
                content: [.text("State refresh triggered. Cache will be updated on next poll cycle.")],
                isError: false
            )

        case "help":
            let category = params["category"]?.stringValue ?? "all"
            let helpText = Self.helpText(for: category)
            return CallTool.Result(content: [.text(helpText)], isError: false)

        default:
            return CallTool.Result(
                content: [.text("Unknown system command: \(command). Available: health, permissions, refresh_cache, debug_windows, debug_panel, debug_strip, debug_focus, state, help")],
                isError: true
            )
        }
    }

    // MARK: - Help text

    private static func helpText(for category: String) -> String {
        switch category {
        case "transport":
            return """
                logic_transport commands:
                  play              -> {} — Start playback
                  stop              -> {} — Stop playback
                  record            -> {} — Start recording
                  pause             -> {} — Pause playback
                  rewind            -> {} — Rewind
                  fast_forward      -> {} — Fast forward
                  toggle_cycle      -> {} — Toggle cycle/loop mode
                  toggle_metronome  -> {} — Toggle metronome
                  toggle_count_in   -> {} — Toggle count-in
                  set_tempo         -> { tempo: Float } — Set BPM (20-999)
                  goto_position     -> { bar: Int } or { time: "HH:MM:SS:FF" }
                  set_cycle_range   -> not implemented (returns an error pointing to cycle_to_regions)
                  cycle_to_regions  -> {} — Select all regions, then set the cycle to them and enable it
                                       (Navigate > Set Rounded Locators by Selection and Enable Cycle)

                Read state via resource: logic://transport/state
                """

        case "tracks":
            return """
                logic_tracks commands:
                  select            -> { index: Int } or { name: String }
                  create_audio      -> {} — New audio track
                  create_instrument -> {} — New software instrument track
                  create_drummer    -> {} — New Drummer track
                  create_external_midi -> {} — New external MIDI track
                  delete            -> { index: Int }
                  duplicate         -> { index: Int }
                  rename            -> { index: Int, name: String }
                  mute              -> { index: Int, enabled: Bool }
                  solo              -> { index: Int, enabled: Bool }
                  arm               -> { index: Int, enabled: Bool }
                  set_color         -> { index: Int, color: Int } (0-24)

                Read state via resources: logic://tracks, logic://tracks/{index}
                """

        case "mixer":
            return """
                logic_mixer commands:
                  strip             -> { track?: Int } — JSON of the channel strip (instrument and effects
                                       top to bottom with bypass state, volume text, peak text, clipping,
                                       Stereo Out volume and peak). Use it to see levels.
                  set_volume        -> { track?: Int, db: Float (-60..6) } — fader searched until the
                                       read-back is within 0.15 dB (success within 0.3 dB);
                                       old form: { track: Int, value: Float } (0.0-1.0)
                  set_pan           -> { track: Int, value: Float } (-1.0 to 1.0)
                  set_send          -> { track: Int, bus: Int, value: Float }
                  set_output        -> { track: Int, output: String }
                  set_input         -> { track: Int, input: String }
                  set_master_volume -> { db: Float (-60..6) } (Stereo Out of the Inspector)
                                       or old form { value: Float }
                  toggle_eq         -> { track: Int }
                  reset_strip       -> { track: Int }
                  insert_plugin     -> { track?: Int (0-based), slot?: "instrument" / 0 = instrument,
                                       "new" / "add" / "append" or omitted = ADD an effect in the empty
                                       slot, n >= 1 = REPLACE the n-th existing effect (top to bottom;
                                       n beyond the effect count means "new"), name: String,
                                       result_index? (default 1: Down presses in the search results),
                                       variant_index? (default 1: submenu entry, 1 = Stereo),
                                       close_window?: Bool }
                                       `track` is selected and read back first; if that fails nothing
                                       is changed. Keyboard-driven (type, Down, Right, Return),
                                       confirmed by the new plug-in window and by the strip structure.
                                       Message has `chain: <instrument> | <effects>` and a step trace;
                                       result includes undo_label.
                                       Example: { "track": 2, "slot": "instrument", "name": "Diva" }
                                       Example: { "track": 2, "name": "Tape Delay" } (adds an effect)
                                       Example: { "track": 2, "slot": 1, "name": "Tape Delay" } (replaces effect 1)
                  bypass_plugin     -> { track?: Int, plugin?: String (name substring) or slot?: Int
                                       (0 = instrument, n = n-th effect), bypassed: Bool } — pressed only
                                       when the state differs, read back

                Read state via resource: logic://mixer
                """

        case "midi":
            return """
                logic_midi commands:
                  send_note         -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }
                  send_chord        -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }
                  send_cc           -> { controller: Int, value: Int, channel: Int }
                  send_program_change -> { program: Int, channel: Int }
                  send_pitch_bend   -> { value: Int, channel: Int } (-8192 to 8191)
                  send_aftertouch   -> { value: Int, channel: Int }
                  send_sysex        -> { bytes: [Int] } or { data: String }
                  create_virtual_port -> { name: String }
                  mmc_play          -> {}
                  mmc_stop          -> {}
                  mmc_record        -> {}
                  mmc_locate        -> { time: "HH:MM:SS:FF" }

                Read ports via resource: logic://midi/ports
                """

        case "edit":
            return """
                logic_edit commands:
                  undo              -> {} — Undo last action
                  redo              -> {} — Redo last undone action
                  cut               -> {} — Cut selection
                  copy              -> {} — Copy selection
                  paste             -> {} — Paste at playhead
                  delete            -> {} — Delete selection
                  select_all        -> {} — Select all
                  split             -> {} — Split at playhead
                  join              -> {} — Join selected regions
                  quantize          -> { value: String } ("1/4", "1/8", "1/16")
                  bounce_in_place   -> {} — Bounce selection to audio
                  normalize         -> {} — Normalize audio
                  duplicate         -> {} — Duplicate selection
                  last_undo         -> {} — Read the Edit menu's Undo title (presses nothing)
                """

        case "navigate":
            return """
                logic_navigate commands:
                  goto_bar          -> { bar: Int }
                  goto_marker       -> { index: Int } or { name: String }
                  create_marker     -> { name: String }
                  delete_marker     -> { index: Int }
                  rename_marker     -> { index: Int, name: String }
                  zoom_to_fit       -> {}
                  set_zoom          -> { level: String } ("in", "out", "fit")
                  toggle_view       -> { view: String } (mixer, piano_roll, score,
                                       step_editor, library, inspector, automation)
                  refresh_editor    -> {} — Close + reopen the editor so it follows the selected region
                  open_piano_roll   -> {} — Window > Open Piano Roll
                """

        case "compose":
            return """
                logic_compose commands (house, deep_house, dub_techno):
                  styles            -> { genre?: String, part?: String } — Available styles
                  generate          -> { genre, part, key?, scale?, bars? (1-64, default 4), style?,
                                       density? (0-1), swing? (0-1), humanize? (0-1), octave?, seed?,
                                       name?, import? (default true), at_bar? (default 1),
                                       loop? (default false), tempo? }
                                       part: drums, kick, hats, bass, stabs, chords, pad.
                                       Seed is always echoed back so a clip can be reproduced.
                  write             -> free-form clip from exact notes, chords and step patterns
                                       { name?, bars? (1-256, derived if omitted),
                                         pattern_bars? (1-64; notes/chords are one pattern of this
                                         many bars, tiled to fill bars), grid? (steps per bar:
                                         4, 8, 12, 16, 24, 32, 48; default 16), channel? (1-16),
                                         transpose? (-48..48, not applied to drum names),
                                         swing? (0-1), humanize? (0-1), seed?,
                                         notes?: [{ pos|step, pitch, len?, vel? }],
                                         chords?: [{ pos|step, chord|pitches, octave? (-1..6,
                                           default 2), voicing? (close, dub, spread, shell,
                                           rootless), inversion? (0-4), strum? (ticks 0-120),
                                           len?, vel?, vel_top? }],
                                         steps?: { lane: pattern | { pattern, vel?, len? } },
                                         kit? ("gm" default | "ultrabeat_init"), program? (0-127),
                                         cc?: [{ cc, points: [{ pos|step, value }], curve?, resolution? }],
                                         import? (default true), at_bar? (default 1),
                                         loop? (default false), track? (0-based), tempo? }
                                       kit: "ultrabeat_init" maps drum names to Ultrabeat's init kit
                                         (C#1 kick 37, D1 snare 38, D#1 hats 39/40, F1 tom 41,
                                         F#1 clap 42, G1 perc 43, G#1 shaker 44); ride, ride_bell and
                                         crash have no voice there and are an error.
                                         Example: { "kit": "ultrabeat_init", "steps": { "kick": "x...x...", "hat": "..x...x." } }
                                       program: Program Change at the clip start (only useful once the
                                         instrument maps program changes). Example: { "program": 12, ... }
                                       cc: controller lanes over the whole clip (not tiled by pattern_bars).
                                         cc 0-127 (1 = mod wheel, many Diva presets map it to cutoff),
                                         points 2-512 with value 0-127 (any order), curve "linear" (default,
                                         an event every `resolution` 16ths, 0.25-4, default 0.5) or "step".
                                         Example: { "cc": [{ "cc": 1, "points": [{ "pos": "1.1.1", "value": 20 },
                                           { "pos": "5.1.1", "value": 110 }] }], ... }
                                       track: put the imported clip on this EXISTING track (0-based, same
                                         indexing as logic_system state) instead of the new track an import
                                         creates: cut, delete the empty new track, select the target (read
                                         back), go to at_bar, paste. A region already at that position on the
                                         target is replaced where they overlap. Works for write, generate,
                                         complement and import_midi. Example: { "track": 2, "at_bar": 5, ... }
                                       pos: "bar.beat.16th", 1-based ("2.3.3"); optional 4th field
                                         = extra ticks 0-119 ("1.1.3.60"); "bar.beat" and "bar" work.
                                       step: 0-based index in grid steps, fractions allowed (2.5).
                                       pitch: MIDI 0-127, note name in Logic octaves (C3 = 60,
                                         "F1", "Bb2") or drum name (kick, snare, clap, closed_hat,
                                         open_hat, rim, shaker, ride, crash, tamb, cowbell, ...).
                                       len: 16ths (0.5, 6) or "1/8", "1/8." dotted, "1/8t" triplet,
                                         "2bars". Default one 16th (steps: one grid step).
                                       vel: 1-127, default 100.
                                       chord: symbol such as Fm9, Bbmaj7, C7#9, m7b5, 7sus4,
                                         add9, 13; "Fm7/C" adds bass C one octave below the root
                                         octave. Or pitches: [41, "C2", "Eb3"] used as written.
                                       steps lane keys: drum name, note name or MIDI number.
                                         Pattern chars: x hit, X accent (+20), o soft (-30),
                                         g ghost (-55), . or - rest, _ tie (extends previous hit).
                                         Spaces and | are ignored; the pattern repeats to fill bars.
                                       Result: path, bars, note_count, seed, range, preview_bar1,
                                         warnings, analysis (key and chords: check it, you cannot hear).
                                       Example: { "pattern_bars": 1, "bars": 4,
                                         "chords": [{ "pos": "1.1.1", "chord": "Fm9", "voicing": "dub",
                                           "len": "1/16", "vel": 84 }],
                                         "steps": { "kick": "x...x...x...x...", "hh": "..x...x...x...x." } }
                  analyze_region    -> {} — Export the selected MIDI region and analyze it
                  analyze_file      -> { path: String } — Analyze an existing .mid file
                  complement        -> same params as generate; fits the selected region
                  import_midi       -> { path: String, at_bar?: Int, loop?: Bool, track?: Int }
                  set_loop          -> { enabled: Bool } — Region inspector Loop checkbox

                Verify results by reading logic_system state (track_header_count, undo_title).
                An import_midi result is an error unless its message says "verified".

                Files go to ~/Music/LogicGrooveMCP/Generated; region exports to
                ~/Music/LogicGrooveMCP/Exports. Import uses File > Import > MIDI File via
                Accessibility. Results include undo_label (the Edit menu's Undo title).
                """

        case "project":
            return """
                logic_project commands:
                  new               -> {} — Create new project
                  open              -> { path: String } — Open .logicx file
                  save              -> {} — Save current project
                  save_as           -> { path: String } — Save to new path
                  close             -> {} — Close project
                  bounce            -> {} — Open bounce dialog
                  launch            -> {} — Launch Logic Pro
                  quit              -> {} — Quit Logic Pro

                Read project info via resource: logic://project/info
                """

        case "system":
            return """
                logic_system commands:
                  health            -> {} — Channel status + cache info
                  permissions       -> {} — macOS permission status
                  refresh_cache     -> {} — Force AX re-poll
                  state             -> {} — JSON: project, transport, tracks, regions (cache) plus
                                       live { track_header_count, undo_title, file_panel_open, windows }
                  debug_windows     -> {} — Windows, buttons and whether a file panel is found
                  debug_panel       -> { window?: String, max_lines?: Int (50-1500) } — AX subtree dump of
                                       the open file panel, of the window whose title contains `window`,
                                       or of the focused window
                  debug_strip       -> { max_lines?: Int } — Inspector channel strip: selected track index,
                                       slot candidates with frames, subtree
                  debug_focus       -> {} — Focused element and focused window
                  help              -> { category: String } — Param docs per category

                Categories: transport, tracks, mixer, midi, edit, navigate, project, compose, system

                Read health via resource: logic://system/health
                Prefer `state` over resources: MCP resources are not reachable from every client.
                """

        default:
            return """
                Logic Groove MCP — 9 dispatcher tools + 7 resources

                Tools (actions):
                  logic_transport  — Transport control (play, stop, record, tempo...)
                  logic_tracks     — Track management (create, mute, solo, arm...)
                  logic_mixer      — Mixer control (volume, pan, plugins...)
                  logic_midi       — MIDI operations (notes, CC, MMC...)
                  logic_edit       — Editing (undo, cut, quantize...)
                  logic_navigate   — Navigation + views (markers, zoom, toggle views...)
                  logic_project    — Project lifecycle (open, save, bounce...)
                  logic_compose    — Generate/analyze/import MIDI (house, deep house, dub techno)
                  logic_system     — Diagnostics + help

                Resources (reads — zero tool cost):
                  logic://transport/state  — Transport state
                  logic://tracks           — All tracks
                  logic://tracks/{index}   — Single track detail
                  logic://mixer            — Mixer state
                  logic://project/info     — Project info
                  logic://midi/ports       — MIDI ports
                  logic://system/health    — System health

                Use: logic_system(command: "help", params: {category: "transport"})
                for detailed command docs per category.
                """
        }
    }
}
