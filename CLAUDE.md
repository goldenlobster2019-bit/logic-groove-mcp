# CLAUDE.md - Logic Groove MCP

## Purpose

MCP server (Swift, macOS) that lets AI assistants drive Logic Pro and write electronic music parts (house, deep house, dub techno). Fork of koltyj/logic-pro-mcp (MIT, Kolton Jacobs), renamed and extended by Golden Lobster Studio (Sorin Gheorghita). Repo: https://github.com/goldenlobster2019-bit/logic-groove-mcp. Version 0.2.0.

## Structure

- `Package.swift` - MusicCore + its tests always; server target `LogicGrooveMCP` and `LogicGrooveMCPTests` only under `#if os(macOS)`.
- `Sources/MusicCore/` - pure Swift (Foundation only), Linux-tested.
  - `Types.swift` - ppq (480), NoteEvent, Clip, Genre, Part, GenerationRequest, ClipAnalysis, SeededRandom, DrumNote map.
  - `Theory.swift` - note names, scales, chord building, chord naming.
  - `MIDIFileIO.swift` - Standard MIDI File reader/writer (tempo meta only when passed).
  - `Analyzer.swift` - key, chord and onset-grid analysis of a Clip.
  - `Generators/Generator.swift` - public API (generate, complement, styles), request resolution, style catalogue.
  - `Generators/DubTechno.swift`, `House.swift` - per genre/part pattern builders (house and deep_house share House.swift).
  - `Generators/Groove.swift` - swing, humanize, interlock with stab onsets, finalize.
- `Sources/LogicGrooveMCP/` - macOS-only server.
  - `main.swift` - entry, `--check-permissions`.
  - `Server/` - `LogicProServer.swift` (tool/resource registration, class name kept from upstream), `ServerConfig.swift` (name, ports, timeouts, MIDI port names).
  - `Dispatchers/` - one file per MCP tool (transport, tracks, mixer, midi, edit, navigate, project, compose, system).
  - `Channels/` - `Channel.swift` (protocol, ChannelID, ChannelResult), `ChannelRouter.swift` (routing table), CoreMIDI, Accessibility (+Compose), CGEvent, AppleScript, OSC channels, `FilePanelAutomation.swift` (open/save panel driving).
  - `Accessibility/` - AX wrappers; `AXLogicProElements+Compose.swift` holds menu/panel/inspector/plugin finders.
  - `MIDI/`, `OSC/` - CoreMIDI engine and MMC, UDP OSC client/server.
  - `State/` - cache, models, adaptive poller. `Resources/` - 7 MCP resources.
  - `Utilities/` - `ComposeSupport.swift` (folders, file names, positions, path validation), input validation, logging, permissions, process utils.
- `Tests/MusicCoreTests/` - generator, analyzer, MIDI IO tests (run everywhere). `Tests/LogicGrooveMCPTests/` - macOS only.
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

- This environment is Linux: `export PATH=/opt/swift/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH && swift test` runs MusicCore tests only (37 tests at last run).
- The AX/CGEvent/CoreMIDI code cannot be compiled on Linux. macOS CI (`macos-15`, `swift build -c release` + `swift test`) is the only compile check. Push and read CI before trusting server changes.
- CI also runs a Linux job in the `swift:6.0` container.

## History

Upstream base: bdc105e (koltyj/logic-pro-mcp, MCP SDK 0.12). Added on branch `electronic-music`:
1. `5761ed8` MusicCore target and shared types/theory; Package.swift made Linux-buildable.
2. `3e446bb` MIDI file reader/writer and key/chord/rhythm analyzer.
3. `33ea0a2` House, deep house, dub techno generators with complement mode.
4. `84cd461` `logic_compose` tool; MIDI import/export via file panels; plugin insert; region loop; editor refresh; `last_undo`; fixed stop/play keys and track creation via menus.
5. `6699f65` explicit CoreGraphics import (macOS compile fix).
6. Rename to Logic Groove MCP (package, targets, ServerConfig name "logic-groove-mcp", MIDI port names, manifest, installer, release, CODEOWNERS, SECURITY, license line), Linux CI job, README rewrite, this file, docs/SKILL.md.

## Verified on a real Mac (Logic Pro 11, 2026-10-18)

- Server starts from the Claude desktop app; needs Accessibility for the binary (~/.local/bin/LogicGrooveMCP).
- generate (import=false), analyze_file, styles: work. Real stab analyzed as F minor, Fm(add9)/Fm.
- Menu "File > Export > Selection as MIDI File…" exists with that exact title.
- The Open/Save panel is a standalone window titled "Save MIDI File as:" that becomes AXMainWindow; name field = first AXTextField (search field has subrole AXSearchField); buttons "Save"/"Cancel"; Cmd+Shift+G opens a go-to sheet that accepts "~/..." paths.
- Fixed: filePanel()/attentionContainers() skipped the main window, so the panel was never found. Use projectWindow() (title contains ".logicx") for project-window lookups.
- AXPress on a region (AXLayoutItem) does NOT select it; a real click does. Region selection is still manual or via screen click.

## Known issues and unverified assumptions

- Menu titles are matched in English (Logic Pro 11); other languages or versions untested.
- File panels in a sandboxed Logic (Cmd+Shift+G go-to-folder, save name field, replace alert) are unverified.
- Go To Position expects the format `N.1.1.1`; result is `.unverified`, so import placement at the playhead is not read back.
- Inspector channel strip is detected as an AXLayoutArea described "Mixer"; plugin menu uses search field or AXPress through submenus. Results are unverified.
- `waitForPanelToClose` treats the tempo sheet as a panel, so it can add up to 3 s delay.
- `refresh_editor` matches menu titles by prefix (risk of hitting a wrong item).
- The "replace" alert search scans all windows.
- AX labels are localized; OSC needs manual Control Surface setup.
- House and deep_house share generators (differ only in default scale and name).

## Decisions

- Never use Space for stop/play; use keypad 0 / Enter style keys (and MMC first).
- Track creation goes through Track menu items first, keyboard as fallback.
- Every mutating compose/plugin result carries `undo_label` (Edit menu Undo title) for verification; `edit.last_undo` reads it without pressing anything.
- The server never clicks at screen coordinates; every step finds an AX element or reports what it saw.
- Tempo meta is written to MIDI only when `tempo` is passed, so imports do not change the project tempo.
- Prefer writing MIDI files and importing them over drawing notes.
- Never delete user material; create new tracks, mute instead of delete.

## Lessons from the live Logic session

- The Piano Roll can stay stuck on an old region: use `refresh_editor` or reopen the project.
- With automation view on, clicking regions creates automation nodes; keep automation view off.
- u-he plugins show a demo dialog that blocks automation until dismissed.
- Pencil-tool clicks are unreliable; MIDI file import is the dependable way to write notes.
