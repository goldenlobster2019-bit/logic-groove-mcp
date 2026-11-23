---
name: logic-groove
description: Use when producing house, deep house or dub techno in Logic Pro through the Logic Groove MCP server: generating drums, bass, stabs, chords and pads, analyzing existing regions, importing MIDI and loading plugins.
---

# Producing electronic music with Logic Groove MCP

## Workflow

1. **Health**: `logic_system("health")` and `logic_system("permissions")`. Fix Accessibility/Automation before anything else. Logic must be running with a project open.
2. **Look**: call `logic_system("state")` (project, transport, tracks, regions plus live track count and Undo title). The `logic://` resources (`logic://tracks`, `logic://transport/state`, `logic://project/info`) are an alternative where the client can read resources.
3. **Analyze** what the user already has: select the stab or chord region, then `logic_compose("analyze_region")`. Read key, chords and `main_onsets`.
4. **Pick the key**: take the analysis; otherwise the user's request; otherwise the genre default (dub techno F minor, deep house A minor, house A dorian).
5. **Generate or write**: `generate` for a quick starting point, `complement` for a part that must fit the selected region (bass avoids stab onsets; chords follow the detected chord). Choose a style from `logic_compose("styles", {genre, part})`. When the user describes a specific sound, rhythm or progression, use `write` instead (see "Writing parts from a description").
6. **Place**: use `at_bar` (default 1) and `loop: true` for repeating clips; or `import: false` and `import_midi` later.
7. **Sound**: create a track first with `logic_tracks("create_instrument")` if needed, then `logic_mixer("insert_plugin", {track, slot: "instrument", name})`. Effects: omit `slot` (or `"new"`) to ADD one, `slot: n` to REPLACE the n-th effect.
8. **Verify** every mutation: read `undo_label` in the result or call `logic_edit("last_undo")`; re-read `logic_system("state")`. Results marked unverified mean the action was performed but not confirmed. An `import_midi` result is an error unless its message says "verified"; its trace shows every step. Imports are staged through `~/Music/LogicGrooveMCP/Import/clip.mid` and are reported as errors unless the track count increased.
9. **Levels**: after building a loop call `logic_mixer("strip", {track})` for each track and read `master.peak_text` / `master.clipping`. When the master peak is above 0 dB, bring levels down with `logic_mixer("set_volume", {track, db: -6})` and `logic_mixer("set_master_volume", {db: -3})`, then call `strip` again.
10. Report the seed so the user can reproduce or vary the clip.

Rules:
- Never delete user material. Put new parts on new tracks. Mute instead of delete.
- Do not change the project tempo unless asked; pass `tempo` to `generate` only when the user wants it embedded.
- Do not use undo to "fix" a result unless `last_undo` shows it is your own action.
- Never improvise screen clicks; if a step fails, report the error text and ask.

## Writing parts from a description

Prefer `logic_compose("write", ...)` whenever the user describes a specific sound, rhythm, chord or progression that the fixed styles do not cover. `generate` is for quick starting points; `write` is for exactly what was asked. You specify the notes (`pos` as `bar.beat.16th`, pitch as note name or drum name, `len` in 16ths or `"1/8."`), chords (symbols such as `Fm9` with a `voicing`), and drum patterns as step strings (`x` hit, `X` accent, `o` soft, `g` ghost, `.` rest, `_` tie).

Working rules:
- Write a short pattern and tile it: `pattern_bars` (notes and chords) plus `bars`. Step patterns repeat on their own to fill `bars`.
- Preview first with `import: false`, read `warnings`, `range`, `preview_bar1` and `analysis`, then import with `import_midi` (or call `write` again with the same `seed`).
- You cannot hear the result. Use `analysis.key` and `analysis.chords` as a sanity check. A dub voicing without the root in the bass can read as the relative or dominant key (Fm9 stabs may analyze as C minor); judge by the chord names, or add the root with a slash bass (`"Fm9/F"`).
- Bass notes under chords: keep them below the chord register (chord root octave 2 means bass in octave 1) so same-pitch overlaps do not shorten the chord.
- `swing` and `humanize` work as in `generate`; leave them at 0 for exact grids.

