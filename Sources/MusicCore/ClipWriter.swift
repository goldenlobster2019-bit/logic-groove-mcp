import Foundation

// ClipWriter: builds a Clip from an explicit JSON description (notes, chords, step patterns).
// This is the free-form counterpart to the fixed generators: the caller decides every note.
// Pure Swift / Foundation only; Linux-testable.

public struct WrittenClip: Sendable {
    public var clip: Clip
    public var warnings: [String]

    public init(clip: Clip, warnings: [String]) {
        self.clip = clip
        self.warnings = warnings
    }
}

public struct ClipWriterError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Minimal JSON value

enum JSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

// MARK: - ClipWriter

public enum ClipWriter {

    /// General MIDI drum names and aliases (lower case, `_` separated).
    public static let drumNames: [String: Int] = [
        "kick": 36, "bd": 36,
        "rim": 37, "rimshot": 37, "sidestick": 37,
        "snare": 38, "sd": 38,
        "clap": 39, "cp": 39,
        "closed_hat": 42, "ch": 42, "hh": 42, "hat": 42,
        "pedal_hat": 44, "ph": 44,
        "open_hat": 46, "oh": 46,
        "low_tom": 45, "lt": 45,
        "mid_tom": 47, "mt": 47,
        "high_tom": 50, "ht": 50,
        "crash": 49,
        "ride": 51,
        "ride_bell": 53,
        "tambourine": 54, "tamb": 54,
        "cowbell": 56,
        "conga_high": 63,
        "conga_low": 64,
        "shaker": 70, "sh": 70,
        "clave": 75,
    ]

    private static let barTicks = 1920
    private static let sixteenth = 120
    private static let allowedGrids = [4, 8, 12, 16, 24, 32, 48]
    private static let maxTotalNotes = 20_000
    private static let maxNotesEntries = 4_000
    private static let maxChordEntries = 2_000
    private static let maxLanes = 64

    /// One note before the post-processing pass.
    private struct RawNote {
        var start: Int
        var duration: Int
        var pitch: Int
        var velocity: Int
    }

    private struct Lane {
        let key: String
        let pitch: Int          // already transposed when pitched
        let chars: [Character]
        let velocity: Int
        let length: Int?        // nil = one grid step
    }

