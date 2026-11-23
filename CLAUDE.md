# CLAUDE.md - Logic Groove MCP

## Purpose

MCP server (Swift, macOS) that lets AI assistants drive Logic Pro and write electronic music parts (house, deep house, dub techno). Fork of koltyj/logic-pro-mcp (MIT, Kolton Jacobs), renamed and extended by Golden Lobster Studio (Sorin Gheorghita). Repo: https://github.com/goldenlobster2019-bit/logic-groove-mcp. Version 0.4.2.

## Structure

- `Package.swift` - MusicCore + its tests always; server target `LogicGrooveMCP` and `LogicGrooveMCPTests` only under `#if os(macOS)`.
- `Sources/MusicCore/` - pure Swift (Foundation only), Linux-tested.
  - `Types.swift` - ppq (480), NoteEvent, ControlEvent, Clip (notes plus optional `program` and `controls`), Genre, Part, GenerationRequest, ClipAnalysis, SeededRandom, DrumNote map.
  - `Theory.swift` - note names, scales, chord building, chord naming.
  - `MIDIFileIO.swift` - Standard MIDI File reader/writer (tempo meta only when passed; Program Change and controller events written and read back).
  - `Analyzer.swift` - key, chord and onset-grid analysis of a Clip.
  - `PresetLibrary.swift` - u-he preset library (`*.h2p`): meta parser, recursive scan, search, resolve, the `MIDI Programs` bank (read, install with an ownership manifest, program lookup). FileManager only, tested with temp folders.
  - `ClipTrim.swift` - `Clip.leadingEmptyBars`, `trimmingLeadingEmptyBars()`, `MIDIFileContents.leadingEmptyBars`.
  - `ClipWriter.swift` - free-form clip builder for `logic_compose write`: JSON spec (notes, chords, step patterns, `kit`, `program`, `cc` lanes) to a Clip; chord symbol parser, voicings, drum name tables (gm, ultrabeat_init), swing/humanize, warnings.
  - `Generators/Generator.swift` - public API (generate, complement, styles), request resolution, style catalogue.
  - `Generators/DubTechno.swift`, `House.swift` - per genre/part pattern builders (house and deep_house share House.swift).
  - `Generators/Groove.swift` - swing, humanize, interlock with stab onsets, finalize.
- `Sources/LogicGrooveMCP/` - macOS-only server.
  - `main.swift` - entry, `--check-permissions`.
  - `Server/` - `LogicProServer.swift` (tool/resource registration, class name kept from upstream), `ServerConfig.swift` (name, ports, timeouts, MIDI port names).
  - `Dispatchers/` - one file per MCP tool (transport, tracks, mixer, midi, edit, navigate, project, compose, sounds, system). `SoundDispatcher.swift` = `logic_sounds`.
  - `Channels/` - `Channel.swift` (protocol, ChannelID, ChannelResult), `ChannelRouter.swift` (routing table), CoreMIDI, Accessibility (+Compose: import/export, verified track selection, plug-in insert; +Placement: region move to an existing track, cycle to regions), CGEvent, AppleScript, OSC channels, `FilePanelAutomation.swift` (open/save panel driving).
  - `Accessibility/` - AX wrappers; `AXLogicProElements+Compose.swift` holds menu/panel/inspector/plugin finders; `AXLogicProElements+Tracks.swift` holds selection read-back, focus, window-set and strip diagnostics; `AXLogicProElements+Strip.swift` holds the structural strip reader (model, slot press, bypass, faders); `AXLogicProElements+ImportPanel.swift` holds the "Where:" / browser readers; `Channels/AccessibilityChannel+Strip.swift` holds strip, bypass and dB volume commands. `Channels/AccessibilityChannel+Tracks.swift` holds the verified mute/solo/rename/delete, `Accessibility/AXLogicProElements+TrackControls.swift` their AX readers (toggle state, header name, transport Play state, alert button, header dump); `Channels/AccessibilityChannel+Sounds.swift` holds `sound.prepare_instrument`.
  - `MIDI/`, `OSC/` - CoreMIDI engine and MMC, UDP OSC client/server.
  - `State/` - cache, models, adaptive poller. `Resources/` - 7 MCP resources.
  - `Utilities/` - `StripModel.swift` (Sendable strip model, slot request parsing), `ComposeSupport.swift` (folders, file names, positions, path validation), input validation, logging, permissions, process utils.
