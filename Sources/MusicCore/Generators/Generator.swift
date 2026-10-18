import Foundation

public struct StyleInfo: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
}

public enum Generator {
    /// Main entry. Resolves defaults (key, scale, octave, style) from genre+part, builds the clip, applies swing + humanize.
    public static func generate(_ request: GenerationRequest) -> Clip {
        build(request, analysis: nil)
    }

    /// Generate a part that fits existing material (e.g. the user's stab region): uses analysis.tonic/isMinor for key,
    /// analysis.mainOnsetSteps to interlock rhythm (bass avoids landing on stab onsets unless style says "follow"),
    /// and analysis.chords (first chord) for chord parts. `request.key`/`scale` override the analysis when non-nil.
    public static func complement(_ analysis: ClipAnalysis, request: GenerationRequest) -> Clip {
        build(request, analysis: analysis)
    }

    /// Styles available for genre+part (first one = default).
    public static func styles(genre: Genre, part: Part) -> [StyleInfo] {
        StyleCatalog.styles(genre: genre, part: part)
    }

    /// The defaults that `generate` would use, for display: (key "F", scale "minor", octave, style).
    public static func resolvedDefaults(_ request: GenerationRequest) -> (key: String, scale: String, octave: Int, style: String) {
        let r = resolve(request, analysis: nil)
        return (r.keyName, r.scale.name, r.octave, r.style)
    }
}

// MARK: - Resolution

struct ResolvedRequest {
    var keyName: String
    var tonic: PitchClass
    var scale: Scale
    var octave: Int
    var octaveIsDefault: Bool
    var style: String
}

extension Generator {
    static func clamp01(_ x: Double, fallback: Double) -> Double {
        x.isNaN ? fallback : min(1, max(0, x))
    }

    static func defaultKey(_ genre: Genre) -> String { genre == .dubTechno ? "F" : "A" }

    static func defaultScale(_ genre: Genre) -> String {
        switch genre {
        case .dubTechno, .deepHouse: return "minor"
        case .house: return "dorian"
        }
    }

    static func defaultOctave(_ part: Part) -> Int {
        part == .bass ? 1 : 2
    }

    static func normalizedStyle(_ s: String) -> String {
        let n = s.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        let aliases = ["monotone": "monotone_pulse", "pulse": "monotone_pulse", "dub": "dub_chord",
                       "four_on_the_floor": "four_on_floor", "4x4": "four_on_floor", "pad": "deep_pad"]
        return aliases[n] ?? n
    }

    static func resolve(_ r: GenerationRequest, analysis: ClipAnalysis?) -> ResolvedRequest {
        // Key
        let keyName: String
        let tonic: PitchClass
        if let k = r.key?.split(separator: " ").first.map(String.init), let pc = NoteName.pitchClass(k) {
            keyName = k.prefix(1).uppercased() + k.dropFirst()
            tonic = pc
        } else if let a = analysis {
            tonic = ((a.tonic % 12) + 12) % 12
            keyName = tonic == 6 ? "F#" : NoteName.pitchClassName(tonic, preferFlats: true)
        } else {
            keyName = defaultKey(r.genre)
            tonic = NoteName.pitchClass(keyName) ?? 0
        }
        // Scale
        let scale: Scale
        if let s = r.scale, let sc = Scale.named(s) {
            scale = sc
        } else if let a = analysis {
            let def = Scale.named(defaultScale(r.genre)) ?? Scale.all[0]
            scale = a.isMinor ? (def.isMinor ? def : Scale.all[0]) : (Scale.named("major") ?? Scale.all[0])
        } else {
            scale = Scale.named(defaultScale(r.genre)) ?? Scale.all[0]
        }
        // Octave
        let octave = min(7, max(-1, r.octave ?? defaultOctave(r.part)))
        // Style
        let available = StyleCatalog.styles(genre: r.genre, part: r.part).map(\.name)
        var style = available[0]
        if let s = r.style {
            let n = normalizedStyle(s)
            if available.contains(n) { style = n }
        }
        return ResolvedRequest(keyName: keyName, tonic: tonic, scale: scale, octave: octave,
                               octaveIsDefault: r.octave == nil, style: style)
    }

    static func displayName(_ genre: Genre) -> String {
        switch genre {
        case .house: return "House"
        case .deepHouse: return "Deep House"
        case .dubTechno: return "Dub Techno"
        }
    }

    static func displayName(_ part: Part) -> String {
        part.rawValue.prefix(1).uppercased() + part.rawValue.dropFirst()
    }

