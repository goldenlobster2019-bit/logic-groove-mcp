import Foundation

/// Key / chord / rhythm analysis of existing MIDI material.
public enum Analyzer {

    // Krumhansl-Kessler key profiles (index 0 = tonic).
    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Keys whose correlation is within this margin of the best are considered ties,
    /// and the tie is broken in favour of the key whose tonic is the bass note.
    private static let tieMargin = 0.05
    /// Notes starting within this many ticks of the group's first note form one chord group.
    private static let groupWindow = 30

    public static func analyze(_ clips: [Clip]) -> ClipAnalysis {
        let notes = clips.flatMap { $0.notes }
        let length = clips.map { $0.lengthTicks }.max() ?? 0
        return analyze(Clip(name: "merged", notes: notes, lengthTicks: length))
    }

    public static func analyze(_ clip: Clip) -> ClipAnalysis {
        let notes = clip.notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        guard !notes.isEmpty else {
            return ClipAnalysis(
                keyName: "C minor", tonic: 0, isMinor: true, keyConfidence: 0, chords: [],
                onsetHistogram16: [Int](repeating: 0, count: 16), mainOnsetSteps: [],
                lowestPitch: 0, highestPitch: 0, noteCount: 0, lengthBars: clip.bars)
        }

        // Onset groups.
        var groups = [[NoteEvent]]()
        for n in notes {
            if let first = groups.last?.first, n.start - first.start <= groupWindow {
                groups[groups.count - 1].append(n)
            } else {
                groups.append([n])
            }
        }

        let key = detectKey(notes: notes, groups: groups)

        // Onset histogram.
        let bar = MusicCore.ticksPerBar()
        var hist = [Int](repeating: 0, count: 16)
        for g in groups {
            let step = (((g[0].start % bar) + bar) % bar + MusicCore.sixteenth / 2) / MusicCore.sixteenth % 16
            hist[step] += 1
        }
        let maxCount = hist.max() ?? 0
        let main = maxCount > 0 ? hist.indices.filter { hist[$0] * 2 >= maxCount } : []

        return ClipAnalysis(
            keyName: key.name, tonic: key.tonic, isMinor: key.minor, keyConfidence: key.confidence,
            chords: detectChords(groups), onsetHistogram16: hist, mainOnsetSteps: main,
            lowestPitch: notes.map { $0.pitch }.min() ?? 0, highestPitch: notes.map { $0.pitch }.max() ?? 0,
            noteCount: notes.count, lengthBars: clip.bars)
    }

    // MARK: - Key detection

    /// Key name. Tonics on pitch classes 1, 3, 8, 10 are spelled with flats (Db, Eb, Ab, Bb) in both modes;
    /// every other tonic uses its natural / sharp name (F major, F# for pc 6).
    static func keyName(tonic: PitchClass, minor: Bool) -> String {
        let flats: Set<Int> = [1, 3, 8, 10]
        return NoteName.pitchClassName(tonic, preferFlats: flats.contains(tonic)) + (minor ? " minor" : " major")
    }

    private static func detectKey(notes: [NoteEvent], groups: [[NoteEvent]])
        -> (name: String, tonic: PitchClass, minor: Bool, confidence: Double) {
        var hist = [Double](repeating: 0, count: 12)
        for n in notes {
            hist[((n.pitch % 12) + 12) % 12] += Double(max(n.duration, 1)) * Double(min(max(n.velocity, 1), 127)) / 127.0
        }

        var scored = [(tonic: Int, minor: Bool, corr: Double)]()
        for minor in [false, true] {
            let profile = minor ? minorProfile : majorProfile
            for t in 0..<12 {
                let rotated = (0..<12).map { profile[(($0 - t) % 12 + 12) % 12] }
                scored.append((t, minor, pearson(hist, rotated)))
            }
        }
        // Stable best: highest correlation, earliest in list on ties.
        var best = scored[0]
        for s in scored where s.corr > best.corr + 1e-12 { best = s }

        if let bass = bassTonic(groups: groups) {
            let close = scored.filter { $0.corr >= best.corr - tieMargin && $0.tonic == bass }
            if var pick = close.first {
                for s in close where s.corr > pick.corr + 1e-12 { pick = s }
                best = pick
            }
        }
        return (keyName(tonic: best.tonic, minor: best.minor), best.tonic, best.minor, min(max(best.corr, 0), 1))
    }

    /// Pitch class of the most frequent lowest-note-of-onset; ties go to the one with the lowest pitch.
    private static func bassTonic(groups: [[NoteEvent]]) -> PitchClass? {
        var counts = [Int: Int]()
        var lowest = [Int: Int]()
        for g in groups {
            guard let low = g.map({ $0.pitch }).min() else { continue }
            let pc = ((low % 12) + 12) % 12
            counts[pc, default: 0] += 1
            lowest[pc] = min(lowest[pc] ?? Int.max, low)
        }
        guard let maxCount = counts.values.max() else { return nil }
        return counts.filter { $0.value == maxCount }.keys.min { (lowest[$0] ?? 0) < (lowest[$1] ?? 0) }
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        let d = (sxx * syy).squareRoot()
        return d > 1e-12 ? sxy / d : 0
    }

    // MARK: - Chords

    private static func detectChords(_ groups: [[NoteEvent]]) -> [DetectedChord] {
        var order = [String]()
        var found = [String: DetectedChord]()
        for g in groups {
            let pitches = Array(Set(g.map { $0.pitch })).sorted()
            let pcSet = Set(pitches.map { (($0 % 12) + 12) % 12 })
            guard pcSet.count >= 2 else { continue }
            let (root, quality) = classify(pitches: pitches, pcSet: pcSet)
            let name = chordName(root: root, quality: quality)
            if var existing = found[name] {
                existing.occurrences += 1
                found[name] = existing
            } else {
                order.append(name)
                found[name] = DetectedChord(name: name, root: root, pitches: pitches, occurrences: 1)
            }
        }
        // Stable sort by occurrences descending (first-seen order breaks ties).
        return order.enumerated()
            .sorted { (found[$0.element]!.occurrences, -$0.offset) > (found[$1.element]!.occurrences, -$1.offset) }
            .map { found[$0.element]! }
    }

    private static func classify(pitches: [Int], pcSet: Set<PitchClass>) -> (PitchClass, ChordQuality) {
        // Candidate roots: bass pitch class first, then the rest in ascending pitch order.
        var roots = [PitchClass]()
        for p in pitches {
            let pc = ((p % 12) + 12) % 12
            if !roots.contains(pc) { roots.append(pc) }
        }
        for r in roots {
            for q in ChordQuality.all where q.pitchClassSet(root: r) == pcSet { return (r, q) }
        }
        var best: (PitchClass, ChordQuality, Double)?
        for r in roots {
            for q in ChordQuality.all {
                let set = q.pitchClassSet(root: r)
                let j = Double(set.intersection(pcSet).count) / Double(set.union(pcSet).count)
                if best == nil || j > best!.2 + 1e-12 { best = (r, q, j) }
            }
        }
        return (best!.0, best!.1)
    }
}