- `Tests/MusicCoreTests/` - generator, analyzer, MIDI IO, ClipWriter (+ `ClipWriterKitCCTests.swift` for kit/program/cc) and doc-recipe tests (run everywhere). `Tests/LogicGrooveMCPTests/` - macOS only.
- `docs/SKILL.md` - agent skill teaching the music workflow. `Scripts/install.sh`, `manifest.json`, `.github/workflows/{ci,release}.yml`.

## Conventions

- Dispatcher pattern: each tool is `static let tool` plus `static func handle(command:params:router:cache:)`; commands are a switch on the string. Add new commands to the tool description and to `SystemDispatcher` help.
- Routing: `ChannelRouter.routingTable` maps `"category.operation"` to an ordered channel list; the router tries each until one succeeds. New operations must be added there.
- `ChannelResult` has `.success`, `.unverified` (action performed, outcome not confirmed) and `.error`. `isSuccess` is true for success and unverified.
- MusicCore must stay Foundation-only and Linux-testable. No AppKit, CoreMIDI or ApplicationServices there.
- Time: 480 ppq ticks, 16th = 120. Pitch convention: Logic C3 = 60 (C1 = 36). Drums use GM notes.
- Determinism: generation is a pure function of the request including `seed` (SplitMix64). Seed is random in the dispatcher when omitted and always echoed back.
- Folders: `~/Music/LogicGrooveMCP/Generated` and `.../Exports`.
- No emojis anywhere (code, docs, commits).
- Commit messages end with the Co-Authored-By and Claude-Session trailer lines requested by the session.

## Build and test

- This environment is Linux: `export PATH=/opt/swift/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH && swift test` runs MusicCore tests only (126 tests at last run).
- Accessibility must be re-granted after each rebuild unless the binary is signed with a stable identity (an Apple Development certificate or a self-signed "Logic Groove Signing" certificate; `Scripts/install-local.sh` picks either).
- The AX/CGEvent/CoreMIDI code cannot be compiled on Linux. macOS CI (`macos-15`, `swift build -c release` + `swift test`) is the only compile check. Push and read CI before trusting server changes.
- CI also runs a Linux job in the `swift:6.0` container.
- Local install on the Mac: double-click `Install.command` (runs `Scripts/install-local.sh --restart-claude`: build, install to ~/.local/bin, sign if an identity exists, restart the Claude app; for an unsigned build it opens the Accessibility pane and waits). The agent cannot run macOS commands, change privacy settings or restart Claude itself, so this stays a user step.

## History

Upstream base: bdc105e (koltyj/logic-pro-mcp, MCP SDK 0.12). Added on branch `electronic-music`:
1. `5761ed8` MusicCore target and shared types/theory; Package.swift made Linux-buildable.
2. `3e446bb` MIDI file reader/writer and key/chord/rhythm analyzer.
3. `33ea0a2` House, deep house, dub techno generators with complement mode.
4. `84cd461` `logic_compose` tool; MIDI import/export via file panels; plugin insert; region loop; editor refresh; `last_undo`; fixed stop/play keys and track creation via menus.
5. `6699f65` explicit CoreGraphics import (macOS compile fix).
6. Rename to Logic Groove MCP (package, targets, ServerConfig name "logic-groove-mcp", MIDI port names, manifest, installer, release, CODEOWNERS, SECURITY, license line), Linux CI job, README rewrite, this file, docs/SKILL.md.
7. Branch `free-notes` (0.3.0): `logic_compose write` (ClipWriter in MusicCore, `writeResult` in ComposeDispatcher, SystemDispatcher help, README section, SKILL recipes, ClipWriterTests and DocRecipeTests). Server-side code was written without a macOS compile: read CI first.

8. Version 0.3.1 (import fix): `midi.import_file` rewritten (never types blind; Accessibility selection first, Go to sheet only with a confirmed text field; verified by track count and Undo title; returns a step trace); `FilePanelAutomation.goToChecked`; `AXLogicProElements.importPanel`, `selectFileInPanel`, `panelConfirmButtonState`, focus and subtree-dump helpers; Go To Position confirms the dialog before typing; `logic_system` gained `state`, `debug_panel`, `debug_focus`; installer accepts a self-signed "Logic Groove Signing" identity. Written without a macOS compile: read CI first.
9. Import staging path and checked typing (still 0.3.1): `importMIDIFile` copies the file to `~/Music/LogicGrooveMCP/Import/clip.mid` and imports that copy; `goToChecked` keeps a matching prefill or types in up to 3 read-back-checked attempts and never presses Return unless the field holds the wanted path (`ComposeSupport.pathsEqual`, `importStagingURL`); verification by track count only. Written without a macOS compile: read CI first.

