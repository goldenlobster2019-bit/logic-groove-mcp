import Foundation

// Dub techno: one chord, lots of space, sub-heavy offbeat pulse, delay-friendly stabs.

enum DubTechno {
    static func build(_ c: inout GenContext) -> [NoteEvent] {
        switch c.part {
        case .drums: return drums(&c)
        case .kick: return kicks(&c, ghostMode: c.style == "ghost")
        case .hats: return hats(&c)
        case .bass: return bass(&c)
        case .stabs: return stabs(&c)
        case .chords: return pads(&c, padMode: false)
        case .pad: return pads(&c, padMode: true)
        }
    }

    // MARK: Drums

    private static func kicks(_ c: inout GenContext, ghostMode: Bool) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            for beat in 0..<4 {
                out.append(genNote(c.tick(bar, beat * 4), 90, DrumNote.kick, beat == 0 ? 112 : 104))
            }
            if ghostMode {
                out.append(genNote(c.tick(bar, 15), 60, DrumNote.kick, 44))
                if c.chance(c.density) { out.append(genNote(c.tick(bar, 7), 60, DrumNote.kick, 36)) }
            } else if c.density > 0.6, bar % 4 == 3 || c.chance((c.density - 0.5) * 1.4) {
                out.append(genNote(c.tick(bar, 15), 60, DrumNote.kick, 42))
            }
        }
        return out
    }

    private static func offbeatHats(_ c: GenContext, bar: Int, into out: inout [NoteEvent]) {
        let vels = [58, 52, 58, 52]
        for (i, s) in [2, 6, 10, 14].enumerated() {
            out.append(genNote(c.tick(bar, s), 70, DrumNote.closedHat, vels[i]))
        }
    }

    private static func shaker(_ c: inout GenContext, bar: Int, into out: inout [NoteEvent]) {
        for s in 0..<16 {
            let onBeat = s % 4 == 0
            let off8 = s % 4 == 2
            let p = onBeat ? 0.5 + 0.4 * c.density : (off8 ? 1.0 : 0.3 + 0.65 * c.density)
            if !c.chance(p) { continue }
            let vel = onBeat ? 34 : (off8 ? 62 : 42 + c.int(10))
            out.append(genNote(c.tick(bar, s), 70, DrumNote.shaker, vel))
        }
    }

    private static func hats(_ c: inout GenContext) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            switch c.style {
            case "offbeat":
                offbeatHats(c, bar: bar, into: &out)
                if c.chance(c.density * 0.8) { out.append(genNote(c.tick(bar, 14), 200, DrumNote.openHat, 50)) }
            case "shaker":
                shaker(&c, bar: bar, into: &out)
            default:
                offbeatHats(c, bar: bar, into: &out)
                shaker(&c, bar: bar, into: &out)
            }
        }
        return out
    }

    private static func drums(_ c: inout GenContext) -> [NoteEvent] {
        var out = kicks(&c, ghostMode: false)
        for bar in 0..<c.bars {
            if c.style == "steppers" {
                out.append(genNote(c.tick(bar, 8), 80, DrumNote.rim, 84))
                if c.density > 0.5 { out.append(genNote(c.tick(bar, 8), 80, DrumNote.snare, 46)) }
                for s in stride(from: 0, to: 16, by: 2) {
                    if s == 14 && c.density > 0.3 {
                        out.append(genNote(c.tick(bar, s), 220, DrumNote.openHat, 62))
                    } else {
                        out.append(genNote(c.tick(bar, s), 70, DrumNote.closedHat, s % 4 == 2 ? 60 : 38))
                    }
                }
                if c.density > 0.6 { shaker(&c, bar: bar, into: &out) }
            } else {
                offbeatHats(c, bar: bar, into: &out)
                shaker(&c, bar: bar, into: &out)
                if c.chance(c.density * 0.35) {
                    out.append(genNote(c.tick(bar, c.pick([3, 7, 11, 13])), 60, DrumNote.rim, 48 + c.int(20)))
                }
            }
        }
        return out
    }

    // MARK: Bass

    private static func bass(_ c: inout GenContext) -> [NoteEvent] {
        let root = c.rootPitch
        var out: [NoteEvent] = []
        switch c.style {
        case "monotone_pulse":
            let order = [3, 11, 7, 15]
            let count = 1 + Int((c.density * 3).rounded())
            for bar in 0..<c.bars {
                for (i, s) in order.prefix(count).enumerated() {
                    let p = c.varyBass(root, probability: c.density * 0.1)
                    out.append(genNote(c.tick(bar, s), 170, p, i == count - 1 && count > 2 ? 70 : 92))
                }
            }
        case "sustain":
            let span = c.density > 0.5 ? 1 : 2
            var bar = 0
            while bar < c.bars {
                let len = min(span, c.bars - bar) * GenTicks.bar
                let start = c.tick(bar, 0)
                if c.density > 0.75 && len >= GenTicks.bar {
                    out.append(genNote(start, len / 2 - 20, root, 96))
                    out.append(genNote(start + len / 2, len / 2 - 30, root, 84))
                } else {
                    out.append(genNote(start, len - 30, root, 96))
                }
                bar += span
            }
        case "rolling":
            out = rolling(&c, root: root, onBeatProb: 0.25 * c.density, octaveProb: 0.15 * c.density,
                          offDur: 110, ghostDur: 80)
        case "follow":
            let steps = c.stabSteps ?? [3, 6, 11]
            for bar in 0..<c.bars {
                for s in steps {
                    out.append(genNote(c.tick(bar, s), 110, c.varyBass(root, probability: c.density * 0.1), 90))
                }
            }
        default: // offbeat
            let vels = [92, 84, 88, 84]
            for bar in 0..<c.bars {
                for (i, s) in [2, 6, 10, 14].enumerated() {
                    let p = c.varyBass(root, probability: c.density * 0.25)
                    out.append(genNote(c.tick(bar, s), 110, p, vels[i]))
                }
                if c.density > 0.45, bar % 2 == 1 || c.chance(c.density - 0.45) {
                    out.append(genNote(c.tick(bar, 15), 90, root, 64))
                }
            }
        }
        return out
    }

    /// Shared rolling-16ths bass (also used by House): offbeat 8ths accented, other 16ths ghosted.
    static func rolling(_ c: inout GenContext, root: Int, onBeatProb: Double, octaveProb: Double,
                        offDur: Int, ghostDur: Int) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for bar in 0..<c.bars {
            for s in 0..<16 {
                let onBeat = s % 4 == 0
                let off8 = s % 4 == 2
                let p = off8 ? 1.0 : (onBeat ? onBeatProb : 0.35 + 0.6 * c.density)
                if !c.chance(p) { continue }
                var pitch = root
                if c.chance(octaveProb) { pitch = root + 12 }
                else if s == 14, c.chance(c.density * 0.2) { pitch = root + 7 }
                let vel = off8 ? 98 : (onBeat ? 46 : 52 + c.int(14))
                out.append(genNote(c.tick(bar, s), off8 ? offDur : ghostDur, pitch, vel))
            }
        }
        return out
    }

    // MARK: Chords (stabs / pads)

    /// One static chord with optional phrase-end movement (m7 -> m7sus4, or the chord a 4th up).
    struct ChordPlan {
        var root: Int
        var quality: ChordQuality
        var fourth: ChordQuality
        var sus: ChordQuality
        var movement: [Int] = []   // per 4-bar phrase: 0 none, 1 sus, 2 a 4th up
        var fixed = false

        init(_ c: inout GenContext, pad: Bool) {
            let minorish = c.scale.isMinor
            func q(_ n: String) -> ChordQuality { ChordQuality.named(n) ?? ChordQuality.all[2] }
            if let o = c.chordOverride {
                root = NoteName.pitch(pitchClass: o.root, octave: c.octave)
                quality = o.quality; fourth = o.quality; sus = o.quality
                fixed = true
                return
            }
            root = c.rootPitch
            let names = minorish ? (pad ? ["m9", "m7", "m7sus4"] : ["m7", "m9", "m7sus4"]) : ["maj7", "maj9", "sus2"]
            quality = q(c.pick(names))
            sus = q(minorish ? "m7sus4" : "sus2")
            fourth = q(minorish ? "m7" : "maj7")
            for _ in 0..<((c.bars + 3) / 4) {
                if c.density > 0.8 { movement.append(c.chance(0.5) ? 2 : 1) }
                else if c.density > 0.6 { movement.append(c.chance(0.7) ? 1 : 0) }
                else { movement.append(0) }
            }
        }

        func chord(bar: Int, voicing: (Int, ChordQuality) -> [Int]) -> [Int] {
            guard !fixed, bar % 4 == 3, bar / 4 < movement.count else { return voicing(root, quality) }
            switch movement[bar / 4] {
            case 1: return voicing(root, sus)
            case 2: return voicing(root + 5, fourth)
            default: return voicing(root, quality)
            }
        }
    }

    private static func stabs(_ c: inout GenContext) -> [NoteEvent] {
        let plan = ChordPlan(&c, pad: false)
        let voicing: (Int, ChordQuality) -> [Int] = { Voicing.dubStab(rootPitch: $0, quality: $1) }
        var out: [NoteEvent] = []

        func add(_ tick: Int, _ dur: Int, _ vel: Int) {
            for p in plan.chord(bar: tick / GenTicks.bar, voicing: voicing) {
                out.append(genNote(tick, dur, p, vel))
            }
        }

        switch c.style {
        case "offbeat":
            let steps = c.density < 0.5 ? [2, 10] : [2, 6, 10, 14]
            for bar in 0..<c.bars {
                for (i, s) in steps.enumerated() { add(c.tick(bar, s), 110, i % 2 == 0 ? 88 : 76) }
            }
        case "dotted":
            let spacing = c.density < 0.5 ? 720 : 360
            var t = 240, k = 0
            while t < c.lengthTicks {
                add(t, 100, k % 2 == 0 ? 90 : 72)
                t += spacing; k += 1
            }
        case "polymeter":
            let spacing = (c.density > 0.75 ? 3 : 5) * GenTicks.step
            var t = 0
            while t < c.lengthTicks {
                add(t, 100, t % GenTicks.beat == 0 ? 92 : 74)
                t += spacing
            }
        default: // dub_chord
            for bar in 0..<c.bars {
                var steps: [Int]
                if c.density < 0.25 { steps = [2, 10] }
                else if c.density < 0.55 { steps = [3, 6, 11] }
                else if c.density < 0.8 { steps = [3, 6, 11, 14] }
                else { steps = [3, 6, 10, 11, 14] }
                if bar % 2 == 1, c.density >= 0.25, c.density < 0.55, c.chance(0.3) { steps = [3, 7, 11] }
                for (i, s) in steps.enumerated() {
                    add(c.tick(bar, s), i == 0 ? 220 : 110, i == 0 ? 92 : 74 + c.int(9))
                }
            }
        }
        return out
    }

    private static func pads(_ c: inout GenContext, padMode: Bool) -> [NoteEvent] {
        let plan = ChordPlan(&c, pad: true)
        let voicing: (Int, ChordQuality) -> [Int] = { Voicing.close(rootPitch: $0, quality: $1) }
        let base = padMode ? 42 : 54
        var out: [NoteEvent] = []

        if c.style == "swell" {
            let period = min(c.bars, c.density > 0.6 ? 2 : 4) * GenTicks.bar
            var t = 0
            while t < c.lengthTicks {
                let tones = plan.chord(bar: t / GenTicks.bar + period / GenTicks.bar - 1, voicing: voicing)
                for (i, p) in tones.enumerated() {
                    let isA = i % 2 == 0
                    let start = t + (isA ? 0 : period / 2)
                    out.append(genNote(start, period, p, base + (isA ? 0 : 8)))
                }
                if c.density > 0.6, let r = tones.first { out.append(genNote(t, period, r + 12, base - 6)) }
                t += period
            }
        } else {
            let span = padMode ? (c.density > 0.5 ? 2 : 4) : (c.density > 0.66 ? 1 : (c.density > 0.33 ? 2 : 4))
            var bar = 0
            while bar < c.bars {
                let n = min(span, c.bars - bar)
                var tones = plan.chord(bar: bar + span - 1, voicing: voicing)
                if c.density > 0.6, let r = tones.first { tones.append(r + 17) }
                for (i, p) in tones.enumerated() {
                    out.append(genNote(c.tick(bar, 0), n * GenTicks.bar, p, base + (i == 0 ? 8 : c.int(6))))
                }
                bar += span
            }
        }
        return out
    }
}
