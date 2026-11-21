# Logic Groove MCP

[![CI](https://github.com/goldenlobster2019-bit/logic-groove-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/goldenlobster2019-bit/logic-groove-mcp/actions/workflows/ci.yml)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000.svg?logo=apple)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An MCP server that lets Claude and other AI assistants drive Logic Pro on macOS and write music parts for house, deep house and dub techno. The assistant can create tracks, generate drums, basses, stabs, chords and pads as MIDI, import them into your project at a chosen bar, load plugins, and write new parts that fit material you already recorded.

Based on [koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp) by Kolton Jacobs (MIT). See [Credits](#credits).

## Features

- **Generate parts** with `logic_compose`: drums, kick, hats, bass, stabs, chords and pad for house, deep house and dub techno. Every part has named styles, and results are seedable (same seed, same clip) with `density`, `swing` and `humanize` controls.
- **Write your own notes** with `logic_compose("write", ...)`: give exact notes, chords (symbols such as `Fm9`, with voicings) and step patterns for drums, and get a clip written and imported exactly like a generated one. Use it whenever the fixed styles do not cover the sound you want.
- **Analyze a selected region**: export the selected MIDI region from Logic and get key, chords, rhythm (onset grid) and pitch range back.
- **Complement**: write a part that fits your existing stab or chords. The bass avoids your stab onsets, takes the key from the analysis, and chord parts follow the detected chord.
- **MIDI import and export**: generated files are imported through Logic's File > Import > MIDI File menu at the bar you choose; regions are exported the same way for analysis. Existing `.mid` files can be analyzed or imported.
- **Plugin loading**: insert instruments and effects into the instrument or FX slots of a track by name.
- **Everything else the original server does**: transport, tracks, mixer, raw MIDI/MMC, editing, navigation, project lifecycle and system diagnostics, plus 7 read-only resources.

## Example prompts

- "Write a monotone dub techno bass in F minor that fits my stab and load it on a new Diva track."
- "Analyze the selected region and tell me the key and chords."
- "Make an 8 bar deep house drum loop at swing 0.2 and put it on bar 9."
- "Give me a dub chord stab in A minor, 4 bars, low density, and loop the region."
- "Add a soft m9 drone pad under the chords, seed 42."

## Example tool calls

```jsonc
// What styles exist?
logic_compose("styles", { "genre": "dub_techno", "part": "bass" })

// Generate and import a dub techno stab at bar 1, looped
logic_compose("generate", { "genre": "dub_techno", "part": "stabs", "key": "F", "scale": "minor",
                            "bars": 8, "style": "dub_chord", "density": 0.3, "seed": 7, "loop": true })

// Analyze the selected region, then write a bass that fits it
logic_compose("analyze_region", {})
logic_compose("complement", { "genre": "dub_techno", "part": "bass", "style": "monotone_pulse", "bars": 8 })

// Generate a file only, import later
logic_compose("generate", { "genre": "house", "part": "drums", "import": false })
logic_compose("import_midi", { "path": "/Users/me/Music/LogicGrooveMCP/Generated/example.mid", "at_bar": 5 })

// Create a track and load a plugin into its instrument slot
logic_tracks("create_instrument", {})
logic_mixer("insert_plugin", { "track": 4, "slot": "instrument", "name": "Diva" })

// Verify what Logic just did
logic_edit("last_undo", {})
```

`generate` and `complement` return the written file path, the resolved key, scale, octave and style, the seed (always echoed back), a bar-1 note preview, the import result and an `undo_label` (the Edit menu's Undo title). The tempo is written into the MIDI file only when you pass `tempo`, so importing does not change the project tempo.

## Tools

| Tool | Purpose | Example |
|------|---------|---------|
| `logic_compose` | styles, generate, write, analyze_region, analyze_file, complement, import_midi, set_loop | `logic_compose("generate", {genre: "house", part: "bass"})` |
| `logic_transport` | play, stop, record, set_tempo, goto_position... | `logic_transport("set_tempo", {tempo: 124})` |
| `logic_tracks` | select, create_audio, create_instrument, mute, solo, arm, rename... | `logic_tracks("mute", {index: 2, enabled: true})` |
| `logic_mixer` | set_volume, set_pan, insert_plugin, bypass_plugin... | `logic_mixer("set_volume", {track: 0, value: 0.8})` |
| `logic_midi` | send_note, send_cc, send_chord, MMC | `logic_midi("send_note", {note: 60, velocity: 100, channel: 1, duration_ms: 500})` |
| `logic_edit` | undo, redo, cut, copy, paste, quantize, split, last_undo | `logic_edit("quantize", {value: "1/16"})` |
| `logic_navigate` | goto_bar, markers, toggle_view, refresh_editor, open_piano_roll | `logic_navigate("goto_bar", {bar: 9})` |
| `logic_project` | new, open, save, bounce, launch, quit | `logic_project("open", {path: "/path/to/song.logicx"})` |
| `logic_system` | health, permissions, refresh_cache, help | `logic_system("help", {category: "compose"})` |

Resources (read-only): `logic://transport/state`, `logic://tracks`, `logic://tracks/{index}`, `logic://mixer`, `logic://project/info`, `logic://midi/ports`, `logic://system/health`.

Full command reference: `logic_system("help", {category: "all"})`.

### Generate parameters

| Parameter | Meaning |
|-----------|---------|
| `genre` | `house`, `deep_house`, `dub_techno` |
| `part` | `drums`, `kick`, `hats`, `bass`, `stabs`, `chords`, `pad` |
| `key`, `scale` | Root note (F, A#, Db) and scale: minor, dorian, phrygian, major, mixolydian, harmonic_minor, minor_pentatonic, major_pentatonic. Defaults: dub techno F minor, deep house A minor, house A dorian |
| `bars` | 1 to 64, default 4 |
| `style` | One of the styles below; the first listed is the default |
| `density` | 0 to 1, default 0.5. How many events are placed |
| `swing` | 0 to 1, default 0. Delays off-16ths |
| `humanize` | 0 to 1, default 0.2. Velocity and timing variation |
| `octave` | Root octave, Logic numbering (C3 = 60). Bass defaults to 1, other parts to 2 |
| `seed` | Reproducible output. Random if omitted, always returned |
| `import`, `at_bar`, `loop`, `tempo`, `name` | Import into Logic (default true), target bar (default 1), enable region Loop, write tempo into the file, clip name |

Deep house and house currently share the same pattern generators; they differ in default scale (minor vs dorian) and clip naming.

### Writing your own notes

`write` takes the exact material instead of a style. Everything is optional, but at least one of `notes`, `chords` or `steps` must produce a note. The clip is written to a `.mid` file and imported the same way as `generate`. The result lists `warnings` (dropped, shortened or trimmed notes), the note `range`, a bar-1 preview and an `analysis` (key, chords) so you can check what was written without listening.

| Parameter | Meaning |
|-----------|---------|
| `name` | Clip name (default "Written clip") |
| `bars` | 1 to 256. If omitted: derived from the content (or `pattern_bars`) |
| `pattern_bars` | 1 to 64. `notes` and `chords` describe a pattern of this many bars, tiled to fill `bars` |
| `grid` | Steps per bar for `steps` and numeric `step` positions: 4, 8, 12, 16 (default), 24, 32, 48. 12 and 24 are triplet grids |
| `channel`, `transpose` | MIDI channel 1 to 16; semitones -48 to 48 (not applied to drum names) |
| `swing`, `humanize`, `seed` | Same meaning as for `generate`; with both at 0 the output is exactly what you wrote |
| `notes` | `[{ pos or step, pitch, len?, vel? }]` |
| `chords` | `[{ pos or step, chord or pitches, octave?, voicing?, inversion?, strum?, len?, vel?, vel_top? }]` |
| `steps` | `{ lane: pattern }` or `{ lane: { pattern, vel?, len? } }` |
| `import`, `at_bar`, `loop`, `tempo` | As for `generate` |

Syntax:

- `pos` is `bar.beat.sixteenth`, all 1-based (`"2.3.3"`); an optional fourth field adds ticks 0 to 119 (`"1.1.3.60"`); `"bar.beat"` and `"bar"` also work. `step` is a 0-based index in `grid` steps and may be fractional (`2.5`).
- `pitch` is a MIDI number, a note name in Logic octaves (`"F1"`, `"Bb2"`, C3 = 60) or a drum name (`kick`, `snare`, `clap`, `rim`, `closed_hat`/`hh`, `open_hat`/`oh`, `pedal_hat`, `shaker`, `tamb`, `ride`, `crash`, `cowbell`, toms, congas, `clave`).
- `len` is in 16ths (`0.5`, `6`) or a note value: `"1/8"`, `"1/8."` (dotted), `"1/8t"` (triplet), `"2bars"`. Default is one 16th. `vel` is 1 to 127 (default 100).
- `chord` is a symbol: major, `m`, `dim`, `aug`, `sus2`, `sus4`, `5`, `6`, `m6`, `7`, `m7`, `maj7`, `mmaj7`, `dim7`, `m7b5`, `9`, `m9`, `maj9`, `11`, `m11`, `13`, `m13`, `add9`, `madd9`, `7sus4`, `m7sus4`, with alterations `b5 #5 b9 #9 #11 b13`. A slash adds a bass note one octave below the root octave (`"Fm7/C"`). `pitches` lists exact notes instead. `octave` is the root octave (default 2, so `Fm7` starts on F2).
- `voicing`: `close` (default), `dub` (open dub-techno stab), `spread`, `shell` (root, third, seventh), `rootless`. `inversion` 0 to 4 moves the lowest note up an octave; `strum` delays each note from low to high by that many ticks.
- `steps` lane keys are drum names, note names or MIDI numbers. Pattern characters: `x` hit, `X` accent, `o` soft, `g` ghost, `.` or `-` rest, `_` tie (extends the previous hit). Spaces and `|` are ignored, and the pattern repeats to fill `bars`.

Dub techno chord stab with drums:

```
logic_compose("write", {
  "name": "Dub techno stab and drums",
  "pattern_bars": 2,
  "bars": 8,
  "humanize": 0.15,
  "chords": [
    {
      "pos": "1.1.1",
      "chord": "Fm9",
      "voicing": "dub",
      "len": "1/16",
      "vel": 88
    },
    {
      "pos": "1.1.4",
      "chord": "Fm9",
      "voicing": "dub",
      "len": "1/16",
      "vel": 64
    },
    {
      "pos": "1.2.3",
      "chord": "Fm9",
      "voicing": "dub",
      "len": "1/16",
      "vel": 76
    },
    {
      "pos": "2.1.4",
      "chord": "Fm9",
      "voicing": "dub",
      "len": "1/16",
      "vel": 70
    },
    {
      "pos": "2.2.3",
      "chord": "Fm9",
      "voicing": "dub",
      "len": "1/16",
      "vel": 58
    }
  ],
  "steps": {
    "kick": {
      "pattern": "x...x...x...x...",
      "vel": 88
    },
    "hh": {
      "pattern": "..x...x...x...x.",
      "vel": 70
    }
  }
})
```

Deep house progression (i9, iv9) with a syncopated bassline:

```
logic_compose("write", {
  "name": "Deep house i9 - iv9",
  "pattern_bars": 4,
  "bars": 8,
  "swing": 0.2,
  "humanize": 0.1,
  "chords": [
    {
      "pos": "1.1.1",
      "chord": "Am9",
      "octave": 2,
      "voicing": "spread",
      "len": "1/1",
      "vel": 72,
      "vel_top": 80
    },
    {
      "pos": "2.1.1",
      "chord": "Dm9",
      "octave": 2,
      "voicing": "spread",
      "len": "1/1",
      "vel": 72,
      "vel_top": 80
    },
    {
      "pos": "3.1.1",
      "chord": "Am9",
      "octave": 2,
      "voicing": "spread",
      "len": "1/1",
      "vel": 72,
      "vel_top": 80
    },
    {
      "pos": "4.1.1",
      "chord": "Dm9",
      "octave": 2,
      "voicing": "spread",
      "len": "1/1",
      "vel": 72,
      "vel_top": 80
    }
  ],
  "notes": [
    {
      "pos": "1.1.1",
      "pitch": "A1",
      "len": "1/8",
      "vel": 100
    },
    {
      "pos": "1.2.3",
      "pitch": "A1",
      "len": "1/16",
      "vel": 80
    },
    {
      "pos": "1.3.2",
      "pitch": "E2",
      "len": "1/16",
      "vel": 70
    },
    {
      "pos": "1.4.3",
      "pitch": "A1",
      "len": "1/8",
      "vel": 90
    },
    {
      "pos": "2.1.1",
      "pitch": "D1",
      "len": "1/8",
      "vel": 100
    },
    {
      "pos": "2.2.3",
      "pitch": "D1",
      "len": "1/16",
      "vel": 80
    },
    {
      "pos": "2.3.2",
      "pitch": "A1",
      "len": "1/16",
      "vel": 70
    },
    {
      "pos": "2.4.3",
      "pitch": "D1",
      "len": "1/8",
      "vel": 90
    },
    {
      "pos": "3.1.1",
      "pitch": "A1",
      "len": "1/8",
      "vel": 100
    },
    {
      "pos": "3.2.3",
      "pitch": "A1",
      "len": "1/16",
      "vel": 80
    },
    {
      "pos": "3.3.2",
      "pitch": "E2",
      "len": "1/16",
      "vel": 70
    },
    {
      "pos": "3.4.3",
      "pitch": "A1",
      "len": "1/8",
      "vel": 90
    },
    {
      "pos": "4.1.1",
      "pitch": "D1",
      "len": "1/8",
      "vel": 100
    },
    {
      "pos": "4.2.3",
      "pitch": "D1",
      "len": "1/16",
      "vel": 80
    },
    {
      "pos": "4.3.2",
      "pitch": "A1",
      "len": "1/16",
      "vel": 70
    },
    {
      "pos": "4.4.3",
      "pitch": "D1",
      "len": "1/8",
      "vel": 90
    }
  ]
})
```

## Styles

Names are case-insensitive; the first style of each row is the default.

### Dub techno

| Part | Style | Description |
|------|-------|-------------|
| drums | `minimal` | Soft 4/4 kick, low offbeat hats, ghosted shaker 16ths, sparse rim |
| drums | `steppers` | 4/4 kick, rim on beat 3, 8th hats with open hat pickup |
| kick | `four_on_floor` | Steady 4/4 kick, optional ghost kick before beat 1 at high density |
| kick | `ghost` | 4/4 kick with ghost kicks leaning into the downbeat |
| hats | `shaker_offbeat` | Shaker 16ths with soft offbeat closed hats |
| hats | `offbeat` | Offbeat closed hats with occasional open hat |
| hats | `shaker` | Ghosted shaker 16ths only |
| bass | `offbeat` | Short sub notes on every 8th offbeat, monotone root, pumping against the kick |
| bass | `monotone_pulse` | Very sparse syncopated root pulses on the last 16th of the beat |
| bass | `sustain` | Long root notes, one per bar or two, with a slight retrigger |
| bass | `rolling` | Rolling 16ths with ghost velocities, root plus occasional octave or fifth |
| bass | `follow` | Plays only on the stab onsets (use with `complement`) |
| stabs | `dub_chord` | Sparse syncopated m7/m9/m7sus4 chord hits leaving space for the delay |
| stabs | `offbeat` | Chord hits on the offbeats (all or every other) |
| stabs | `dotted` | Dotted-8th spacing that locks with 3/16 delays |
| stabs | `polymeter` | 3- or 5-step cycle drifting against the 16-step bar |
| chords | `drone` | Sustained m9 chord over one or more bars, low velocity |
| chords | `swell` | Long overlapping notes with staggered re-entries |
| pad | `drone` | Very long, soft m9 drone |
| pad | `swell` | Slow overlapping swells with staggered re-entries |

### House and deep house

| Part | Style | Description |
|------|-------|-------------|
| drums | `classic` | 4/4 kick, clap on 2 and 4, open hat on offbeats, accented closed 16ths |
| drums | `deep` | Lighter kit: rim on 2 and 4, shuffled 16th hats, slight swing |
| drums | `garage` | Skippy kick variations, ghost claps, swung hats |
| kick | `four_on_floor` | Steady 4/4 kick |
| kick | `garage` | 4/4 kick with skippy extra hits |
| hats | `offbeat_open` | Open hats on the offbeats, soft closed hats on the beats |
| hats | `sixteenths` | Closed 16ths with velocity accents |
| hats | `shuffle` | Shuffled 16ths with accents on the swung 16ths |
| bass | `deep_groove` | Syncopated deep house bassline following an i-iv or i-VII progression |
| bass | `offbeat` | Offbeat 8th house bass on the root |
| bass | `octave_jump` | Root alternating low and high octave |
| bass | `rolling` | Rolling 16ths with ghost notes and octave accents |
| bass | `follow` | Plays only on the stab onsets (use with `complement`) |
| stabs | `chord_stab` | Syncopated m7 chord stabs over a short progression |
| stabs | `organ_stab` | M1-style organ stabs, m7/m9 over a 2-4 chord progression |
| stabs | `piano_stab` | Offbeat-heavy piano chord hits |
| chords | `deep_pad` | Whole-bar m9/maj7 chords: i9-iv9 or i9-VII-VI |
| chords | `progression` | One chord per bar from a genre-typical progression |
| pad | `deep_pad` | Soft, long-held m9 pad chords |

Aliases accepted by the generator: `monotone` and `pulse` (monotone_pulse), `dub` (dub_chord), `4x4` (four_on_floor), `pad` (deep_pad). Drum parts use General MIDI drum notes (kick 36, rim 37, clap 39, closed hat 42, open hat 46), which map to Logic's Drum Kit Designer and Drum Machine Designer.

## Installation

Requires macOS 14+ and Logic Pro 11 (English UI). Building needs Swift 6.0+.

### Build from source

```bash
git clone https://github.com/goldenlobster2019-bit/logic-groove-mcp.git
cd logic-groove-mcp
swift build -c release
# Binary: .build/release/LogicGrooveMCP
sudo install -m 0755 .build/release/LogicGrooveMCP /usr/local/bin/LogicGrooveMCP
```

### Install script

From a clone, `Scripts/install.sh` builds a universal binary, installs it to `/usr/local/bin` and registers it with Claude Code:

```bash
./Scripts/install.sh
```

Outside a clone it downloads the latest release binary and verifies its SHA-256 checksum. Releases are produced by the tag-triggered workflow in `.github/workflows/release.yml`; until a release exists, build from source.

### Register with Claude Code

```bash
claude mcp add --scope user logic-groove -- /usr/local/bin/LogicGrooveMCP
```

### Register with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "logic-groove": {
      "command": "/usr/local/bin/LogicGrooveMCP",
      "args": []
    }
  }
}
```

## Permissions

1. **Accessibility**: System Settings > Privacy & Security > Accessibility > add the app that launches the server (Terminal, Claude Desktop, your IDE).
2. **Automation**: System Settings > Privacy & Security > Automation > allow that app to control Logic Pro.

Check without starting the server:

```bash
LogicGrooveMCP --check-permissions
```

or call `logic_system("permissions", {})` from the assistant.

## Where files are stored

| Folder | Content |
|--------|---------|
| `~/Music/LogicGrooveMCP/Generated` | MIDI files written by `generate` and `complement` (`<timestamp>-<clip name>.mid`) |
| `~/Music/LogicGrooveMCP/Exports` | MIDI exported from the selected Logic region for `analyze_region` and `complement` |

Folders are created on demand. Nothing in your project is deleted by the server.

## Status and limitations

The music engine (MusicCore) is unit-tested on Linux and macOS CI. The Logic Pro automation is macOS-only and has been exercised only in a limited live session, so treat it as beta.

Worked in the author's live Logic session (one setup, not a test matrix): menu-based track creation, transport stop/play via keypad keys, MIDI import via File > Import > MIDI File, and reading the Edit menu's Undo title. The items below are the assumptions that still need confirmation on other setups.

Needs testing on more Macs and Logic versions:
- **Menu titles** are matched by English text (Logic Pro 11); other languages or versions may not match.
- **File panels in a sandboxed Logic**: import and export drive the open/save panel with Cmd+Shift+G and path entry; behavior may differ with sandboxed file access.
- **Import placement at the playhead**: the playhead is moved with Go To Position (`N.1.1.1`) before import; the result is reported as unverified because the outcome is not read back. Check the region landed at the intended bar.
- **Plugin slot detection**: slots are found in the Inspector channel strip through the Accessibility tree and the plugin is picked from the slot menu (search field or submenu walk). Results are reported as unverified; confirm the plugin loaded.
- **Tempo sheet**: the panel-close wait can treat a tempo sheet as an open panel, adding up to 3 seconds of delay.
- **Editor refresh and replace alert**: `refresh_editor` matches menu titles by prefix, and the "replace" alert search scans all windows.
- Piano Roll can stay on an old region; use `logic_navigate("refresh_editor")` or reopen the project.
- Logic exposes no programmatic API: UI paths change between versions, AX labels are localized, and OSC needs a manual Control Surface setup.

The server never clicks at screen coordinates.

## Architecture

```
Claude ── 9 dispatcher tools ──┐
       └─ 7 resources ─────────┤
                               ▼
        Dispatchers ──► ChannelRouter ──► CoreMIDI | Accessibility | CGEvent | AppleScript | OSC
             │
             └── MusicCore (pure Swift: theory, generators, analyzer, MIDI file I/O)
```

| Channel | Latency | Used for |
|---------|---------|----------|
| CoreMIDI | <1 ms | MMC transport, notes, CC, SysEx |
| Accessibility | ~15 ms | State reading, menus, file panels, plugin slots, region export |
| CGEvent | <2 ms | Keyboard shortcuts posted to the Logic process |
| AppleScript | ~200 ms | App lifecycle (launch, quit, open file) |
| OSC | <1 ms | Mixer control (needs Logic Control Surface setup) |

Each operation has a primary channel and fallbacks in a static routing table. A background poller keeps a state cache for the resources.

`Sources/MusicCore` depends on Foundation only. It builds and is tested on Linux; the server target is compiled only on macOS.

## Development

```bash
swift build            # on Linux this builds MusicCore only
swift test             # MusicCore tests on Linux; all tests on macOS
swift build -c release
.build/debug/LogicGrooveMCP --check-permissions
```

CI runs the full build and tests on macOS and the MusicCore tests on Linux for every push and pull request. See `CLAUDE.md` for contributor and AI-session notes and `docs/SKILL.md` for an agent skill that teaches an assistant the music workflow.

## Credits

Logic Groove MCP is a fork of [koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp) by Kolton Jacobs, which provides the channel architecture, dispatchers and state cache. The MusicCore engine, `logic_compose` tool and electronic music focus were added by Golden Lobster Studio.

## License

MIT. Copyright (c) 2025 Kolton Jacobs, (c) 2026 Golden Lobster Studio (Sorin Gheorghita). See [LICENSE](LICENSE).