10. Version 0.4.0 (sounds and placement; first live test 2026-11-22 evening: instrument insert and arrow-key track selection worked, see the section below; the other items here are still unrun):
    - MusicCore (tested here): `kit` ("gm" | "ultrabeat_init", `ClipWriter.drumNames(kit:)`, hat2/perc/tom added to GM), `program` (Program Change at tick 0 before the first note), `cc` lanes (linear/step, resolution, dedupe of interpolated values, exact point values always emitted, not tiled by `pattern_bars`, max 16 lanes / 20000 events), `Clip.program`, `Clip.controls`, `ControlEvent`, `MIDIFileIO` write/read of both. Specs without the new keys produce byte-identical MIDI.
    - Import pre-check bug fixed: `importMIDIFile` now refuses only when the strict `importPanel()` is up (a plug-in window no longer blocks imports). The export flow and `file_panel_open` use the new `strictFilePanel()` (import panel, window titled Save/Export/Open, or a file-panel-looking sheet) instead of the loose `filePanel()` (kept for diagnostics).
    - `AccessibilityChannel.selectTrackVerified(index:)` plus `AXLogicProElements.selectedTrackIndex()`: AXPress, AXSelected, arrow keys, last-resort mouse click, each re-read after 200 ms; ok only when the read-back equals the wanted index.
    - `insertPlugin` rewritten: verified track, short AX messaging timeout on the slot press (return value ignored), wait for a focused text field, type the name with read-back, Down x result_index, Right, Down x (variant_index - 1), Return, confirm by a new window (multiset of window titles), close only the new window(s). Params `result_index`, `variant_index`. Result is `.success` only when a new window appeared.
    - `track` on `logic_compose` write/generate/complement/import_midi: routed ops `region.move_selected_to_track` (cut, delete the empty temporary track when its selection is verified, select the target verified) and `region.paste_on_track` (re-verify selection, Edit > Paste); `goto_position` runs between them; the result JSON gets a `place` step.
    - `logic_transport cycle_to_regions` (Edit > Select > All, Navigate > Set Rounded Locators by Selection and Enable Cycle); `set_cycle_range` now returns an error pointing to it.
    - `logic_system debug_panel` gained `window` and `max_lines`; new `debug_strip`.
    - Earlier fixed: the "plug-in window blocks import" bug (see first bullet).