Recipes (ready to send; change the key by changing the chord roots and note names):

1. Dub techno chord stab: one m9 chord, dub voicing, 2-3 hits per bar on dotted-8th positions, short, varied velocity.

```
logic_compose("write", {
  "name": "Dub stab Fm9",
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
  ]
})
```

2. Dub techno sub: offbeat 8ths on the root in octave 1, short (use `F0` for a deeper sub).

```
logic_compose("write", {
  "name": "Dub sub F",
  "bars": 8,
  "steps": {
    "F1": {
      "pattern": "..x...x...x...x.",
      "vel": 100,
      "len": "1/16"
    }
  }
})
```

3. Minimal dub techno drums: soft 4/4 kick, offbeat closed hat, ghost shaker 16ths, sparse rim (once every two bars).

```
logic_compose("write", {
  "name": "Dub drums minimal",
  "bars": 8,
  "humanize": 0.1,
  "steps": {
    "kick": {
      "pattern": "x...x...x...x...",
      "vel": 88
    },
    "hh": {
      "pattern": "..x...x...x...x.",
      "vel": 70
    },
    "shaker": "gggogggogggogggo",
    "rim": "........................x......."
  }
})
```

4. Deep house chords with a syncopated bassline: i9 - iv9, whole-bar spread voicings, bass in octave 1.

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

For a i9 - VII - VI feel, change the chord symbols to `Am9`, `Gmaj9`, `Fmaj9`, `Gmaj9` and move the bass note names to the same roots.

5. Classic house drums plus organ stab: kick on every beat, clap on 2 and 4, open hat on the offbeat, ghost hats, syncopated Am7 stab.

```
logic_compose("write", {
  "name": "House drums and organ stab",
  "pattern_bars": 1,
  "bars": 4,
  "humanize": 0.1,
  "chords": [
    {
      "step": 3,
      "chord": "Am7",
      "octave": 3,
      "len": "1/16",
      "vel": 98
    },
    {
      "step": 6,
      "chord": "Am7",
      "octave": 3,
      "len": "1/16",
      "vel": 84
    },
    {
      "step": 10,
      "chord": "Am7",
      "octave": 3,
      "len": "1/16",
      "vel": 92
    }
  ],
  "steps": {
    "kick": "x...x...x...x...",
    "clap": "....x.......x...",
    "oh": "..x...x...x...x.",
    "hh": ".g.g.g.g.g.g.g.g"
  }
})
```

## Sounds: Diva presets

Presets of u-he synths (default `Diva`) are chosen with `logic_sounds`, never by clicking in the plug-in. The synth loads up to 128 presets from its `MIDI Programs` folder when Logic starts (alphabetical, the first file is program 0) and selects them by Program Change.

1. Browse with `logic_sounds("folders")` and `logic_sounds("presets", { "query": "bass", "limit": 20 })` (filters `folder`, `category`).
2. Install a bank once: `logic_sounds("bank_install", { "presets": ["HS Stabz", "MK Bass Sub Tri", "IW Lush PWM Pad"] })`, then tell the user to QUIT AND REOPEN Logic Pro (the synth reads the bank only when the host starts). `logic_sounds("bank")` shows the programs and warns when the bank changed after Logic started.
3. For each track: `logic_mixer("insert_plugin", { "track": 2, "slot": "instrument", "name": "Diva" })`, then `logic_sounds("set_preset", { "track": 2, "preset": "HS Stabz" })`. `verified: false` means the Program Change was sent but the plug-in display cannot be read: say so and ask the user to listen.
4. Drums for house and dub techno: build them from the synth's percussive presets, ONE VOICE PER TRACK (kick, hats, clap), each written as pitched notes with `logic_compose("write", ...)`; the Ultrabeat init kit does not sound like house drums.
5. `at_bar` means "bar 1 of the clip goes here": the server adds the clip's leading empty bars itself (Logic drops them), so a clip whose notes start at bar 9 and is imported with `at_bar: 1` plays from bar 9. Read `leading_empty_bars` and `region_start_bar` in the result.
6. `logic_tracks` `mute`, `solo`, `rename` and `delete` now read their result back; `delete` needs `index`. `set_volume {db}` steps the fader and can take several seconds.

