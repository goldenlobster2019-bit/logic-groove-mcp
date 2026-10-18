import Foundation

// MARK: - Note names (Logic convention: C3 = 60, C1 = 36, C-2 = 0)

public enum NoteName {
    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let flatNames  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// Pitch class of a note name without octave: "F" -> 5, "Bb" -> 10, "f#" -> 6. nil if invalid.
    public static func pitchClass(_ name: String) -> PitchClass? {
        let s = name.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first).uppercased()] else {
            return nil
        }
        var pc = base
        for ch in s.dropFirst() {
            switch ch {
            case "#", "♯": pc += 1
            case "b", "♭": pc -= 1
            default: return nil
            }
        }
        return ((pc % 12) + 12) % 12
    }

    /// MIDI pitch for a pitch class + Logic octave number (C3 = 60).
    public static func pitch(pitchClass: PitchClass, octave: Int) -> Int {
        (octave + 2) * 12 + pitchClass
    }

    /// Parse "F1", "C#3", "Bb-1" into a MIDI pitch (Logic convention). nil if invalid / out of range.
    public static func pitch(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let idx = s.firstIndex(where: { $0.isNumber || $0 == "-" }), idx != s.startIndex else { return nil }
        guard let pc = pitchClass(String(s[..<idx])), let oct = Int(s[idx...]) else { return nil }
        let p = pitch(pitchClass: pc, octave: oct)
        return (0...127).contains(p) ? p : nil
    }

    /// "F1" for 41. Uses sharps unless `preferFlats`.
    public static func name(_ pitch: Int, preferFlats: Bool = false) -> String {
        let pc = ((pitch % 12) + 12) % 12
        let octave = pitch / 12 - 2
        return (preferFlats ? flatNames : sharpNames)[pc] + String(octave)
    }

    public static func pitchClassName(_ pc: PitchClass, preferFlats: Bool = false) -> String {
        (preferFlats ? flatNames : sharpNames)[((pc % 12) + 12) % 12]
    }
}

// MARK: - Scales

public struct Scale: Equatable, Sendable {
    public let name: String
    /// Semitone offsets from the tonic, ascending, starting with 0.
    public let intervals: [Int]

    public static let all: [Scale] = [
        Scale(name: "minor", intervals: [0, 2, 3, 5, 7, 8, 10]),          // aeolian
        Scale(name: "dorian", intervals: [0, 2, 3, 5, 7, 9, 10]),
        Scale(name: "phrygian", intervals: [0, 1, 3, 5, 7, 8, 10]),
        Scale(name: "major", intervals: [0, 2, 4, 5, 7, 9, 11]),
        Scale(name: "mixolydian", intervals: [0, 2, 4, 5, 7, 9, 10]),
        Scale(name: "harmonic_minor", intervals: [0, 2, 3, 5, 7, 8, 11]),
        Scale(name: "minor_pentatonic", intervals: [0, 3, 5, 7, 10]),
        Scale(name: "major_pentatonic", intervals: [0, 2, 4, 7, 9]),
    ]

    /// Lookup by name (case-insensitive; "aeolian" = "minor", "ionian" = "major").
    public static func named(_ name: String) -> Scale? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "_")
        let alias = ["aeolian": "minor", "natural_minor": "minor", "ionian": "major", "min": "minor", "maj": "major"][n] ?? n
        return all.first { $0.name == alias }
    }

    public var isMinor: Bool { intervals.contains(3) }

    /// Pitch classes of the scale for a tonic.
    public func pitchClasses(tonic: PitchClass) -> [PitchClass] {
        intervals.map { (tonic + $0) % 12 }
    }

    /// MIDI pitch of scale degree `degree` (0-based, may exceed count / be negative) above tonic pitch.
    public func pitch(degree: Int, tonicPitch: Int) -> Int {
        let n = intervals.count
        let octaveShift = Int((Double(degree) / Double(n)).rounded(.down))
        let idx = ((degree % n) + n) % n
        return tonicPitch + octaveShift * 12 + intervals[idx]
    }

    /// Snap a pitch to the nearest scale tone (ties go down).
    public func snap(_ pitch: Int, tonic: PitchClass) -> Int {
        let pcs = Set(pitchClasses(tonic: tonic))
        for d in 0...6 {
            if pcs.contains(((pitch - d) % 12 + 12) % 12) { return pitch - d }
            if pcs.contains(((pitch + d) % 12 + 12) % 12) { return pitch + d }
        }
        return pitch
    }
}