11. Version 0.4.1 (live-test fixes; FIRST LIVE TEST PENDING for everything below, written without a macOS compile: read CI first):
    - Plug-in slots by structure: `AXLogicProElements.stripModel()` (`Utilities/StripModel.swift` holds the Sendable types, `Accessibility/AXLogicProElements+Strip.swift` the AX reader) reads the selected track's layout item and Stereo Out; `pressPluginList(slotKind:)` presses the `list` button of the instrument or of the n-th effect (REPLACES it) or the empty `audio plug-in` button (ADDS an effect). `insertPlugin` takes `slot` = "instrument"/0, "new"/"add"/"append" (default) or n >= 1; it verifies by the strip structure after the window check and returns `chain: <instrument> | <effects>`. Fixes the live failure where `slot: 1` replaced Channel EQ instead of adding an effect.
    - New `logic_mixer` commands: `strip` (JSON model), `bypass_plugin` (rewritten: bypass checkbox, pressed only when the state differs, read back), `set_volume {db}` and `set_master_volume {db}` (bisection on the fader's AXValue, at most 14 steps, read back from the level text title; `ComposeSupport.parseDecibels`). Old `value` forms are unchanged. Routed as `mixer.strip`, `mixer.set_volume_db`, `mixer.set_master_volume_db`, `plugin.bypass`; implemented in `Channels/AccessibilityChannel+Strip.swift`.
    - Import: strategy A only when the panel exposes AXRow/AXCell with string values; new strategy K (keyboard, no typing: "Where:" pop-up equals the staging folder name and the folder holds exactly one entry; AXFocused on the column browser, Right, then Down, then Import if enabled and the folder is unchanged); strategy B (Go to sheet) now pastes the path first (NSPasteboard saved and restored, Cmd+A, Cmd+V, read back), then at most 2 typed attempts; every failed attempt notes the focus afterwards. Fixes the live failure where typing left the focus outside the Go to field.
    - Version 0.4.1.

12. Version 0.4.2 (`87706bb` MusicCore, `622fdeb` server; macOS CI green; FIRST LIVE TEST PENDING for everything below):
    - `logic_sounds` (new tool): `folders`, `presets {query, folder, category, limit}`, `bank`, `bank_install {presets, mode: replace|append}`, `set_preset {track, preset|program}`. Presets of u-he synths (default plug-in "Diva") are read from `/Library/Audio/Presets/u-he/<plugin>` and `~/Library/Audio/Presets/u-he/<plugin>`; `bank_install` copies up to 128 of them into `<local root>/MIDI Programs` as `NNN name.h2p` (ownership manifest `~/Music/LogicGrooveMCP/<plugin>-bank.json`; files the server did not write are never touched). The synth loads that folder only when the host starts, so Logic must be restarted after every bank change (`bank` and `set_preset` warn when the bank is newer than Logic's launch date). `set_preset` selects the track (read back), requires the instrument name to contain the plug-in name, sends Bank Select CC 0 = 0 and a Program Change through the virtual MIDI source, then compares the track header name before/after (`verified` only when the name contains the preset name).
    - Import position: `at_bar` now means "bar 1 of the clip". Server-built clips are written without their leading empty bars and imported at `at_bar + leading_empty_bars`; `import_midi` reads the file to count them. Results carry `leading_empty_bars` and `region_start_bar`. Playback is stopped before the Go To Position (transport Play checkbox read live).
    - `logic_tracks` mute/solo/rename/delete rewritten with read-back (`AccessibilityChannel+Tracks.swift`): AXPress first, then verified selection + Logic frontmost + key (M, S, Shift+Return, Cmd+Delete). `delete` requires `index`, presses "Delete" on the confirmation alert and succeeds only when the header count drops by one. `track.delete` is routed to accessibility only.
    - `set_volume {db}` / `set_master_volume {db}`: stepped search (AXIncrement/AXDecrement, then AXValue deltas, then the level text field) with read-back, caps 700 steps / 25 s; integer `db` accepted (`InputValidation.looseDouble`).
    - Placement uses Cmd+X / Cmd+V key events after `ensureFrontmost()`; the cut guard ("Cut" in the Undo title) stays, the paste must show "Paste".
    - Project window test accepts "<name> - Tracks" (unsaved projects). `logic_edit` shortcuts go through the HID tap after a frontmost check. `logic_system debug_header {track}`.

## Verified on a real Mac (Logic Pro 11, 2026-10-18)

- Server starts from the Claude desktop app; needs Accessibility for the binary (~/.local/bin/LogicGrooveMCP).
- generate (import=false), analyze_file, styles: work. Real stab analyzed as F minor, Fm(add9)/Fm.
- Menu "File > Export > Selection as MIDI File…" exists with that exact title.
- The Open/Save panel is a standalone window titled "Save MIDI File as:" that becomes AXMainWindow; name field = first AXTextField (search field has subrole AXSearchField); buttons "Save"/"Cancel"; Cmd+Shift+G opens a go-to sheet that accepts "~/..." paths.
- Fixed: filePanel()/attentionContainers() skipped the main window, so the panel was never found. Use projectWindow() (title contains ".logicx") for project-window lookups.
- AXPress on a region (AXLayoutItem) does NOT select it; a real click does. Region selection is still manual or via screen click. (For TRACK headers, arrow keys select; AXPress does not reliably change the selection, see the 2026-11-22 evening section.)

## Verified on a real Mac (Logic Pro 11, 2026-11-22, commit 350c4a3)

- `logic_compose write` and `import_midi` work end to end: four imports in a row succeeded (stab, sub, step-pattern drums, pad), each verified by the track count, regions landed at the requested bar (1 and 5) with the clip name as region name.
- First import after another app used the Go to sheet: the path was typed once and read back correctly ("attempt 1: matches=true"). Every later import: "prefill already matches; not typing".
- Each import creates a NEW software instrument track with the default patch (shown as "Studio Grand"); the track is not named after the clip. Sound assignment is still missing (next step).
- `logic_system state` works; right after the server starts the live track header count and the cache can read 0 until the first poll: call `refresh_cache` (or `state` twice) before trusting counts.
- `transport.goto_position` through the checked Go To Position dialog works.
- MCP resources (logic://...) are not reachable through the Claude desktop device bridge; tools only.
- The installed binary lost Accessibility after every unsigned rebuild; the user re-adds it by hand. `Install.command` was used for the last install.

## Verified on a real Mac (Logic Pro 11, 2026-11-22 evening, 0.4.0)

WORKS:
- `logic_mixer insert_plugin {track: 5, slot: 0, name: "Diva"}` succeeded first time. Trace: `select track 5: selected now 2; AXPress ok -> selected 2; AXSelected: not settable -> selected 2; arrow Down x3 -> selected 5; ...; slot candidates=43, chosen AXButton[title=, desc=list], AXPress returned -25204; menu search field focused: AXTextField/AXSearchField value=''; typed 'Diva', field holds 'Diva'; keys: Down x1, Right, Down x0, Return; new window: 'Studio Grand' after 500 ms; closed 1 new window(s)`.
- Track selection: arrow keys are what works. AXPress on a track header and AXSelected (not settable) do NOT change the selection.
- The slot press returns -25204 while the menu is open (the return value is only recorded); the menu's search field is an AXSearchField and is readable; the new plug-in window is detected.
- `logic_system debug_strip` works and shows the real structure.

Inspector channel strip structure (software instrument track): `AXLayoutArea desc='Mixer'` with two `AXLayoutItem`s, the selected track (desc = track name) and `desc='Stereo Out'`. Inside the track's item the AX child order is bottom to top on screen; frames are global, y grows downward:
- `AXTextField desc='name'`; `AXSlider desc='volume fader'` (settable AXValue, 173 = 0.0 dB); `AXTextField title="volume fader level, 0,0 dB"` (decimal comma); `AXButton title="peak level meter, -7,9 dB" value='signal clipping off'` (title is just "peak level meter" when no signal has passed; Stereo Out shows value 'mixed' when clipping); `AXSlider desc='pan'`.
- `AXGroup desc='Read, automation enabled'` holds `AXCheckBox desc='automation'` and a `list` button: NOT a plug-in slot.
- Plug-in = `AXGroup desc='<plug-in name>'` with children `AXCheckBox desc='bypass'` (value '1' = bypassed), `AXButton desc='open'`, `AXButton desc='list'`. Empty effect slot = `AXButton desc='audio plug-in'` (pressing it opens the same searchable menu and ADDS an effect). `AXButton desc='MIDI plug-in'` sits just above the instrument group. `AXButton desc='insert bar'` between slots.
- On screen top to bottom: setting, EQ, MIDI plug-in, instrument, effect 1..n, empty 'audio plug-in' slot, send, Stereo Output, group, automation, pan, fader. The instrument is the plug-in group with the smallest y.

FAILED:
- `insert_plugin {slot: 1, name: "Tape Delay"}` REPLACED the existing first effect (Channel EQ) instead of adding one (fixed in 0.4.1, untested: structural slots).
- `logic_compose import_midi` failed twice, safely (Return was not pressed): after Cmd+A and typing, the focus was no longer a non-search text field (`B attempt 1: field has 0 chars; B attempt 2: focus is not the go-to field`). Typing into the Go to sheet is unreliable and the sheet's memory is overwritten whenever the user uses a Go to sheet in any other app (fixed in 0.4.1, untested: strategy K and paste).

## Verified on a real Mac (Logic Pro 11, 2026-11-23 morning, 0.4.1, new "Untitled" project)

WORKS:
- Import strategy K (no typing): `K Where='Import', 1 file in the staging folder; K AXBrowser: AXFocused set; K after Right: button enabled:Import; K pressed 'Import'`. It worked on the first import only; on the next two the button stayed disabled after Right and Down (the panel reopens in a different focus state), and strategy B took over.
- Import strategy B with paste: `B paste: field has 59 chars, matches=true`, and on the following import `B prefill already matches; not typing`. Three imports out of three succeeded.
- `insert_plugin`: instrument (`Diva`, `Ultrabeat`) and a NEW effect (`Tape Delay` without `slot`: chain `Diva | Channel EQ, Compressor, ChromaVerb, Tape Delay`, undo title "Undo Insert Plug-in in Channel Strip"). The structural check and the `chain:` text are correct.
- `logic_mixer strip` returns the right model; `bypass_plugin {plugin: "Compressor", bypassed: true}` worked with read-back.
- `kit: "ultrabeat_init"` maps the drum names correctly; `logic_transport cycle_to_regions` selects the regions and enables the cycle (confirmed visually: cycle on bars 1-5).
- Track selection: the header holds an `AXRadioButton 'Has Focus'`; the last-resort click on the number column works (`click at (3883,314) posted -> selected 1`).

BROKEN (to fix in 0.4.2):
- Placement (`track` param): `Edit > Cut` pressed through AX did NOT cut (undo title stayed "Undo Import"), so the safety stopped it. A Cmd+X key event posted while Logic was frontmost DID cut ("Undo Cut"). A later Cmd+V posted while the Claude app was frontmost did nothing. Key commands only work when Logic is frontmost, and Edit menu items pressed through AX are unreliable; use key events after `ensureFrontmost()`.
- The Edit menu Undo title is only meaningful while Logic is frontmost (it reads plain "Undo" / "Can't Undo" in the background). Read it right after an action inside a flow that brought Logic to the front.
- Arrow-key track selection is skipped on an unsaved project: "the project window is not the focused window (title='Untitled - Tracks')". The project-window test must accept "<name> - Tracks" without ".logicx".
- `set_volume {db}`: setting the fader's AXValue does not jump to the value; every set moves the fader by one small step (about 0.1 dB down per call), whatever value is passed, so the bisection ended at -1.4 dB after 14 steps. The fader has to be stepped (AXIncrement / AXDecrement or repeated sets) until the level text reaches the target.
- `set_volume {db: -6}` with an integer was routed to the old `value` path ("Missing 'index' or 'value' parameter"); only a float (-6.5) reached the dB code.
- `logic_edit` shortcuts (cut, paste, ...) are posted without bringing Logic to the front first.
- Still missing: choosing a Diva preset without its custom UI (every new Diva instance plays the init sound), and setting plug-in parameters.

## Verified on a real Mac (Logic Pro 11, 2026-11-23 late morning, 0.4.1, first full track built with MCP tools only)

WORKS:
- Five imports in a row (drums, sub, stab, pad, ping; 64-bar clips) each followed by `insert_plugin` on the instrument slot (Ultrabeat, ES M, Diva, ES E, EFM1), `insert_plugin` of a new effect (Tape Delay) and `bypass_plugin` (ChromaVerb): every call succeeded. Strategy K failed every time (Import stayed disabled), strategy B with the matching prefill did the work.
- `analyze_region` right after an import exports the freshly imported (still selected) region. The exported file keeps the ABSOLUTE project position (a 52-bar region at bar 20 analyzed as 71 bars), so it can be used to read back where a region landed.

BROKEN / LEARNED (to fix in 0.4.2):
- Logic drops the leading empty bars of an imported MIDI file: the region starts at the bar of the first note and THAT bar is put at the playhead. A clip whose notes start at bar 9 imported with `at_bar: 1` plays from bar 1. All parts of the test track therefore start at bar 1 and the planned build-up (sub from 9, stab from 17, ping from 25) and the aligned break are lost. Fix: the dispatcher must add the clip's leading empty bars to `at_bar` (ClipWriter knows the first note tick), and say so in the result.
- One import with `at_bar: 9` landed at bar 20 although Go To Position reported 9.1.1.1 (the playhead showed 20 afterwards; the user may have been playing back). The playhead position must be read back right before the Import button is pressed.
- `logic_tracks rename` and `logic_tracks mute` return success and change nothing (headers keep "Studio Grand", the M button stays off). `logic_tracks delete` selects through the unverified `track.select` and then posts Cmd+Delete: it can delete the wrong track, do not use it until it goes through `selectTrackVerified`.
- The `state` cache is stale for the transport position and track names; only `live` values are trustworthy.
- User feedback on the result: the sounds are the problem, not the notes. He wants Diva on every part where it fits, with real house / electronic presets (not init sounds), and drums that sound like house drums (the Ultrabeat init kit does not). Preset selection (Diva, drum kit) is now the top priority, ahead of placement.

## Sound assignment, learned by hand on 2026-11-22 (not yet in the server)

- `logic_mixer insert_plugin` FAILS on the instrument slot: "Could not open the slot menu (neither AXShowMenu nor AXPress worked on AXButton[title=, desc=list])". An AXPress on that same `list` button from another tool does open the menu, so the press works but the server does not find the opened menu.
- Working keyboard flow once the slot menu is open (Logic frontmost): the menu has a Search field with focus; type the plug-in name ("Diva"), Down (highlights the single result), Right (opens the Stereo / Multi-Output submenu), Return. The plug-in window opens.
- Diva is installed as a DEMO (1.4.8, AU). Every new instance shows a "Thank you for trying our software" notice that must be closed (X at its top right) before anything else. The user wants Diva used anyway.
- Diva presets are chosen in its own PRESETS tab (custom drawn UI: search field, double-click a result). Local presets live in /Library/Audio/Presets/u-he/Diva (folders 1 BASS ... 8 TEMPLATES, MIDI Programs, THIRD PARTY; 1432 presets). The "MIDI Programs" folder exists: presets placed there are selectable by MIDI Program Change (u-he feature, loaded when the host starts), which is the planned way to pick presets without the UI. Folder access to the preset folders was refused to the agent; the user has to add the folder himself if presets are to be read or written.
- Presets used for the first audible test: stab "HS Stabz" (poly brass-like stab), sub "MK Bass Sub Tri", pad "IW Lush PWM Pad".
- A track takes the name of the loaded plug-in setting (track 2 became "HS Stabz").
- Logic's sound library is mostly NOT downloaded on this Mac (Library items show a download badge; AX description starts with "downloadable"). Ultrabeat has no factory kits (settings menu only offers Load/Save), so its init kit is used.
- Ultrabeat init kit mapping (NOT GM): C1 sine, C#1 kick, D1 snare, D#1 hat 1, E1 hat 2, F1 tom, F#1 claps, G1 perc, G#1 shaker, A1 bass, A#1 sample; voice 25 is a chromatic bass from C3 up. Drum clips for it must use these notes, not the GM drum names.
- Every import lands on a new track with the default instrument, so the instrument has to be set after each import (or the region moved to an existing track). `transport.set_cycle_range` is not implemented.

- Audio FX slot: clicking the first empty slot under the last effect opens the same searchable menu; "Tape Delay" + Down + Right + Return inserts it (Stereo). Tape Delay defaults are already dub friendly (tempo sync, feedback 61 %, low cut 520 Hz, high cut 1500 Hz, dry 90 / wet 30); the Note pop-up is a normal menu (Up/Down + Return): "1/8 dotted" was set on the stab track.
- Menu items that work without any clicking and should be used by the server: Edit > Select > All, then Navigate > Set Rounded Locators by Selection and Enable Cycle (sets the cycle to the regions). Navigate items are disabled until something is selected.
- Putting an imported region on an existing instrument track currently needs a mouse drag from the new track to the target track (same x keeps the bar; with Drag: No Overlap it replaces the region underneath). A server-side way is needed (for example select the target track and paste at the playhead).
- A hovered insert slot shows a power button at its left end: clicking it bypasses the plug-in (used to switch off the patch reverb on the sub track).
- Session result: 8-bar loop in F minor (Fm9 x4, Dbmaj9 x2, Cm9 x2) on tracks 2-5 of the user's "Untitled" project: Diva stab + Tape Delay, Diva sub, Ultrabeat drums, Diva pad. The Stereo Out peaked at +3.8 dB, so levels need to come down.

- Placement safety (0.4.0): `region.move_selected_to_track` continues past Edit > Cut only when the Edit menu's Undo title then contains "Cut"; otherwise it stops with the region still on the new track (no delete, no paste). If the first live test shows that title is not reliable here, the check has to be replaced, not removed.

## Known issues and unverified assumptions

- Live test 2026-11-22 (Logic Pro 11): File > Import > MIDI File... opens a window (AXWindow, subrole AXDialog, title "Import", buttons Cancel and Import) whose content is hosted out of process; it opens in the last used folder and Import is disabled until a file is selected. The old flow (Cmd+Shift+G, Cmd+A, type, Return) closed the panel without importing anything while reporting `unverified`. Import now returns a trace and is `.error` unless the track count or the Edit menu Undo title changed.
- Live runs 2026-11-22 (0.3.1 flow): the Go to typing landed once and failed twice (field had 0 chars) when the field was pre-filled with the previous path; the Go to sheet remembers the last path system-wide. Return on an empty or mismatched field closes the whole panel without importing. File rows are not exposed through AX in column view (`AXBrowser` > empty `AXScrollArea`s), so `selectFileInPanel` cannot work there. The Edit menu Undo title flips between "Can't Undo" and "Undo" without any import and is not usable as a signal. The Go To Position dialog check works. Logic creates a new track named after the default patch for every imported MIDI file and asks a tempo question that is answered "No".

- 0.4.2 assumptions, all unverified: Logic passes a Program Change from the virtual MIDI source (and from a region) to the instrument plug-in of the selected track; Diva renames the track when a program loads (only basis for `verified: true` in `set_preset`); `/Library/Audio/Presets/u-he/Diva/MIDI Programs` is writable by the user; Shift+Return opens the inline track name editor; plain M / S toggle mute / solo of the selected track; Cmd+Delete deletes the selected track and the confirmation alert has "Delete" and "Cancel" buttons; the Undo title contains "Cut" / "Paste" after Cmd+X / Cmd+V; the fader slider offers AXIncrement / AXDecrement; the header toggle AXValue reads as number, "1" or "true"; Logic counts only NOTES when it drops leading empty bars (a CC or Program Change at tick 0 with later notes is untested).
- If Program Change does not reach Diva in Logic, plan B is driving Diva's own preset browser from the server (clicks inside the plug-in window only).
- Menu titles are matched in English (Logic Pro 11); other languages or versions untested.
- File panels in a sandboxed Logic (Cmd+Shift+G go-to-folder, save name field, replace alert) are unverified.
- Go To Position expects the format `N.1.1.1`; result is `.unverified`, so import placement at the playhead is not read back.
- Inspector channel strip is an AXLayoutArea described "Mixer" (verified); its structure is in the 2026-11-22 evening section. The 0.4.1 structural reader (`stripModel`), bypass, `set_volume {db}` bisection (assumes the raw value is monotonic in dB) and the instrument rule (first plug-in group is the instrument only when a `MIDI plug-in` button exists and there is no empty `instrument plug-in` button; a loaded MIDI FX plug-in would be misread as the instrument) are unverified.
- `waitForPanelToClose` treats the tempo sheet as a panel, so it can add up to 3 s delay.
- `refresh_editor` matches menu titles by prefix (risk of hitting a wrong item).
- The "replace" alert search scans all windows.
- AX labels are localized; OSC needs manual Control Surface setup.
- House and deep_house share generators (differ only in default scale and name).

## Decisions

- Imports go through a fixed staging file (~/Music/LogicGrooveMCP/Import/clip.mid) so the Go to sheet's remembered path normally already matches and nothing has to be typed.
- An import is verified only by a higher track count.
- Never type into a panel or dialog unless the target text field is confirmed through AX; cancel and return an error with a trace instead.
- State is exposed through `logic_system state` because MCP resources are not reachable from every client.
- A synthetic mouse click is allowed in exactly one place: the last-resort track selection in `selectTrackVerified` (track number column of an AX-located header). Everything else stays AX or keyboard.
- Plug-ins are inserted through the slot menu's search field with the keyboard (type, Down, Right, Return) and confirmed by the new plug-in window and by the strip structure.
- Effect slots are addressed by structure: 'new' (default) adds in the empty slot, n replaces the n-th effect.
- Imports first try the keyboard path in the remembered staging folder (no typing), then the Go to sheet with paste (typing only as a fallback).
- Levels are read from the strip's peak meter titles (`logic_mixer strip`); after building a loop, bring the master peak below 0 dB with `set_volume {db}`.
- A plug-in is never inserted unless the target track selection was read back.

- Synth presets are chosen without the plug-in UI: a curated bank in the synth's `MIDI Programs` folder plus a live Program Change on the verified-selected track (the preset is then saved with the project). `program` inside a clip is kept for special cases only, because it reloads the preset every time the cycle passes the region start.
- The server only ever removes or overwrites bank files it wrote itself (manifest); foreign presets in `MIDI Programs` stay.
- `at_bar` is the position of bar 1 of the clip, not of the first note.
- House / dub techno drums are built from the synth's percussive presets, one voice per track (kick, hats, clap), written as pitched notes; the Ultrabeat init kit is not good enough (user feedback 2026-11-23).
- Track mute/rename/delete count as done only after a read-back; `delete` never runs without an explicit index and a verified selection.
- Never use Space for stop/play; use keypad 0 / Enter style keys (and MMC first).
- Track creation goes through Track menu items first, keyboard as fallback.
- Every mutating compose/plugin result carries `undo_label` (Edit menu Undo title) for verification; `edit.last_undo` reads it without pressing anything.
- The server never clicks at screen coordinates, except the single last-resort track header click described below; every step finds an AX element or reports what it saw.
- Tempo meta is written to MIDI only when `tempo` is passed, so imports do not change the project tempo.
- Prefer writing MIDI files and importing them over drawing notes.
- Never delete user material; create new tracks, mute instead of delete.
- Free-form parts go through `logic_compose write` (ClipWriter in MusicCore); generators remain for quick starting points.
- ClipWriter warning counts (dropped, shortened, trimmed) are computed before humanize so they only reflect what the caller wrote.

## Lessons from the live Logic session

- The Piano Roll can stay stuck on an old region: use `refresh_editor` or reopen the project.
- With automation view on, clicking regions creates automation nodes; keep automation view off.
- u-he plugins show a demo dialog that blocks automation until dismissed.
- Pencil-tool clicks are unreliable; MIDI file import is the dependable way to write notes.
