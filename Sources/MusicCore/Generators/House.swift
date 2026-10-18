import Foundation

// House / deep house: 4/4 kick, clap backbeat, syncopated chord stabs and grooves in a dorian / minor key.

enum House {
    static func build(_ c: inout GenContext) -> [NoteEvent] {
        switch c.part {
        case .drums:
            if c.style == "garage" { c.swing = max(c.swing, 0.35) }
            else if c.style == "deep" { c.swing = max(c.swing, 0.15) }
            return drums(&c)
        case .kick:
            if c.style == "garage" { c.swing = max(c.swing, 0.35) }
            return kicks(&c, skippy: c.style == "garage")
        case .hats:
            if c.style == "shuffle" { c.swing = max(c.swing, 0.25) }
            return hats(&c)
        case .bass: return bass(&c)
        case .stabs: return stabs(&c)
        case .chords, .pad: return chordsPart(&c)
        }
    }

    // MARK: Drums

    private static func kicks(_ c: inout GenContext, skippy: Bool, velocity: Int = 112) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            for beat in 0..<4 {
                out.append(genNote(c.tick(bar, beat * 4), 90, DrumNote.kick, beat == 0 ? velocity : velocity - 6))
            }
            if !skippy {
                if c.density > 0.7, bar % 4 == 3 || c.chance(c.density - 0.6) {
                    out.append(genNote(c.tick(bar, 15), 60, DrumNote.kick, 46))
                }
            } else {
                if c.chance(c.density * 0.8) { out.append(genNote(c.tick(bar, c.pick([6, 7, 10])), 70, DrumNote.kick, 82)) }
                if c.chance(c.density * 0.5) { out.append(genNote(c.tick(bar, 15), 60, DrumNote.kick, 52)) }
            }
        }
        return out
    }

    private static func openOffbeats(_ c: GenContext, bar: Int, into out: inout [NoteEvent], velocity: Int = 82) {
        let vels = [velocity - 4, velocity + 4, velocity - 4, velocity + 8]
        for (i, s) in [2, 6, 10, 14].enumerated() {
            out.append(genNote(c.tick(bar, s), 200, DrumNote.openHat, vels[i]))
        }
    }

    /// Closed 16th hats. `skipOffbeats` leaves the 8th offbeats to the open hat.
    private static func closedSixteenths(_ c: inout GenContext, bar: Int, skipOffbeats: Bool, into out: inout [NoteEvent]) {
        for s in 0..<16 {
            if skipOffbeats && s % 4 == 2 { continue }
            let onBeat = s % 4 == 0
            let p = onBeat ? 1.0 : (s % 2 == 1 ? 0.25 + 0.75 * c.density : 0.7 + 0.3 * c.density)
            if !c.chance(p) { continue }
            let vel = onBeat ? 66 : (s % 4 == 2 ? 72 : 38 + (s % 4 == 3 ? 8 : 0) + c.int(8))
            out.append(genNote(c.tick(bar, s), 60, DrumNote.closedHat, vel))
        }
    }

    private static func shuffleHats(_ c: inout GenContext, bar: Int, into out: inout [NoteEvent]) {
        for s in 0..<16 {
            let p = s % 4 == 1 ? 0.3 + 0.7 * c.density : 1.0
            if !c.chance(p) { continue }
            let vel: Int
            switch s % 4 {
            case 3: vel = 72 + c.int(6)     // accented swung 16th
            case 2: vel = 56
            case 0: vel = 46
            default: vel = 34 + c.int(6)
            }
            out.append(genNote(c.tick(bar, s), 60, DrumNote.closedHat, vel))
        }
    }

    private static func hats(_ c: inout GenContext) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            switch c.style {
            case "sixteenths":
                closedSixteenths(&c, bar: bar, skipOffbeats: false, into: &out)
            case "shuffle":
                shuffleHats(&c, bar: bar, into: &out)
            default: // offbeat_open
                openOffbeats(c, bar: bar, into: &out)
                for s in [0, 4, 8, 12] where c.density >= 0.3 {
                    out.append(genNote(c.tick(bar, s), 60, DrumNote.closedHat, 44))
                }
                if c.density > 0.6 {
                    for s in [3, 7, 11, 15] where c.chance(c.density - 0.4) {
                        out.append(genNote(c.tick(bar, s), 50, DrumNote.closedHat, 36))
                    }
                }
            }
        }
        return out
    }

    private static func drums(_ c: inout GenContext) -> [NoteEvent] {
        var out = kicks(&c, skippy: c.style == "garage", velocity: c.style == "deep" ? 102 : 112)
        for bar in 0..<c.bars {
            switch c.style {
            case "deep":
                for s in [4, 12] {
                    out.append(genNote(c.tick(bar, s), 80, DrumNote.rim, 84))
                    if c.density > 0.5 { out.append(genNote(c.tick(bar, s), 100, DrumNote.clap, 48)) }
                }
                shuffleHats(&c, bar: bar, into: &out)
                if c.chance(c.density * 0.6) { out.append(genNote(c.tick(bar, 14), 200, DrumNote.openHat, 58)) }
            case "garage":
                for s in [4, 12] { out.append(genNote(c.tick(bar, s), 100, DrumNote.clap, 102)) }
                if c.chance(c.density * 0.6) { out.append(genNote(c.tick(bar, c.pick([7, 15])), 80, DrumNote.clap, 44)) }
                closedSixteenths(&c, bar: bar, skipOffbeats: false, into: &out)
                out.append(genNote(c.tick(bar, 10), 200, DrumNote.openHat, 72))
                if c.density > 0.5 { out.append(genNote(c.tick(bar, 14), 200, DrumNote.openHat, 66)) }
            default: // classic
                for s in [4, 12] { out.append(genNote(c.tick(bar, s), 100, DrumNote.clap, 104)) }
                openOffbeats(c, bar: bar, into: &out)
                closedSixteenths(&c, bar: bar, skipOffbeats: true, into: &out)
                if c.density > 0.55 {
                    for s in [7, 15] where c.chance(c.density - 0.5) {
                        out.append(genNote(c.tick(bar, s), 60, DrumNote.rim, 45))
                    }
                }
            }
        }
        return out
    }

    // MARK: Progressions

    /// Scale-degree roots (0 = i, 3 = iv, 5 = VI, 6 = VII) for common house progressions.
    private static let twoChord: [[Int]] = [[0, 3], [0, 6]]
    private static let fourChord: [[Int]] = [[0, 6, 5, 6], [0, 3, 6, 5], [0, 5, 3, 6], [0, 0, 6, 5]]

    private static func barsPerChord(_ n: Int) -> Int { max(1, 4 / max(1, n)) }

    // MARK: Bass

    private enum Kind: Int { case root = 0, fifth = 4, octave = 7, passDown = -1, passUp = 1 }
    private struct Hit { let step: Int; let len: Int; let kind: Kind }

    private static func bass(_ c: inout GenContext) -> [NoteEvent] {
        let root = c.rootPitch
        var out: [NoteEvent] = []
        switch c.style {
        case "offbeat":
            for bar in 0..<c.bars {
                for (i, s) in [2, 6, 10, 14].enumerated() {
                    let up = (i % 2 == 1) && c.chance(c.density * 0.3)
                    out.append(genNote(c.tick(bar, s), 190, up ? root + 12 : root, i == 3 ? 92 : 100))
                }
                if c.density > 0.45, c.chance(c.density) { out.append(genNote(c.tick(bar, 15), 90, root, 70)) }
                if c.density > 0.75, bar > 0 { out.append(genNote(c.tick(bar, 0), 100, root, 78)) }
            }
        case "octave_jump":
            let all8ths = c.density > 0.5
            for bar in 0..<c.bars {
                for s in stride(from: all8ths ? 0 : 2, to: 16, by: all8ths ? 2 : 4) {
                    let high = (s / 2) % 2 == 1
                    out.append(genNote(c.tick(bar, s), 190, high ? root + 12 : root, high ? 88 : 100))
                }
                if c.density > 0.85, c.chance(0.6) { out.append(genNote(c.tick(bar, 15), 80, root + 7, 64)) }
            }
        case "rolling":
            out = DubTechno.rolling(&c, root: root, onBeatProb: 0.1 + 0.3 * c.density,
                                    octaveProb: 0.15 + 0.25 * c.density, offDur: 200, ghostDur: 90)
        case "follow":
            let steps = c.stabSteps ?? [3, 6, 11]
            for bar in 0..<c.bars {
                for s in steps { out.append(genNote(c.tick(bar, s), 150, c.varyBass(root, probability: c.density * 0.1), 94)) }
            }
        default: // deep_groove
            out = deepGroove(&c)
        }
        return out
    }

    private static func deepGroove(_ c: inout GenContext) -> [NoteEvent] {
        let root = c.rootPitch
        let degrees = c.pick(twoChord)
        let perChord = barsPerChord(degrees.count)

        let sparse = [Hit(step: 0, len: 3, kind: .root), Hit(step: 6, len: 2, kind: .root), Hit(step: 10, len: 3, kind: .root)]
        let mid = [Hit(step: 0, len: 3, kind: .root), Hit(step: 3, len: 2, kind: .root), Hit(step: 6, len: 2, kind: .fifth),
                   Hit(step: 10, len: 2, kind: .root), Hit(step: 12, len: 3, kind: .octave)]
        let busy = [Hit(step: 0, len: 2, kind: .root), Hit(step: 3, len: 1, kind: .passDown), Hit(step: 4, len: 2, kind: .root),
                    Hit(step: 7, len: 2, kind: .fifth), Hit(step: 10, len: 1, kind: .root), Hit(step: 11, len: 2, kind: .passUp),
                    Hit(step: 14, len: 2, kind: .octave)]
        let template = c.density < 0.35 ? sparse : (c.density < 0.7 ? mid : busy)

        func chordRoot(_ degree: Int) -> (pitch: Int, shift: Int) {
            let raw = c.scale.pitch(degree: degree, tonicPitch: root)
            let shift = raw > root + 6 ? -12 : 0
            return (raw + shift, shift)
        }

        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            let segment = bar / perChord
            let degree = degrees[segment % degrees.count]
            let next = degrees[(segment + 1) % degrees.count]
            let lastOfSegment = (bar + 1) % perChord == 0
            let shift = chordRoot(degree).shift
            let approach = lastOfSegment && next != degree && c.density > 0.3
            for h in template {
                if approach && h.step >= 13 { continue }
                let pitch = c.scale.pitch(degree: degree + h.kind.rawValue, tonicPitch: root) + shift
                let vel = h.step == 0 ? 100 : (h.kind == .passDown || h.kind == .passUp ? 70 : 88)
                out.append(genNote(c.tick(bar, h.step), h.len * GenTicks.step - 10, pitch, vel))
            }
            if approach {
                let target = chordRoot(next)
                let pitch = c.scale.pitch(degree: next - 1, tonicPitch: root) + target.shift
                out.append(genNote(c.tick(bar, 14), 2 * GenTicks.step - 10, pitch, 80))
            }
        }
        return out
    }

    // MARK: Stabs

    private static func stabs(_ c: inout GenContext) -> [NoteEvent] {
        var pool = twoChord
        if c.density > 0.5 || c.style == "organ_stab" { pool += fourChord }
        let degrees = c.pick(pool)
        let perChord = barsPerChord(degrees.count)
        let noteCount = (c.style == "organ_stab" && c.density > 0.5) ? 5 : 4
        let voiced = voicedChords(&c, degrees: degrees, notes: noteCount, target: Double(c.rootPitch) + 12)

        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            let chord = voiced[(bar / perChord) % voiced.count]
            let steps: [Int]
            switch c.style {
            case "organ_stab":
                steps = c.density < 0.35 ? [3, 10] : (c.density < 0.7 ? [3, 6, 10, 11] : [3, 6, 10, 11, 14, 15])
            case "piano_stab":
                steps = c.density < 0.35 ? [6, 14] : (c.density < 0.7 ? [2, 6, 10, 14] : [2, 6, 10, 11, 14])
            default:
                steps = c.density < 0.35 ? [3, 10] : (c.density < 0.7 ? [3, 6, 10, 13] : [3, 6, 8, 10, 13, 15])
            }
            for (i, s) in steps.enumerated() {
                let dur: Int, vel: Int
                switch c.style {
                case "organ_stab": dur = 90; vel = 98 + c.int(5)
                case "piano_stab": dur = 190; vel = 68 + c.int(26)
                default: dur = 100; vel = i == 0 ? 98 : 82 + c.int(7)
                }
                for p in chord { out.append(genNote(c.tick(bar, s), dur, p, vel)) }
            }
        }
        return out
    }

    /// Diatonic chords (in the active scale) voice-led around `target`, or the analysed chord when complementing.
    private static func voicedChords(_ c: inout GenContext, degrees: [Int], notes: Int, target: Double) -> [[Int]] {
        if let o = c.chordOverride {
            let rootPitch = NoteName.pitch(pitchClass: o.root, octave: c.octave)
            return [Groove.voiceLead(Voicing.close(rootPitch: rootPitch, quality: o.quality), target: target)]
        }
        var result: [[Int]] = []
        var t = target
        for d in degrees {
            let raw = Voicing.diatonic(scale: c.scale, tonicPitch: c.rootPitch, degree: d, notes: notes)
            let v = Groove.voiceLead(raw, target: t)
            t = Groove.mean(v)
            result.append(v)
        }
        return result
    }

    // MARK: Chords / pads

    private static func chordsPart(_ c: inout GenContext) -> [NoteEvent] {
        let isPad = c.part == .pad
        let degrees: [Int]
        if c.style == "progression" {
            degrees = c.pick(fourChord + [[0, 3, 6, 5], [0, 6, 3, 5]])
        } else {
            degrees = c.pick([[0, 3], [0, 0, 6, 5], [0, 6, 5, 5]])
        }
        let perChord = barsPerChord(degrees.count) * (isPad ? 2 : 1)
        let noteCount = c.density > 0.4 ? 5 : 4
        let voiced = voicedChords(&c, degrees: degrees, notes: noteCount, target: Double(c.rootPitch) + 9)
        let base = isPad ? 44 : 60

        var out: [NoteEvent] = []
        var bar = 0
        var segment = 0
        while bar < c.bars {
            let n = min(perChord, c.bars - bar)
            var chord = voiced[segment % voiced.count]
            if c.density > 0.7, let low = chord.first { chord.append(low + 24) }
            for (i, p) in chord.enumerated() {
                out.append(genNote(c.tick(bar, 0), n * GenTicks.bar, p, base + (i == 0 ? 6 : c.int(8))))
            }
            bar += perChord
            segment += 1
        }
        return out
    }
}