    static func build(_ request: GenerationRequest, analysis: ClipAnalysis?) -> Clip {
        let res = resolve(request, analysis: analysis)
        let bars = min(64, max(1, request.bars))
        var ctx = GenContext(
            genre: request.genre, part: request.part, style: res.style, tonic: res.tonic, scale: res.scale,
            octave: res.octave, octaveIsDefault: res.octaveIsDefault, bars: bars,
            density: clamp01(request.density, fallback: 0.5),
            swing: clamp01(request.swing, fallback: 0),
            humanize: clamp01(request.humanize, fallback: 0.2),
            rng: SeededRandom(seed: request.seed),
            stabSteps: nil, chordOverride: nil)

        if let a = analysis {
            let steps = Array(Set(a.mainOnsetSteps.filter { (0..<16).contains($0) })).sorted()
            ctx.stabSteps = steps.isEmpty ? nil : steps
            if let first = a.chords.first {
                ctx.chordOverride = ChordSpec(root: ((first.root % 12) + 12) % 12, quality: Groove.quality(of: first))
            }
        }

        var raw: [NoteEvent]
        switch request.genre {
        case .dubTechno: raw = DubTechno.build(&ctx)
        case .house, .deepHouse: raw = House.build(&ctx)
        }
        if let steps = ctx.stabSteps, ctx.part == .bass, ctx.style != "follow" {
            raw = Interlock.avoid(raw, steps: steps)
        }
        let notes = Groove.finalize(raw, &ctx)
        let name = "\(displayName(request.genre)) \(displayName(request.part)) – \(res.keyName) \(res.scale.name) – \(res.style)"
        return Clip(name: name, notes: notes, lengthTicks: ctx.lengthTicks)
    }
}

// MARK: - Style catalogue

enum StyleCatalog {
    private static func s(_ name: String, _ description: String) -> StyleInfo {
        StyleInfo(name: name, description: description)
    }

    static func styles(genre: Genre, part: Part) -> [StyleInfo] {
        switch genre {
        case .dubTechno: return dub(part)
        case .house, .deepHouse: return house(part)
        }
    }

    private static func dub(_ part: Part) -> [StyleInfo] {
        switch part {
        case .drums: return [
            s("minimal", "Soft 4/4 kick, low offbeat hats, ghosted shaker 16ths, sparse rim"),
            s("steppers", "4/4 kick, rim on beat 3, 8th hats with open hat pickup"),
        ]
        case .kick: return [
            s("four_on_floor", "Steady 4/4 kick, optional ghost kick before beat 1 at high density"),
            s("ghost", "4/4 kick with ghost kicks leaning into the downbeat"),
        ]
        case .hats: return [
            s("shaker_offbeat", "Shaker 16ths with soft offbeat closed hats"),
            s("offbeat", "Offbeat closed hats with occasional open hat"),
            s("shaker", "Ghosted shaker 16ths only"),
        ]
        case .bass: return [
            s("offbeat", "Short sub notes on every 8th offbeat, monotone root, pumping against the kick"),
            s("monotone_pulse", "Very sparse syncopated root pulses on the last 16th of the beat"),
            s("sustain", "Long root notes, one per bar or two, with a slight retrigger"),
            s("rolling", "Rolling 16ths with ghost velocities, root plus occasional octave/fifth"),
            s("follow", "Plays only on the stab onsets (use with complement)"),
        ]
        case .stabs: return [
            s("dub_chord", "Sparse syncopated m7/m9/m7sus4 chord hits leaving space for the delay"),
            s("offbeat", "Chord hits on the offbeats (all or every other)"),
            s("dotted", "Dotted-8th spacing that locks with 3/16 delays"),
            s("polymeter", "3- or 5-step cycle drifting against the 16-step bar"),
        ]
        case .chords: return [
            s("drone", "Sustained m9 chord over one or more bars, low velocity"),
            s("swell", "Long overlapping notes with staggered re-entries"),
        ]
        case .pad: return [
            s("drone", "Very long, soft m9 drone"),
            s("swell", "Slow overlapping swells with staggered re-entries"),
        ]
        }
    }

    private static func house(_ part: Part) -> [StyleInfo] {
        switch part {
        case .drums: return [
            s("classic", "4/4 kick, clap on 2 & 4, open hat on offbeats, accented closed 16ths"),
            s("deep", "Lighter kit: rim on 2 & 4, shuffled 16th hats, slight swing"),
            s("garage", "Skippy kick variations, ghost claps, swung hats"),
        ]
        case .kick: return [
            s("four_on_floor", "Steady 4/4 kick"),
            s("garage", "4/4 kick with skippy extra hits"),
        ]
        case .hats: return [
            s("offbeat_open", "Open hats on the offbeats, soft closed hats on the beats"),
            s("sixteenths", "Closed 16ths with velocity accents"),
            s("shuffle", "Shuffled 16ths with accents on the swung 16ths"),
        ]
        case .bass: return [
            s("deep_groove", "Syncopated deep house bassline following an i-iv or i-VII progression"),
            s("offbeat", "Offbeat 8th house bass on the root"),
            s("octave_jump", "Root alternating low and high octave"),
            s("rolling", "Rolling 16ths with ghost notes and octave accents"),
            s("follow", "Plays only on the stab onsets (use with complement)"),
        ]
        case .stabs: return [
            s("chord_stab", "Syncopated m7 chord stabs over a short progression"),
            s("organ_stab", "M1-style organ stabs, m7/m9 over a 2-4 chord progression"),
            s("piano_stab", "Offbeat-heavy piano chord hits"),
        ]
        case .chords: return [
            s("deep_pad", "Whole-bar m9/maj7 chords: i9-iv9 or i9-VII-VI"),
            s("progression", "One chord per bar from a genre-typical progression"),
        ]
        case .pad: return [
            s("deep_pad", "Soft, long-held m9 pad chords"),
        ]
        }
    }
}
