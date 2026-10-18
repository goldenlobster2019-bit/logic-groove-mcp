import Foundation

/// Result of parsing a Standard MIDI File.
public struct MIDIFileContents: Sendable {
    /// One clip per MTrk that contains notes; name from track-name meta (FF 03) or "Track N" (N = 1-based MTrk index).
    public var clips: [Clip]
    /// First tempo meta event (earliest tick), if any.
    public var tempoBPM: Double?
    /// First time-signature meta event (earliest tick), if any.
    public var timeSignature: (numerator: Int, denominator: Int)?

    public init(clips: [Clip], tempoBPM: Double? = nil, timeSignature: (numerator: Int, denominator: Int)? = nil) {
        self.clips = clips
        self.tempoBPM = tempoBPM
        self.timeSignature = timeSignature
    }
}

public enum MIDIFileError: Error, Sendable, Equatable {
    case notMIDI
    case truncated
    case unsupportedFormat(String)
}

public enum MIDIFileIO {

    // MARK: - Writing

    /// Standard MIDI File, format 1, division = MusicCore.ppq.
    /// Track 0 = conductor track: time signature 4/4 always; tempo meta ONLY when tempoBPM != nil.
    /// Then one MTrk per clip with a track-name meta (clip.name), note on/off pairs, end-of-track.
    /// startOffsetTicks shifts every note later (used to place a clip at a bar inside a bigger timeline).
    public static func write(clips: [Clip], tempoBPM: Double? = nil, startOffsetTicks: Int = 0) -> Data {
        var out = [UInt8]()
        out += Array("MThd".utf8)
        out += be32(6)
        out += be16(1)
        out += be16(clips.count + 1)
        out += be16(MusicCore.ppq)

        // Conductor track.
        var conductor = [UInt8]()
        conductor += [0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08] // 4/4, 24 clocks, 8 32nds
        if let bpm = tempoBPM, bpm > 0, bpm.isFinite {
            let us = min(max(Int((60_000_000.0 / bpm).rounded()), 1), 0xFF_FFFF)
            conductor += [0x00, 0xFF, 0x51, 0x03, UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)]
        }
        conductor += [0x00, 0xFF, 0x2F, 0x00]
        out += trackChunk(conductor)

