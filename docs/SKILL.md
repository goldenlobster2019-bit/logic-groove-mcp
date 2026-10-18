---
name: logic-groove
description: Use when producing house, deep house or dub techno in Logic Pro through the Logic Groove MCP server: generating drums, bass, stabs, chords and pads, analyzing existing regions, importing MIDI and loading plugins.
---

# Producing electronic music with Logic Groove MCP

## Workflow

1. **Health**: `logic_system("health")` and `logic_system("permissions")`. Fix Accessibility/Automation before anything else. Logic must be running with a project open.
2. **Look**: read `logic://tracks`, `logic://transport/state`, `logic://project/info` (tempo, existing tracks).
3. **Analyze** what the user already has: select the stab or chord region, then `logic_compose("analyze_region")`. Read key, chords and `main_onsets`.
4. **Pick the key**: take the analysis; otherwise the user's request; otherwise the genre default (dub techno F minor, deep house A minor, house A dorian).
5. **Generate**: `generate` for a fresh part, `complement` for a part that must fit the selected region (bass avoids stab onsets; chords follow the detected chord). Choose a style from `logic_compose("styles", {genre, part})`.
6. **Place**: use `at_bar` (default 1) and `loop: true` for repeating clips; or `import: false` and `import_midi` later.
7. **Sound**: create a track first with `logic_tracks("create_instrument")` if needed, then `logic_mixer("insert_plugin", {track, slot: "instrument", name})`. Effects use slot 1+.
8. **Verify** every mutation: read `undo_label` in the result or call `logic_edit("last_undo")`; re-read `logic://tracks`. Results marked unverified mean the action was performed but not confirmed.
9. Report the seed so the user can reproduce or vary the clip.

Rules:
- Never delete user material. Put new parts on new tracks. Mute instead of delete.
- Do not change the project tempo unless asked; pass `tempo` to `generate` only when the user wants it embedded.
- Do not use undo to "fix" a result unless `last_undo` shows it is your own action.
- Never improvise screen clicks; if a step fails, report the error text and ask.

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
- **Import landed at the wrong bar or nothing appeared**: check `undo_label` and the tracks resource; move the region or retry `import_midi` with `at_bar`.
- **Plugin did not load** (result unverified): look at the channel strip or `logic://mixer`, retry with the exact name from Logic's plugin menu.
- **Permission errors**: grant Accessibility and Automation to the app that launched the server, then restart it.
- **File panel problems**: ensure Logic is frontmost and no other sheet or dialog is open.
