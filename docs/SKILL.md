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
7. **Sound**: create a track first with `logic_tracks("create_instrument")` if needed, then `logic_mixer("insert_plugin", {track, slot: "instrument", name})`. Effects use slot 1+.
8. **Verify** every mutation: read `undo_label` in the result or call `logic_edit("last_undo")`; re-read `logic_system("state")`. Results marked unverified mean the action was performed but not confirmed. An `import_midi` result is an error unless its message says "verified"; its trace shows every step. Imports are staged through `~/Music/LogicGrooveMCP/Import/clip.mid` and are reported as errors unless the track count increased.
9. Report the seed so the user can reproduce or vary the clip.

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