        for clip in clips {
            out += trackChunk(clipTrackBody(clip, offset: startOffsetTicks))
        }
        return Data(out)
    }

    public static func write(clip: Clip, tempoBPM: Double? = nil, startOffsetTicks: Int = 0) -> Data {
        write(clips: [clip], tempoBPM: tempoBPM, startOffsetTicks: startOffsetTicks)
    }

    private static func clipTrackBody(_ clip: Clip, offset: Int) -> [UInt8] {
        // (tick, order 0 = off / 1 = on, pitch, bytes)
        struct Ev { var tick: Int; var order: Int; var pitch: Int; var bytes: [UInt8] }
        var events = [Ev]()
        for n in clip.notes where n.duration > 0 {
            let pitch = min(max(n.pitch, 0), 127)
            let vel = min(max(n.velocity, 1), 127)
            let ch = UInt8(min(max(n.channel, 1), 16) - 1)
            let start = max(0, n.start + offset)
            let end = start + n.duration
            events.append(Ev(tick: start, order: 1, pitch: pitch, bytes: [0x90 | ch, UInt8(pitch), UInt8(vel)]))
            events.append(Ev(tick: end, order: 0, pitch: pitch, bytes: [0x80 | ch, UInt8(pitch), 0x40]))
        }
        events.sort { ($0.tick, $0.order, $0.pitch) < ($1.tick, $1.order, $1.pitch) }

        var body = [UInt8]()
        let nameBytes = Array(clip.name.utf8)
        body += [0x00, 0xFF, 0x03]
        body += vlq(nameBytes.count)
        body += nameBytes

        var last = 0
        for e in events {
            body += vlq(e.tick - last)
            body += e.bytes
            last = e.tick
        }
        let endTick = max(clip.lengthTicks + offset, last)
        body += vlq(endTick - last)
        body += [0xFF, 0x2F, 0x00]
        return body
    }

    private static func trackChunk(_ body: [UInt8]) -> [UInt8] {
        Array("MTrk".utf8) + be32(body.count) + body
    }

    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func be16(_ v: Int) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Variable-length quantity encoding (clamped to 0...0x0FFFFFFF).
    static func vlq(_ value: Int) -> [UInt8] {
        var v = min(max(value, 0), 0x0FFF_FFFF)
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        return bytes.reversed()
    }

    // MARK: - Reading

    public static func read(url: URL) throws -> MIDIFileContents {
        try read(try Data(contentsOf: url))
    }

    /// Reads format 0 and 1 (format 2 -> unsupportedFormat). Handles running status, note-on velocity 0 as note-off,
    /// overlapping same-pitch notes (FIFO pairing), sysex/meta skipping, SMPTE division -> unsupportedFormat.
    /// Rescales all ticks to MusicCore.ppq. Clip.lengthTicks = end of last note rounded UP to a whole 4/4 bar (min 1 bar).
    /// For format 0, split notes into clips by MIDI channel only if more than one channel is used, else one clip.
    public static func read(_ data: Data) throws -> MIDIFileContents {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else { throw MIDIFileError.notMIDI }
        guard b.count >= 14 else { throw MIDIFileError.truncated }
        let headerLen = u32(b, 4)
        guard headerLen >= 6, b.count >= 8 + headerLen else { throw MIDIFileError.truncated }
        let format = u16(b, 8)
        let division = u16(b, 12)
        if format > 1 { throw MIDIFileError.unsupportedFormat("MIDI format \(format)") }
        if division & 0x8000 != 0 { throw MIDIFileError.unsupportedFormat("SMPTE time division") }
        guard division > 0 else { throw MIDIFileError.unsupportedFormat("zero time division") }

        var pos = 8 + headerLen
        var trackIndex = 0
        var clips = [Clip]()
        var tempo: (tick: Int, bpm: Double)?
        var timeSig: (tick: Int, num: Int, den: Int)?
        let bar = MusicCore.ticksPerBar()

        func rescale(_ t: Int) -> Int { (t * MusicCore.ppq + division / 2) / division }

        while pos + 8 <= b.count {
            let tag = Array(b[pos..<pos + 4])
            let len = u32(b, pos + 4)
            let bodyStart = pos + 8
            guard bodyStart + len <= b.count else { throw MIDIFileError.truncated }
            pos = bodyStart + len
            guard tag == Array("MTrk".utf8) else { continue }
            trackIndex += 1

            let parsed = try parseTrack(b, bodyStart, bodyStart + len)
            if let t = parsed.tempo, tempo == nil || t.tick < tempo!.tick { tempo = t }
            if let s = parsed.timeSig, timeSig == nil || s.tick < timeSig!.tick { timeSig = s }
            guard !parsed.notes.isEmpty else { continue }

            let baseName = parsed.name ?? "Track \(trackIndex)"
            let notes = parsed.notes.map {
                NoteEvent(start: rescale($0.start), duration: max(1, rescale($0.end) - rescale($0.start)),
                          pitch: $0.pitch, velocity: $0.velocity, channel: $0.channel)
            }
            func makeClip(_ name: String, _ ns: [NoteEvent]) -> Clip {
                let end = ns.map { $0.end }.max() ?? 0
                let bars = max(1, (end + bar - 1) / bar)
                return Clip(name: name, notes: ns, lengthTicks: bars * bar)
            }
            let channels = Set(notes.map { $0.channel })
            if format == 0 && channels.count > 1 {
                for ch in channels.sorted() {
                    clips.append(makeClip("\(baseName) ch\(ch)", notes.filter { $0.channel == ch }))
                }
            } else {
                clips.append(makeClip(baseName, notes))
            }
        }

        return MIDIFileContents(
            clips: clips,
            tempoBPM: tempo?.bpm,
            timeSignature: timeSig.map { ($0.num, $0.den) }
        )
    }

    private struct RawNote { var start: Int; var end: Int; var pitch: Int; var velocity: Int; var channel: Int }
    private struct ParsedTrack {
        var notes: [RawNote] = []
        var name: String?
        var tempo: (tick: Int, bpm: Double)?
        var timeSig: (tick: Int, num: Int, den: Int)?
    }

    private static func parseTrack(_ b: [UInt8], _ start: Int, _ end: Int) throws -> ParsedTrack {
        var r = ParsedTrack()
        var p = start
        var tick = 0
        var running: UInt8?
        // FIFO of indices into r.notes of notes still sounding, keyed by channel*128+pitch.
        var open = [Int: [Int]]()

        func byte() throws -> UInt8 {
            guard p < end else { throw MIDIFileError.truncated }
            defer { p += 1 }
            return b[p]
        }
        func varLen() throws -> Int {
            var v = 0
            for _ in 0..<4 {
                let c = try byte()
                v = (v << 7) | Int(c & 0x7F)
                if c & 0x80 == 0 { return v }
            }
            throw MIDIFileError.truncated
        }
        func noteOff(_ ch: Int, _ pitch: Int) {
            let key = ch * 128 + pitch
            if var q = open[key], !q.isEmpty {
                let idx = q.removeFirst()
                r.notes[idx].end = tick
                open[key] = q
            }
        }

        while p < end {
            tick += try varLen()
            var status = try byte()
            var firstData: UInt8?
            if status < 0x80 {
                guard let rs = running else { throw MIDIFileError.truncated }
                firstData = status
                status = rs
            }
            switch status {
            case 0xFF:
                running = nil
                let type = try byte()
                let len = try varLen()
                guard p + len <= end else { throw MIDIFileError.truncated }
                let payload = Array(b[p..<p + len])
                p += len
                switch type {
                case 0x03 where r.name == nil:
                    r.name = String(decoding: payload, as: UTF8.self)
                case 0x51 where payload.count == 3 && r.tempo == nil:
                    let us = (Int(payload[0]) << 16) | (Int(payload[1]) << 8) | Int(payload[2])
                    if us > 0 { r.tempo = (tick, 60_000_000.0 / Double(us)) }
                case 0x58 where payload.count >= 2 && r.timeSig == nil:
                    r.timeSig = (tick, Int(payload[0]), 1 << Int(min(payload[1], 16)))
                case 0x2F:
                    p = end
                default: break
                }
            case 0xF0, 0xF7:
                running = nil
                let len = try varLen()
                guard p + len <= end else { throw MIDIFileError.truncated }
                p += len
            case 0xF1, 0xF3: running = nil; _ = try byte()
            case 0xF2: running = nil; _ = try byte(); _ = try byte()
            case 0xF4...0xFE: running = nil
            default:
                running = status
                let kind = status & 0xF0
                let ch = Int(status & 0x0F)
                let d1 = try firstData ?? byte()
                let d2: UInt8 = (kind == 0xC0 || kind == 0xD0) ? 0 : try byte()
                if kind == 0x90 && d2 > 0 {
                    r.notes.append(RawNote(start: tick, end: tick, pitch: Int(d1), velocity: Int(d2), channel: ch + 1))
                    open[ch * 128 + Int(d1), default: []].append(r.notes.count - 1)
                } else if kind == 0x80 || kind == 0x90 {
                    noteOff(ch, Int(d1))
                }
            }
        }
        // Close any notes left hanging at the end of the track.
        for idx in open.values.flatMap({ $0 }) { r.notes[idx].end = max(tick, r.notes[idx].start + 1) }
        return r
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 8) | Int(b[i + 1])
    }
}