## Sounds and placement

Track placement, `kit`, `program` and `cc` are new in 0.4.0 and plug-in insert is verified for the instrument slot; the structural slots, `strip`, `bypass_plugin` and `set_volume {db}` are new in 0.4.1 and unverified (0.4.2 changed `set_volume {db}` to stepping and made placement use Cmd+X / Cmd+V) until the next live session: read the step trace in every result, and read `logic_system("state")` before and after each step (track count, track names, windows, undo title).

- **Put a clip on an existing track**: add `track` (0-based, same indexing as `state`) to `write`, `generate`, `complement` or `import_midi`. The import still creates a new track first; the server then cuts the region, deletes that empty track (only when its selection is read back), selects the target (read back), goes to `at_bar` and pastes. A region already at that position on the target is replaced where they overlap. If the result is an error, the `place` step says where it stopped (the region may be on the new track or on the clipboard).
- **Insert a plug-in**: `logic_mixer("insert_plugin", { "track": 2, "slot": "instrument", "name": "Diva" })`. `slot` is `"instrument"` (or 0) for the instrument, `"new"` / `"add"` / `"append"` (the default when `slot` is omitted) to ADD an effect in the empty slot (`{ "track": 2, "name": "Tape Delay" }`), or a number n >= 1 to REPLACE the n-th existing effect, top to bottom (`{ "track": 2, "slot": 1, "name": "Tape Delay" }` replaces effect 1; an n beyond the effect count means "new"). The command selects the track and reads the selection back; if that fails it refuses to act. It types the name in the slot menu's search field and presses Down, Right, Return, confirms by the new plug-in window and then by the channel strip structure; the message ends with `chain: <instrument> | <effects>`. Use `result_index` (extra Down presses when the first result is not the one) and `variant_index` (submenu entry; 1 = Stereo) when the default picks the wrong entry. A u-he demo notice lives inside the plug-in window, so closing the window (default) is enough.
- **See the strip**: `logic_mixer("strip", { "track": 2 })` returns JSON: instrument and effects top to bottom with their bypass state, `volume_text` (for example "0,0 dB", decimal comma), `peak_text`, `clipping`, and `master` (Stereo Out volume and peak). This is how you see levels.
- **Bypass**: `logic_mixer("bypass_plugin", { "track": 2, "plugin": "Chromaverb", "bypassed": true })` or `{ "slot": 0 }` (instrument) / `{ "slot": 2 }` (second effect). The checkbox is pressed only when the state differs and the result is read back.
- **Volume in dB**: `logic_mixer("set_volume", { "track": 2, "db": -6 })` and `logic_mixer("set_master_volume", { "db": -3 })` search the fader until the read-back level is within 0.15 dB (success within 0.3 dB). The old `value` 0.0-1.0 form still exists but is not reliable.
- **Ultrabeat drums**: Ultrabeat's init kit is not GM. Pass `"kit": "ultrabeat_init"` and keep using drum names: kick/bd = C#1 (37), snare/sd = D1 (38), closed_hat/ch/hh/hat = D#1 (39), open_hat/oh/hat2 = E1 (40), tom/low_tom/mid_tom/high_tom = F1 (41), clap/cp = F#1 (42), rim/perc/cowbell/clave/congas/tamb = G1 (43), shaker/sh/pedal_hat/ph = G#1 (44). ride, ride_bell and crash have no voice (error). The same spec works with `"kit": "gm"` (hat2 = 46, perc = 56, tom = 45).
- **Filter movement**: `cc` lanes, for example `{ "cc": [{ "cc": 1, "points": [{ "pos": "1.1.1", "value": 20 }, { "pos": "9.1.1", "value": 110 }] }] }`. Many Diva presets map the mod wheel (CC 1) to cutoff or resonance; check the preset. Linear lanes emit an event every `resolution` 16ths (0.25 to 4, default 0.5); `"curve": "step"` emits only at the points. Lanes cover the whole clip (not tiled by `pattern_bars`).
- **Program change**: `"program": 12` is only useful once the instrument maps program changes (for example u-he presets in the MIDI Programs folder).
- **Cycle to the regions**: `logic_transport("cycle_to_regions")` selects all regions and sets and enables the cycle over them. `set_cycle_range` is not implemented.
- **Typical order**: write the clip with `track`, insert instruments and effects, `cycle_to_regions`, play. Lower the levels afterwards if the Stereo Out clips.

