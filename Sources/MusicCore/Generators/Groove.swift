import Foundation

// Shared plumbing for the generators: tick constants, the per-request context,
// swing / humanize / clean-up pass, voice leading and complement interlocking.

enum GenTicks {
    static let bar = 1920
    static let beat = 480
    static let step = 120   // one 16th
}

struct ChordSpec: Sendable {
    var root: PitchClass
    var quality: ChordQuality
}

/// Everything a genre generator needs, resolved from the request (and optional analysis).
struct GenContext {
    let genre: Genre
    let part: Part
    let style: String
    let tonic: PitchClass
    let scale: Scale
    let octave: Int
    let octaveIsDefault: Bool
    let bars: Int
    let density: Double
    var swing: Double
    let humanize: Double
    var rng: SeededRandom
    /// 16th-step indices (0...15) of existing material, set by `complement`.
    var stabSteps: [Int]?
    /// First chord of existing material, set by `complement` (chord-based parts).
    var chordOverride: ChordSpec?

    var lengthTicks: Int { bars * GenTicks.bar }
    var rootPitch: Int { min(127, max(0, NoteName.pitch(pitchClass: tonic, octave: octave))) }
    var isDrumPart: Bool { part == .drums || part == .kick || part == .hats }

    func tick(_ bar: Int, _ step: Int) -> Int { bar * GenTicks.bar + step * GenTicks.step }

    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(rng.next() % UInt64(n)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    mutating func chance(_ p: Double) -> Bool { p <= 0 ? false : (p >= 1 ? true : rng.chance(p)) }

    /// Bass pitch variation: mostly the root; with probability `p` a fifth, octave or b7 below.
    mutating func varyBass(_ root: Int, probability p: Double) -> Int {
        guard p > 0, rng.chance(p) else { return root }
        let roll = rng.unit()
        if roll < 0.45 { return root + 7 }
        if roll < 0.75 { return root + 12 }
        return scale.snap(root - 2, tonic: tonic)
    }
}

func genNote(_ start: Int, _ duration: Int, _ pitch: Int, _ velocity: Int) -> NoteEvent {
    NoteEvent(start: start, duration: duration, pitch: pitch, velocity: velocity, channel: 1)
}

enum Groove {
    /// Swing, humanize, scale conformance, register folding, clamping, de-duplication.
    static func finalize(_ raw: [NoteEvent], _ c: inout GenContext) -> [NoteEvent] {
        let isDrum = c.isDrumPart
        let swingTicks = Int((c.swing * 0.4 * Double(GenTicks.step)).rounded())
        let anchors: Set<Int> = [DrumNote.kick, DrumNote.clap, DrumNote.snare]
        var out: [NoteEvent] = []
        out.reserveCapacity(raw.count)

        for var n in raw {
            // Backbeat anchors stay exactly on the grid.
            let anchored = isDrum && n.start % GenTicks.beat == 0 && anchors.contains(n.pitch)
            if swingTicks > 0, n.start % GenTicks.step == 0, (n.start / GenTicks.step) % 2 == 1 {
                n.start += swingTicks
            }
            if c.humanize > 0 {
                let ut = c.rng.unit()
                let uv = c.rng.unit()
                if !anchored { n.start += Int(((ut * 2 - 1) * c.humanize * 8).rounded()) }
                n.velocity += Int(((uv * 2 - 1) * c.humanize * 12).rounded())
            }
            if !isDrum {
                n.pitch = c.scale.snap(n.pitch, tonic: c.tonic)
                if c.part == .bass && c.octaveIsDefault {
                    while n.pitch >= 60 { n.pitch -= 12 }
                }
            }
            n.pitch = min(127, max(0, n.pitch))
            n.velocity = min(127, max(1, n.velocity))
            n.start = max(0, n.start)
            guard n.start < c.lengthTicks else { continue }
            n.duration = max(1, min(n.duration, c.lengthTicks - n.start))
            out.append(n)
        }

        // Merge exact duplicates (same start + pitch), keeping the louder/longer one.
        struct Key: Hashable { let start: Int; let pitch: Int }
        var index: [Key: Int] = [:]
        var merged: [NoteEvent] = []
        for n in out {
            let k = Key(start: n.start, pitch: n.pitch)
            if let i = index[k] {
                merged[i].velocity = max(merged[i].velocity, n.velocity)
                merged[i].duration = max(merged[i].duration, n.duration)
            } else {
                index[k] = merged.count
                merged.append(n)
            }
        }

        // Same-pitch overlaps (from humanize / swing) are trimmed so no note-off can cancel a later note-on.
        let order = merged.indices.sorted { (merged[$0].pitch, merged[$0].start) < (merged[$1].pitch, merged[$1].start) }
        for (a, b) in zip(order, order.dropFirst()) where merged[a].pitch == merged[b].pitch {
            if merged[a].end > merged[b].start {
                merged[a].duration = max(1, merged[b].start - merged[a].start)
            }
        }
        return merged
    }

    /// Voice-lead a chord: choose the inversion / octave whose mean pitch is closest to `target`.
    static func voiceLead(_ chord: [Int], target: Double) -> [Int] {
        guard !chord.isEmpty else { return chord }
        var cur = chord.sorted()
        var best = cur
        var bestCost = Double.infinity
        for _ in 0..<cur.count {
            for shift in [-12, 0, 12] {
                let cand = cur.map { $0 + shift }
                let mean = Double(cand.reduce(0, +)) / Double(cand.count)
                let cost = abs(mean - target)
                if cost < bestCost - 1e-9 { best = cand; bestCost = cost }
            }
            let first = cur.removeFirst()
            cur.append(first + 12)
        }
        return best.sorted()
    }

    static func mean(_ pitches: [Int]) -> Double {
        pitches.isEmpty ? 0 : Double(pitches.reduce(0, +)) / Double(pitches.count)
    }

    /// Derive a chord quality from detected pitches (falls back to m7 / maj7 / m).
    static func quality(of chord: DetectedChord) -> ChordQuality {
        let rel = Set(chord.pitches.map { (($0 - chord.root) % 12 + 12) % 12 })
        if let exact = ChordQuality.all.first(where: { $0.pitchClassSet(root: 0) == rel }) { return exact }
        let has3 = rel.contains(3), has4 = rel.contains(4), has10 = rel.contains(10), has11 = rel.contains(11)
        let sym: String
        if has3 { sym = has10 ? "m7" : "m" }
        else if has4 { sym = has11 ? "maj7" : (has10 ? "7" : "") }
        else { sym = "m7sus4" }
        return ChordQuality.named(sym) ?? ChordQuality.all[2]
    }
}

enum Interlock {
    /// Move bass notes that land on `avoid` steps onto a free neighbouring 16th (or drop them).
    /// Expects on-grid notes (before swing / humanize).
    static func avoid(_ notes: [NoteEvent], steps avoid: [Int]) -> [NoteEvent] {
        let blocked = Set(avoid)
        var out: [NoteEvent] = []
        for var n in notes {
            let bar = n.start / GenTicks.bar
            let step = (n.start % GenTicks.bar) / GenTicks.step
            guard n.start % GenTicks.step == 0, blocked.contains(step) else { out.append(n); continue }
            if let free = [step + 1, step - 1, step + 2].first(where: { $0 >= 0 && $0 < 16 && !blocked.contains($0) }) {
                n.start = bar * GenTicks.bar + free * GenTicks.step
                out.append(n)
            }
        }
        return out
    }
}
