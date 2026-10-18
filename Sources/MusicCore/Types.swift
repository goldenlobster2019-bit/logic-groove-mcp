import Foundation

// MusicCore — pure-Swift, platform-independent music engine used by the
// `logic_compose` tool. No Apple-only frameworks here: this target must build
// and test on Linux (CI) as well as macOS.
//
// Time unit everywhere: ticks at `MusicCore.ppq` pulses per quarter note.
// Positions are relative to the start of the generated clip (bar 1, beat 1 = tick 0)
// unless a function says otherwise.

public enum MusicCore {
    /// Pulses per quarter note used for all generated and parsed material.
    public static let ppq: Int = 480
    public static let sixteenth: Int = ppq / 4
    public static let eighth: Int = ppq / 2
    public static let beat: Int = ppq

    /// Ticks per bar for a given time signature numerator/denominator.
    public static func ticksPerBar(numerator: Int = 4, denominator: Int = 4) -> Int {
        numerator * ppq * 4 / denominator
    }
}

/// A single MIDI note event.
public struct NoteEvent: Equatable, Hashable, Codable, Sendable {
    /// Start position in ticks.
    public var start: Int
    /// Length in ticks (> 0).
    public var duration: Int
    /// MIDI pitch 0...127. Logic convention: 60 = C3 (middle C), 36 = C1.
    public var pitch: Int
    /// Velocity 1...127.
    public var velocity: Int
    /// MIDI channel 1...16.
    public var channel: Int

    public init(start: Int, duration: Int, pitch: Int, velocity: Int = 100, channel: Int = 1) {
        self.start = start
        self.duration = duration
        self.pitch = pitch
        self.velocity = velocity
        self.channel = channel
    }

    public var end: Int { start + duration }
}

/// A named clip of notes — one future Logic region / one MIDI track in a file.
public struct Clip: Equatable, Codable, Sendable {
    public var name: String
    public var notes: [NoteEvent]
    /// Length of the clip in ticks (used for looping and for the region length).
    public var lengthTicks: Int

    public init(name: String, notes: [NoteEvent], lengthTicks: Int) {
        self.name = name
        self.notes = notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        self.lengthTicks = lengthTicks
    }

    public var bars: Double { Double(lengthTicks) / Double(MusicCore.ticksPerBar()) }
}

/// Pitch class 0...11 with C = 0.
public typealias PitchClass = Int

/// Electronic-music genres the generators know about.
public enum Genre: String, Codable, CaseIterable, Sendable {
    case house
    case deepHouse = "deep_house"
    case dubTechno = "dub_techno"
}

/// Which instrument part to generate.
public enum Part: String, Codable, CaseIterable, Sendable {
    case drums      // full kit on one clip (kick/clap/hats/perc), GM / Drum Machine Designer map
    case kick
    case hats
    case bass
    case stabs      // short chord stabs (dub techno chord, house organ/piano stab)
    case chords     // longer sustained chords / pads
    case pad        // drone / atmosphere
}

/// Parameters for a generation request. All optional fields have genre-aware defaults.
public struct GenerationRequest: Codable, Sendable {
    public var genre: Genre
    public var part: Part
    /// Root note name, e.g. "F", "A#", "Db". Default chosen by genre (dub techno: F; house: A).
    public var key: String?
    /// Scale name, see `Scale.named(_:)`. Default "minor" (dub techno: "minor", house: "dorian").
    public var scale: String?
    public var bars: Int
    /// Named style inside the genre/part, e.g. "offbeat", "rolling", "monotone". nil = genre default.
    public var style: String?
    /// 0...1 — how many events to place (1 = busiest).
    public var density: Double
    /// Swing amount 0...1 applied to off-16ths (0.5 ≈ MPC 58%).
    public var swing: Double
    /// Velocity/timing humanization 0...1.
    public var humanize: Double
    /// Octave of the root for this part (Logic numbering, C3 = 60). nil = part default (bass: 1, stabs: 3).
    public var octave: Int?
    /// Deterministic seed so the same request gives the same clip.
    public var seed: UInt64

    public init(
        genre: Genre, part: Part, key: String? = nil, scale: String? = nil, bars: Int = 4,
        style: String? = nil, density: Double = 0.5, swing: Double = 0, humanize: Double = 0.2,
        octave: Int? = nil, seed: UInt64 = 1
    ) {
        self.genre = genre; self.part = part; self.key = key; self.scale = scale; self.bars = bars
        self.style = style; self.density = density; self.swing = swing; self.humanize = humanize
        self.octave = octave; self.seed = seed
    }
}

/// Result of analysing existing material (e.g. a region exported from Logic).
public struct ClipAnalysis: Codable, Sendable {
    /// Best key guess, e.g. "F minor".
    public var keyName: String
    public var tonic: PitchClass
    public var isMinor: Bool
    /// 0...1 confidence of the key guess.
    public var keyConfidence: Double
    /// Distinct chords found at onsets, e.g. ["Fm", "Fm7"], with their pitch content.
    public var chords: [DetectedChord]
    /// Onset positions inside one bar, as 16th-step indices 0...15, with how often each occurs.
    public var onsetHistogram16: [Int]
    /// Most common onset steps (16th indices within the bar), sorted.
    public var mainOnsetSteps: [Int]
    public var lowestPitch: Int
    public var highestPitch: Int
    public var noteCount: Int
    public var lengthBars: Double
}

public struct DetectedChord: Codable, Sendable, Equatable {
    public var name: String          // "Fm7"
    public var root: PitchClass
    public var pitches: [Int]        // actual MIDI pitches of the voicing
    public var occurrences: Int
}

/// Small deterministic PRNG (SplitMix64) so generation is reproducible across platforms.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform Double in 0..<1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// General MIDI drum map as used by Logic's Drum Machine Designer / Drum Kit Designer.
public enum DrumNote {
    public static let kick = 36        // C1
    public static let rim = 37         // C#1
    public static let snare = 38       // D1
    public static let clap = 39        // D#1
    public static let closedHat = 42   // F#1
    public static let pedalHat = 44    // G#1
    public static let openHat = 46     // A#1
    public static let lowTom = 45      // A1
    public static let midTom = 47      // B1
    public static let crash = 49       // C#2
    public static let ride = 51        // D#2
    public static let shaker = 70      // A#3 (maracas)
    public static let cowbell = 56     // G#2
}