## Genre cheat sheet

| Genre | Tempo | Typical keys | Character |
|-------|-------|--------------|-----------|
| House | 120-128 BPM | A, F, G minor/dorian | Straight 4/4 kick, clap on 2 and 4, open hat on the offbeat, organ or piano stabs, offbeat or syncopated bass |
| Deep house | 118-124 BPM | A, D, F minor | Same grid, softer. m7/m9 progressions (i9-iv9, i9-VII-VI), warm pads, shuffled hats, swing 0.1-0.3 |
| Dub techno | 118-126 BPM | F, G, A minor (often a single chord) | Soft 4/4 kick, one chord with a delayed stab, lots of space, offbeat or sparse sub, shaker/hat texture, long drones |

Style guidance:
- **Dub techno**: stabs `dub_chord` with low density leave room for the delay; keep to one chord. Bass `offbeat` for the classic pumping sub, `monotone_pulse` for minimal pulses, `sustain` under drones. Drums `minimal`; `steppers` for a more driving feel. Pad/chords `drone` or `swell`.
- **Deep house**: chords `deep_pad` or `progression`, stabs `chord_stab` or `piano_stab`, bass `deep_groove`, drums `deep`, hats `shuffle`. Use scale `minor`, swing 0.15-0.25.
- **House**: drums `classic`, hats `offbeat_open`, bass `offbeat` or `octave_jump`, stabs `organ_stab`. Use scale `dorian`. `garage` styles for skippy UK-flavored grooves.
- Use bass `follow` with `complement` to play only on the stab hits; otherwise complement keeps bass off the stab onsets.

## Parameter guidance

- `density` 0-1 (default 0.5): 0.2-0.35 sparse and dubby, 0.5 normal, 0.7+ busy. Low density for stabs and bass in dub techno.
- `swing` 0-1: 0 straight (techno, dub techno), 0.1-0.3 deep house, 0.2-0.4 garage/shuffle. Above 0.5 is extreme.
- `humanize` 0-1 (default 0.2): 0.1-0.3 for tight electronic feel, 0.4+ for loose live feel. Keep drums lower than pads.
- `seed`: omit to explore; reuse a seed to reproduce, then change one parameter at a time to compare. Always tell the user the seed.
- `bars`: 4 or 8 for loops, 1-2 for one-shots; max 64. `octave`: bass defaults to 1, others 2 (C3 = 60).
- `tempo`: written to the MIDI file only if given.

## Troubleshooting

- **Piano Roll shows an old region**: `logic_navigate("refresh_editor")`; if still stuck, save and reopen the project.
- **Clicking regions creates automation nodes**: automation view is on. Turn it off (toggle automation view in the Mix/View menu) and undo the stray nodes with `logic_edit("undo")` after checking `last_undo`.
- **Tempo dialog appears on import**: a MIDI file with tempo meta triggers Logic's tempo import question. Generate without `tempo`; dismiss the dialog manually if it is open. Panel waits may take up to 3 s longer.
- **Plugin demo nag** (u-he and others): a modal demo dialog blocks further automation. Ask the user to dismiss it, then retry.
- **Import landed at the wrong bar or nothing appeared**: check `undo_label` and `logic_system("state")`; move the region or retry `import_midi` with `at_bar`.
- **Plugin did not load** (result unverified): look at the channel strip or `logic://mixer`, retry with the exact name from Logic's plugin menu.
- **Permission errors**: grant Accessibility and Automation to the app that launched the server, then restart it.
- **File panel problems**: ensure Logic is frontmost and no other sheet or dialog is open.