// MARK: - Chords

public struct ChordQuality: Equatable, Sendable {
    public let symbol: String       // "m7"
    public let intervals: [Int]     // from root, e.g. [0, 3, 7, 10]

    public static let all: [ChordQuality] = [
        ChordQuality(symbol: "m", intervals: [0, 3, 7]),
        ChordQuality(symbol: "", intervals: [0, 4, 7]),
        ChordQuality(symbol: "m7", intervals: [0, 3, 7, 10]),
        ChordQuality(symbol: "maj7", intervals: [0, 4, 7, 11]),
        ChordQuality(symbol: "7", intervals: [0, 4, 7, 10]),
        ChordQuality(symbol: "m9", intervals: [0, 3, 7, 10, 14]),
        ChordQuality(symbol: "m11", intervals: [0, 3, 7, 10, 14, 17]),
        ChordQuality(symbol: "maj9", intervals: [0, 4, 7, 11, 14]),
        ChordQuality(symbol: "sus2", intervals: [0, 2, 7]),
        ChordQuality(symbol: "sus4", intervals: [0, 5, 7]),
        ChordQuality(symbol: "m7sus4", intervals: [0, 5, 7, 10]),   // classic "minor 7 sus" dub chord colour
        ChordQuality(symbol: "5", intervals: [0, 7]),
        ChordQuality(symbol: "dim", intervals: [0, 3, 6]),
        ChordQuality(symbol: "m(add9)", intervals: [0, 3, 7, 14]),
    ]

    public static func named(_ symbol: String) -> ChordQuality? {
        let s = symbol == "min" ? "m" : symbol == "maj" ? "" : symbol
        return all.first { $0.symbol == s }
    }

    /// Pitch-class set (mod 12) of this quality on a root.
    public func pitchClassSet(root: PitchClass) -> Set<PitchClass> {
        Set(intervals.map { (root + $0) % 12 })
    }
}

public enum Voicing {
    /// Close voicing: root at `rootPitch`, intervals stacked as defined.
    public static func close(rootPitch: Int, quality: ChordQuality) -> [Int] {
        quality.intervals.map { rootPitch + $0 }
    }

    /// Dub-techno stab voicing: open, root-less-ish top structure that leaves the low end to the sub.
    /// For minor qualities gives e.g. Fm7 at octave 2/3 as [F2, C3, Eb3, Ab3] (root, 5th, b7, b3 up an octave).
    public static func dubStab(rootPitch: Int, quality: ChordQuality) -> [Int] {
        let iv = quality.intervals
        var notes = [rootPitch]
        if iv.contains(7) { notes.append(rootPitch + 7) }
        if let seventh = iv.first(where: { $0 == 10 || $0 == 11 }) { notes.append(rootPitch + seventh) }
        if let third = iv.first(where: { $0 == 3 || $0 == 4 }) { notes.append(rootPitch + third + 12) }
        if let ninth = iv.first(where: { $0 == 14 }) { notes.append(rootPitch + ninth) }
        if let sus = iv.first(where: { $0 == 2 || $0 == 5 }), !iv.contains(3), !iv.contains(4) { notes.append(rootPitch + sus + 12) }
        return Array(Set(notes)).sorted()
    }

    /// Diatonic triad/7th built on a scale degree (0-based) — used for progressions.
    public static func diatonic(scale: Scale, tonicPitch: Int, degree: Int, notes: Int = 4) -> [Int] {
        (0..<notes).map { scale.pitch(degree: degree + 2 * $0, tonicPitch: tonicPitch) }
    }
}

/// Human-readable chord name: "Fm7".
public func chordName(root: PitchClass, quality: ChordQuality, preferFlats: Bool = true) -> String {
    NoteName.pitchClassName(root, preferFlats: preferFlats) + quality.symbol
}