    /// Parses a JSON object (the spec) and builds the clip. Throws `ClipWriterError` with a precise message.
    public static func write(json: Data, seed: UInt64 = 1) throws -> WrittenClip {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: json)
        } catch {
            throw fail("invalid JSON: \(error.localizedDescription)")
        }
        guard case .object(let spec) = root else {
            throw fail("the spec must be a JSON object")
        }

        var warnings: [String] = []

        // Global parameters.
        var name = "Written clip"
        if let value = get(spec, "name") {
            guard case .string(let text) = value else { throw fail("name must be a string") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = String(trimmed.prefix(80)) }
        }
        let explicitBars = try rangedInt(spec, "bars", 1...256, prefix: "")
        let patternBars = try rangedInt(spec, "pattern_bars", 1...64, prefix: "")
        let grid: Int
        if let value = get(spec, "grid") {
            guard let g = intValue(value), allowedGrids.contains(g) else {
                throw fail("grid must be one of \(allowedGrids.map(String.init).joined(separator: ", "))")
            }
            grid = g
        } else {
            grid = 16
        }
        let channel = try rangedInt(spec, "channel", 1...16, prefix: "") ?? 1
        let transpose = try rangedInt(spec, "transpose", -48...48, prefix: "") ?? 0
        let swing = try rangedDouble(spec, "swing", 0...1, prefix: "") ?? 0
        let humanize = try rangedDouble(spec, "humanize", 0...1, prefix: "") ?? 0
        let stepTicks = barTicks / grid
        let patternTicks = patternBars.map { $0 * barTicks }

        // notes
        var events: [RawNote] = []
        if let value = get(spec, "notes") {
            guard case .array(let items) = value else { throw fail("notes must be an array") }
            guard items.count <= maxNotesEntries else {
                throw fail("notes has \(items.count) entries (max \(maxNotesEntries))")
            }
            for (i, item) in items.enumerated() {
                let ctx = "notes[\(i)]"
                guard case .object(let o) = item else { throw fail("\(ctx) must be an object") }
                let start = try position(o, ctx: ctx, stepTicks: stepTicks)
                if let limit = patternTicks, start >= limit {
                    throw fail("\(ctx): position is beyond pattern_bars (\(patternBars ?? 0) bars)")
                }
                guard let pitchValue = get(o, "pitch") else { throw fail("\(ctx): pitch is required") }
                let resolved = try resolvePitch(pitchValue, ctx: ctx)
                let length = try lengthTicks(get(o, "len"), defaultTicks: sixteenth, ctx: ctx)
                let velocity = try rangedInt(o, "vel", 1...127, prefix: "\(ctx): ") ?? 100
                events.append(RawNote(
                    start: start, duration: length,
                    pitch: resolved.isDrum ? resolved.pitch : resolved.pitch + transpose,
                    velocity: velocity))
            }
        }

        // chords
        if let value = get(spec, "chords") {
            guard case .array(let items) = value else { throw fail("chords must be an array") }
            guard items.count <= maxChordEntries else {
                throw fail("chords has \(items.count) entries (max \(maxChordEntries))")
            }
            for (i, item) in items.enumerated() {
                let ctx = "chords[\(i)]"
                guard case .object(let o) = item else { throw fail("\(ctx) must be an object") }
                let start = try position(o, ctx: ctx, stepTicks: stepTicks)
                if let limit = patternTicks, start >= limit {
                    throw fail("\(ctx): position is beyond pattern_bars (\(patternBars ?? 0) bars)")
                }
                let length = try lengthTicks(get(o, "len"), defaultTicks: sixteenth, ctx: ctx)
                let velocity = try rangedInt(o, "vel", 1...127, prefix: "\(ctx): ") ?? 100
                let velTop = try rangedInt(o, "vel_top", 1...127, prefix: "\(ctx): ")
                let octave = try rangedInt(o, "octave", -1...6, prefix: "\(ctx): ") ?? 2
                let inversion = try rangedInt(o, "inversion", 0...4, prefix: "\(ctx): ") ?? 0
                let strum = try rangedInt(o, "strum", 0...120, prefix: "\(ctx): ") ?? 0
                var voicing = "close"
                if let v = get(o, "voicing") {
                    guard case .string(let text) = v,
                          ["close", "dub", "spread", "shell", "rootless"].contains(text.lowercased()) else {
                        throw fail("\(ctx): voicing must be one of close, dub, spread, shell, rootless")
                    }
                    voicing = text.lowercased()
                }

                let chordValue = get(o, "chord")
                let pitchesValue = get(o, "pitches")
                var pitches: [Int]
                var bass: Int?
                if chordValue != nil && pitchesValue != nil {
                    throw fail("\(ctx): give either chord or pitches, not both")
                } else if let chordValue {
                    guard case .string(let symbol) = chordValue else {
                        throw fail("\(ctx): chord must be a string")
                    }
                    guard let parsed = parseChordSymbol(symbol) else {
                        throw fail("\(ctx): unknown chord symbol '\(symbol)'")
                    }
                    let rootPitch = NoteName.pitch(pitchClass: parsed.root, octave: octave)
                    pitches = voice(rootPitch: rootPitch, intervals: parsed.intervals, voicing: voicing)
                    pitches = invert(pitches, times: inversion)
                    if let bassClass = parsed.bass {
                        bass = NoteName.pitch(pitchClass: bassClass, octave: octave - 1)
                    }
                } else if let pitchesValue {
                    guard case .array(let list) = pitchesValue, !list.isEmpty else {
                        throw fail("\(ctx): pitches must be a non-empty array")
                    }
                    pitches = try list.map { try resolvePitch($0, ctx: ctx).pitch }
                    pitches = invert(Array(Set(pitches)).sorted(), times: inversion)
                } else {
                    throw fail("\(ctx): either chord or pitches is required")
                }
                if let bass { pitches.insert(bass, at: 0) }
                pitches = pitches.map { $0 + transpose }
                let sorted = pitches.sorted()
                for (j, pitch) in sorted.enumerated() {
                    var v = velocity
                    if let velTop, j == sorted.count - 1 { v = velTop }
                    events.append(RawNote(start: start + j * strum, duration: length, pitch: pitch, velocity: v))
                }
            }
        }

        // steps
        var lanes: [Lane] = []
        if let value = get(spec, "steps") {
            guard case .object(let laneSpecs) = value else { throw fail("steps must be an object") }
            guard laneSpecs.count <= maxLanes else {
                throw fail("steps has \(laneSpecs.count) lanes (max \(maxLanes))")
            }
            for key in laneSpecs.keys.sorted() {
                let ctx = "steps.\(key)"
                let resolved = try resolveLane(key, ctx: ctx)
                var patternText: String
                var velocity = 100
                var length: Int?
                switch laneSpecs[key] ?? .null {
                case .string(let text):
                    patternText = text
                case .object(let o):
                    guard case .string(let text)? = get(o, "pattern") else {
                        throw fail("\(ctx): pattern is required and must be a string")
                    }
                    patternText = text
                    velocity = try rangedInt(o, "vel", 1...127, prefix: "\(ctx): ") ?? 100
                    if get(o, "len") != nil {
                        length = try lengthTicks(get(o, "len"), defaultTicks: stepTicks, ctx: ctx)
                    }
                default:
                    throw fail("\(ctx): pattern must be a string or an object")
                }
                var chars: [Character] = []
                for ch in patternText {
                    if ch == " " || ch == "|" || ch.isWhitespace { continue }
                    guard "xXog.-_".contains(ch) else {
                        throw fail("\(ctx): invalid character '\(ch)' in pattern")
                    }
                    chars.append(ch)
                }
                guard !chars.isEmpty else { throw fail("\(ctx): pattern is empty") }
                lanes.append(Lane(
                    key: key,
                    pitch: resolved.isDrum ? resolved.pitch : resolved.pitch + transpose,
                    chars: chars, velocity: velocity, length: length))
            }
        }

        // Clip length.
        let bars: Int
        if let explicitBars {
            bars = explicitBars
        } else if let patternBars {
            bars = patternBars
        } else {
            var needed = 1
            if let maxEnd = events.map({ $0.start + $0.duration }).max() {
                needed = max(needed, (maxEnd + barTicks - 1) / barTicks)
            }
            if let longest = lanes.map({ $0.chars.count }).max() {
                needed = max(needed, (longest + grid - 1) / grid)
            }
            guard needed <= 256 else { throw fail("bars must be between 1 and 256") }
            bars = needed
        }
        let lengthTicks = bars * barTicks

        // Tile the pattern.
        var raw: [RawNote] = []
        if let patternTicks, !events.isEmpty {
            let tiles = (lengthTicks + patternTicks - 1) / patternTicks
            guard events.count * tiles <= maxTotalNotes else {
                throw fail("too many notes after tiling (\(events.count * tiles), max \(maxTotalNotes))")
            }
            for tile in 0..<tiles {
                let offset = tile * patternTicks
                for var e in events {
                    e.start += offset
                    if tile > 0 {
                        if e.start >= lengthTicks { continue }
                        e.duration = min(e.duration, lengthTicks - e.start)
                    }
                    raw.append(e)
                }
            }
        } else {
            raw = events
        }

        // Step lanes.
        let totalSteps = bars * grid
        for lane in lanes {
            var lastHit: Int?       // index into raw
            var previousActive = false
            var warnedTie = false
            for i in 0..<totalSteps {
                let ch = lane.chars[i % lane.chars.count]
                let start = i * stepTicks
                switch ch {
                case "x", "X", "o", "g":
                    let delta: Int
                    switch ch {
                    case "X": delta = 20
                    case "o": delta = -30
                    case "g": delta = -55
                    default: delta = 0
                    }
                    raw.append(RawNote(
                        start: start, duration: lane.length ?? stepTicks, pitch: lane.pitch,
                        velocity: min(127, max(1, lane.velocity + delta))))
                    lastHit = raw.count - 1
                    previousActive = true
                case "_":
                    if previousActive, let index = lastHit {
                        raw[index].duration = max(raw[index].duration, start + stepTicks - raw[index].start)
                    } else if !warnedTie {
                        warnedTie = true
                        warnings.append("steps.\(lane.key): tie '_' at step \(i) has nothing to extend (ignored)")
                        previousActive = false
                    }
                default:
                    previousActive = false
                }
            }
            guard raw.count <= maxTotalNotes else {
                throw fail("too many notes (more than \(maxTotalNotes))")
            }
        }

        guard !raw.isEmpty else {
            throw fail("the spec produced no notes (give at least one of notes, chords, steps)")
        }
        guard raw.count <= maxTotalNotes else {
            throw fail("too many notes (\(raw.count), max \(maxTotalNotes))")
        }

        // Deterministic order before swing / humanize.
        raw.sort { ($0.start, $0.pitch, $0.velocity, $0.duration) < ($1.start, $1.pitch, $1.velocity, $1.duration) }

        // Swing (same formula as Groove.finalize).
        let swingTicks = Int((swing * 0.4 * Double(sixteenth)).rounded())
        if swingTicks > 0 {
            for i in raw.indices where raw[i].start % sixteenth == 0 && (raw[i].start / sixteenth) % 2 == 1 {
                raw[i].start += swingTicks
            }
        }

        // Clamp, drop, truncate, merge, trim. Warning counts come from the pass without
        // humanize so they only report what the written material itself causes.
        let finished = finish(raw, lengthTicks: lengthTicks, channel: channel)
        var merged = finished.notes
        if humanize > 0 {
            var rng = SeededRandom(seed: seed)
            var jittered = raw
            for i in jittered.indices {
                let ut = rng.unit()
                let uv = rng.unit()
                jittered[i].start += Int(((ut * 2 - 1) * humanize * 8).rounded())
                jittered[i].velocity += Int(((uv * 2 - 1) * humanize * 12).rounded())
            }
            merged = finish(jittered, lengthTicks: lengthTicks, channel: channel).notes
        }
        if finished.dropped > 0 {
            warnings.append("\(finished.dropped) note(s) started at or after the clip end (\(bars) bars) and were dropped")
        }
        if finished.truncated > 0 {
            warnings.append("\(finished.truncated) note(s) ran past the clip end and were shortened")
        }
        if finished.trimmed > 0 {
            warnings.append("\(finished.trimmed) overlapping note(s) of the same pitch were shortened to end where the next one starts")
        }

        guard !merged.isEmpty else {
            throw fail("no notes remain inside the clip (\(bars) bars)")
        }
        return WrittenClip(clip: Clip(name: name, notes: merged, lengthTicks: lengthTicks), warnings: warnings)
    }

    /// Clamp, drop notes outside the clip, truncate, merge exact duplicates, trim same-pitch overlaps.
    private static func finish(
        _ raw: [RawNote], lengthTicks: Int, channel: Int
    ) -> (notes: [NoteEvent], dropped: Int, truncated: Int, trimmed: Int) {
        var dropped = 0
        var truncated = 0
        var notes: [NoteEvent] = []
        notes.reserveCapacity(raw.count)
        for r in raw {
            let start = max(0, r.start)
            guard start < lengthTicks else { dropped += 1; continue }
            var duration = max(1, r.duration)
            if start + duration > lengthTicks {
                duration = lengthTicks - start
                truncated += 1
            }
            notes.append(NoteEvent(
                start: start, duration: duration,
                pitch: min(127, max(0, r.pitch)),
                velocity: min(127, max(1, r.velocity)),
                channel: channel))
        }

        // Merge exact duplicates (same start + pitch + channel).
        struct Key: Hashable { let start: Int; let pitch: Int; let channel: Int }
        var index: [Key: Int] = [:]
        var merged: [NoteEvent] = []
        for n in notes {
            let k = Key(start: n.start, pitch: n.pitch, channel: n.channel)
            if let i = index[k] {
                merged[i].velocity = max(merged[i].velocity, n.velocity)
                merged[i].duration = max(merged[i].duration, n.duration)
            } else {
                index[k] = merged.count
                merged.append(n)
            }
        }

        // Trim same-pitch overlaps so a note-off cannot cancel a later note-on.
        var trimmed = 0
        let order = merged.indices.sorted {
            (merged[$0].pitch, merged[$0].start) < (merged[$1].pitch, merged[$1].start)
        }
        for (a, b) in zip(order, order.dropFirst()) where merged[a].pitch == merged[b].pitch {
            if merged[a].end > merged[b].start {
                merged[a].duration = max(1, merged[b].start - merged[a].start)
                trimmed += 1
            }
        }
        return (merged, dropped, truncated, trimmed)
    }

    // MARK: - Errors and value helpers

    private static func fail(_ message: String) -> ClipWriterError {
        ClipWriterError(message: message)
    }

    /// Object member, with JSON null treated as absent.
    private static func get(_ object: [String: JSONValue], _ key: String) -> JSONValue? {
        guard let value = object[key] else { return nil }
        if case .null = value { return nil }
        return value
    }

    private static func numberValue(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let d):
            return d.isFinite ? d : nil
        case .string(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
            return nil
        default:
            return nil
        }
    }

    private static func intValue(_ value: JSONValue) -> Int? {
        guard let d = numberValue(value), d == d.rounded(), abs(d) < 1e12 else { return nil }
        return Int(d)
    }

    private static func rangedInt(
        _ object: [String: JSONValue], _ key: String, _ range: ClosedRange<Int>, prefix: String
    ) throws -> Int? {
        guard let value = get(object, key) else { return nil }
        guard let i = intValue(value), range.contains(i) else {
            throw fail("\(prefix)\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return i
    }

    private static func rangedDouble(
        _ object: [String: JSONValue], _ key: String, _ range: ClosedRange<Double>, prefix: String
    ) throws -> Double? {
        guard let value = get(object, key) else { return nil }
        guard let d = numberValue(value), range.contains(d) else {
            throw fail("\(prefix)\(key) must be between \(format(range.lowerBound)) and \(format(range.upperBound))")
        }
        return d
    }

    private static func format(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }

    // MARK: - Positions

    private static func position(_ o: [String: JSONValue], ctx: String, stepTicks: Int) throws -> Int {
        let pos = get(o, "pos")
        let step = get(o, "step")
        switch (pos, step) {
        case (nil, nil):
            throw fail("\(ctx): one of pos or step is required")
        case (.some, .some):
            throw fail("\(ctx): give either pos or step, not both")
        case (.some(let p), nil):
            guard case .string(let text) = p else { throw fail("\(ctx): pos must be a string like \"1.1.1\"") }
            return try parsePos(text, ctx: ctx)
        case (nil, .some(let s)):
            guard let d = numberValue(s), d >= 0 else { throw fail("\(ctx): step must be a number of 0 or more") }
            return Int((d * Double(stepTicks)).rounded())
        }
    }

    /// "bar.beat.sixteenth[.ticks]", all 1-based except ticks; short forms "bar" and "bar.beat".
    private static func parsePos(_ text: String, ctx: String) throws -> Int {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else {
            throw fail("\(ctx): pos '\(text)' is invalid (expected bar.beat.sixteenth)")
        }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)) else {
                throw fail("\(ctx): pos '\(text)' is invalid (expected bar.beat.sixteenth, all numbers)")
            }
            numbers.append(n)
        }
        let bar = numbers[0]
        let beat = numbers.count > 1 ? numbers[1] : 1
        let six = numbers.count > 2 ? numbers[2] : 1
        let extra = numbers.count > 3 ? numbers[3] : 0
        guard bar >= 1 else { throw fail("\(ctx): pos '\(text)' is invalid (bar must be 1 or more)") }
        guard (1...4).contains(beat) else { throw fail("\(ctx): pos '\(text)' is invalid (beat must be 1-4)") }
        guard (1...4).contains(six) else { throw fail("\(ctx): pos '\(text)' is invalid (sixteenth must be 1-4)") }
        guard (0...119).contains(extra) else { throw fail("\(ctx): pos '\(text)' is invalid (tick offset must be 0-119)") }
        return (bar - 1) * barTicks + (beat - 1) * 480 + (six - 1) * sixteenth + extra
    }

    // MARK: - Pitch and length

    private static func drumKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func resolveText(_ text: String) -> (pitch: Int, isDrum: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) { return (0...127).contains(n) ? (n, false) : nil }
        if let p = NoteName.pitch(trimmed) { return (p, false) }
        if let d = drumNames[drumKey(trimmed)] { return (d, true) }
        return nil
    }

    private static func resolvePitch(_ value: JSONValue, ctx: String) throws -> (pitch: Int, isDrum: Bool) {
        switch value {
        case .number(let d):
            guard d == d.rounded(), (0...127).contains(d) else {
                throw fail("\(ctx): unknown pitch '\(format(d))' (MIDI numbers are 0-127)")
            }
            return (Int(d), false)
        case .string(let s):
            guard let r = resolveText(s) else { throw fail("\(ctx): unknown pitch '\(s)'") }
            return r
        default:
            throw fail("\(ctx): pitch must be a MIDI number, a note name or a drum name")
        }
    }

    private static func resolveLane(_ key: String, ctx: String) throws -> (pitch: Int, isDrum: Bool) {
        guard let r = resolveText(key) else {
            throw fail("\(ctx): unknown lane '\(key)' (use a drum name, a note name or a MIDI number)")
        }
        return r
    }

    /// Length in ticks. Number / numeric string = 16ths; "1/8", "1/8.", "1/8t"; "2bars".
    private static func lengthTicks(_ value: JSONValue?, defaultTicks: Int, ctx: String) throws -> Int {
        guard let value else { return defaultTicks }
        switch value {
        case .number(let d):
            guard d.isFinite, d > 0 else { throw fail("\(ctx): len must be greater than 0") }
            return max(1, Int((d * Double(sixteenth)).rounded()))
        case .string(let raw):
            let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let d = Double(s) {
                guard d.isFinite, d > 0 else { throw fail("\(ctx): len must be greater than 0") }
                return max(1, Int((d * Double(sixteenth)).rounded()))
            }
            for suffix in ["bars", "bar"] where s.hasSuffix(suffix) {
                let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let d = Double(number), d.isFinite, d > 0 {
                    return max(1, Int((d * Double(barTicks)).rounded()))
                }
                throw fail("\(ctx): invalid len '\(raw)'")
            }
            var body = s
            var factor = 1.0
            if body.hasSuffix(".") { body.removeLast(); factor = 1.5 }
            else if body.hasSuffix("t") { body.removeLast(); factor = 2.0 / 3.0 }
            let halves = body.split(separator: "/", omittingEmptySubsequences: false)
            guard halves.count == 2, let numerator = Int(halves[0]), let denominator = Int(halves[1]),
                  numerator >= 1, [1, 2, 4, 8, 16, 32, 64].contains(denominator) else {
                throw fail("\(ctx): invalid len '\(raw)'")
            }
            let ticks = Double(barTicks) * Double(numerator) / Double(denominator) * factor
            return max(1, Int(ticks.rounded()))
        default:
            throw fail("\(ctx): len must be a number or a string like \"1/8\"")
        }
    }

    // MARK: - Chords

    struct ParsedChord: Equatable {
        let root: PitchClass
        let intervals: [Int]
        let bass: PitchClass?
    }

    private static let chordBases: [(String, [Int])] = {
        let table: [(String, [Int])] = [
            ("", [0, 4, 7]), ("m", [0, 3, 7]), ("maj", [0, 4, 7]), ("M", [0, 4, 7]),
            ("dim", [0, 3, 6]), ("aug", [0, 4, 8]), ("+", [0, 4, 8]),
            ("sus2", [0, 2, 7]), ("sus4", [0, 5, 7]), ("sus", [0, 5, 7]),
            ("5", [0, 7]), ("6", [0, 4, 7, 9]), ("m6", [0, 3, 7, 9]),
            ("7", [0, 4, 7, 10]), ("m7", [0, 3, 7, 10]),
            ("maj7", [0, 4, 7, 11]), ("M7", [0, 4, 7, 11]),
            ("mmaj7", [0, 3, 7, 11]), ("mM7", [0, 3, 7, 11]),
            ("dim7", [0, 3, 6, 9]), ("m7b5", [0, 3, 6, 10]),
            ("aug7", [0, 4, 8, 10]), ("+7", [0, 4, 8, 10]),
            ("9", [0, 4, 7, 10, 14]), ("m9", [0, 3, 7, 10, 14]),
            ("maj9", [0, 4, 7, 11, 14]), ("M9", [0, 4, 7, 11, 14]),
            ("11", [0, 7, 10, 14, 17]), ("m11", [0, 3, 7, 10, 14, 17]),
            ("13", [0, 4, 7, 10, 14, 21]), ("m13", [0, 3, 7, 10, 14, 21]),
            ("maj13", [0, 4, 7, 11, 14, 21]),
            ("7sus4", [0, 5, 7, 10]), ("7sus", [0, 5, 7, 10]), ("9sus4", [0, 5, 7, 10, 14]),
            ("m7sus4", [0, 5, 7, 10]),
        ]
        return table.sorted { $0.0.count > $1.0.count }
    }()

    private static let chordAlterations = ["add13", "add11", "add9", "#11", "b13", "b9", "#9", "b5", "#5"]

    /// General chord symbol parser: root, quality, alterations, optional slash bass.
    static func parseChordSymbol(_ symbol: String) -> ParsedChord? {
        var text = symbol.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }

        var bass: PitchClass?
        if let slash = text.lastIndex(of: "/") {
            let bassText = String(text[text.index(after: slash)...])
            guard let pc = NoteName.pitchClass(bassText), !bassText.isEmpty else { return nil }
            bass = pc
            text = String(text[..<slash])
        }

        guard let first = text.first, "ABCDEFG".contains(first) else { return nil }
        var rootText = String(first)
        var rest = Substring(text.dropFirst())
        while let ch = rest.first, ch == "#" || ch == "b" {
            rootText.append(ch)
            rest = rest.dropFirst()
        }
        guard let root = NoteName.pitchClass(rootText) else { return nil }

        var quality = String(rest)
        if quality.hasPrefix("min") {
            quality = "m" + quality.dropFirst(3)
        } else if quality.hasPrefix("-") {
            quality = "m" + quality.dropFirst()
        } else if quality.lowercased().hasPrefix("maj") {
            quality = "maj" + quality.dropFirst(3)
        }

        guard let base = chordBases.first(where: { quality.hasPrefix($0.0) }) else { return nil }
        var intervals = base.1
        var remainder = Substring(quality.dropFirst(base.0.count))

        func replace(_ old: Int, _ new: Int) {
            if let i = intervals.firstIndex(of: old) { intervals[i] = new } else { intervals.append(new) }
        }
        while !remainder.isEmpty {
            guard let alt = chordAlterations.first(where: { remainder.hasPrefix($0) }) else { return nil }
            switch alt {
            case "b5": replace(7, 6)
            case "#5": replace(7, 8)
            case "b9": replace(14, 13)
            case "#9": replace(14, 15)
            case "#11": replace(17, 18)
            case "b13": replace(21, 20)
            case "add9": if !intervals.contains(14) { intervals.append(14) }
            case "add11": if !intervals.contains(17) { intervals.append(17) }
            default: if !intervals.contains(21) { intervals.append(21) }
            }
            remainder = remainder.dropFirst(alt.count)
        }
        return ParsedChord(root: root, intervals: Array(Set(intervals)).sorted(), bass: bass)
    }

    static func voice(rootPitch: Int, intervals iv: [Int], voicing: String) -> [Int] {
        func close() -> [Int] { iv.map { rootPitch + $0 } }
        switch voicing {
        case "dub":
            return Voicing.dubStab(rootPitch: rootPitch, quality: ChordQuality(symbol: "", intervals: iv))
        case "spread":
            let fifth = [7, 6, 8].first { iv.contains($0) }
            let threshold = rootPitch + (fifth ?? 7)
            var out: Set<Int> = [rootPitch]
            if let fifth { out.insert(rootPitch + fifth) }
            for t in iv where t != 0 && t != fifth {
                var p = rootPitch + t
                while p <= threshold { p += 12 }
                out.insert(p)
            }
            return out.sorted()
        case "shell":
            let third = iv.first { $0 == 3 || $0 == 4 } ?? iv.first { $0 == 2 || $0 == 5 }
            let seventh = iv.first { $0 == 10 || $0 == 11 }
                ?? ((iv.contains(3) && iv.contains(6) && iv.contains(9)) ? 9 : nil)
            if let seventh {
                var out: Set<Int> = [rootPitch, rootPitch + seventh]
                if let third { out.insert(rootPitch + third) } else if iv.contains(7) { out.insert(rootPitch + 7) }
                return out.sorted()
            }
            return iv.filter { $0 < 12 }.map { rootPitch + $0 }
        case "rootless":
            let rest = iv.filter { $0 != 0 }.map { rootPitch + $0 }
            return rest.count >= 2 ? rest : close()
        default:
            return close()
        }
    }

    private static func invert(_ pitches: [Int], times: Int) -> [Int] {
        var current = pitches.sorted()
        for _ in 0..<times where !current.isEmpty {
            let lowest = current.removeFirst()
            current.append(lowest + 12)
            current = Array(Set(current)).sorted()
        }
        return current
    }
}
