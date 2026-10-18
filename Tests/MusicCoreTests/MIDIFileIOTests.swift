import XCTest
@testable import MusicCore

final class MIDIFileIOTests: XCTestCase {

    private func sampleClip(_ name: String = "Stabs") -> Clip {
        Clip(name: name, notes: [
            NoteEvent(start: 0, duration: 240, pitch: 53, velocity: 90, channel: 1),
            NoteEvent(start: 240, duration: 240, pitch: 56, velocity: 100, channel: 1),
            NoteEvent(start: 480, duration: 480, pitch: 60, velocity: 64, channel: 1),
            NoteEvent(start: 960, duration: 960, pitch: 36, velocity: 127, channel: 1),
        ], lengthTicks: 3840)
    }

    func testRoundTripWithTempo() throws {
        let clip = sampleClip()
        let data = MIDIFileIO.write(clip: clip, tempoBPM: 122)
        let back = try MIDIFileIO.read(data)
        XCTAssertEqual(back.clips.count, 1)
        XCTAssertEqual(back.clips[0].name, "Stabs")
        XCTAssertEqual(back.clips[0].notes, clip.notes)
        XCTAssertEqual(try XCTUnwrap(back.tempoBPM), 122, accuracy: 0.01)
        XCTAssertEqual(back.timeSignature?.numerator, 4)
        XCTAssertEqual(back.timeSignature?.denominator, 4)
        XCTAssertEqual(back.clips[0].lengthTicks, 1920)
    }

    func testNoTempoWhenNil() throws {
        let back = try MIDIFileIO.read(MIDIFileIO.write(clip: sampleClip()))
        XCTAssertNil(back.tempoBPM)
        XCTAssertNotNil(back.timeSignature)
    }

    func testMultipleClipsAndChannels() throws {
        let a = sampleClip("A")
        let b = Clip(name: "Drums", notes: [NoteEvent(start: 0, duration: 120, pitch: 36, velocity: 110, channel: 10)], lengthTicks: 1920)
        let back = try MIDIFileIO.read(MIDIFileIO.write(clips: [a, b]))
        XCTAssertEqual(back.clips.map { $0.name }, ["A", "Drums"])
        XCTAssertEqual(back.clips[1].notes, b.notes)
    }

    func testStartOffset() throws {
        let clip = sampleClip()
        let back = try MIDIFileIO.read(MIDIFileIO.write(clip: clip, startOffsetTicks: 1920 * 4))
        XCTAssertEqual(back.clips[0].notes.map { $0.start }, clip.notes.map { $0.start + 7680 })
    }

    func testRepeatedNoteRetriggers() throws {
        let clip = Clip(name: "R", notes: [
            NoteEvent(start: 0, duration: 480, pitch: 60), NoteEvent(start: 480, duration: 480, pitch: 60),
        ], lengthTicks: 1920)
        let back = try MIDIFileIO.read(MIDIFileIO.write(clip: clip))
        XCTAssertEqual(back.clips[0].notes, clip.notes)
    }

    func testClampingAndDropping() throws {
        let clip = Clip(name: "C", notes: [
            NoteEvent(start: 0, duration: 0, pitch: 60),
            NoteEvent(start: 0, duration: 100, pitch: 200, velocity: 500),
        ], lengthTicks: 1920)
        let back = try MIDIFileIO.read(MIDIFileIO.write(clip: clip))
        XCTAssertEqual(back.clips[0].notes.count, 1)
        XCTAssertEqual(back.clips[0].notes[0].pitch, 127)
        XCTAssertEqual(back.clips[0].notes[0].velocity, 127)
    }

    private func smf(format: UInt8, division: [UInt8] = [0x01, 0xE0], tracks: [[UInt8]]) -> Data {
        var d = Array("MThd".utf8) + [0, 0, 0, 6, 0, format, 0, UInt8(tracks.count)] + division
        for t in tracks {
            d += Array("MTrk".utf8) + [UInt8((t.count >> 24) & 0xFF), UInt8((t.count >> 16) & 0xFF), UInt8((t.count >> 8) & 0xFF), UInt8(t.count & 0xFF)] + t
        }
        return Data(d)
    }

    func testRunningStatusAndVelocityZeroNoteOff() throws {
        // 480 ppq. Note-on C3 (60), then running-status note-on E3 (64); both ended with velocity-0 note-ons (running status).
        let track: [UInt8] = [
            0x00, 0x90, 60, 100,
            0x00, 64, 90,            // running status
            0x83, 0x60, 60, 0,       // delta 480 (0x83 0x60), vel 0 off
            0x00, 64, 0,
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let back = try MIDIFileIO.read(smf(format: 0, tracks: [track]))
        XCTAssertEqual(back.clips.count, 1)
        XCTAssertEqual(back.clips[0].notes.count, 2)
        XCTAssertEqual(back.clips[0].notes.map { $0.pitch }, [60, 64])
        XCTAssertEqual(back.clips[0].notes.map { $0.duration }, [480, 480])
        XCTAssertEqual(back.clips[0].notes[0].velocity, 100)
        XCTAssertEqual(back.clips[0].lengthTicks, 1920)
        XCTAssertEqual(back.clips[0].name, "Track 1")
    }

    func testOverlappingSamePitchFIFO() throws {
        let track: [UInt8] = [
            0x00, 0x90, 60, 100,
            0x78, 0x90, 60, 80,      // second on at 120
            0x78, 0x80, 60, 0,       // off at 240 -> closes first (FIFO)
            0x78, 0x80, 60, 0,       // off at 360 -> closes second
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let back = try MIDIFileIO.read(smf(format: 0, tracks: [track]))
        let n = back.clips[0].notes
        XCTAssertEqual(n.map { $0.start }, [0, 120])
        XCTAssertEqual(n.map { $0.duration }, [240, 240])
    }

    func testFormat0SplitsByChannel() throws {
        let track: [UInt8] = [
            0x00, 0x90, 60, 100,
            0x00, 0x91, 36, 100,
            0x60, 0x80, 60, 0,
            0x00, 0x81, 36, 0,
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let back = try MIDIFileIO.read(smf(format: 0, tracks: [track]))
        XCTAssertEqual(back.clips.count, 2)
        XCTAssertEqual(back.clips.map { $0.notes[0].channel }, [1, 2])
    }

    func testSysexAndMetaSkipped() throws {
        let track: [UInt8] = [
            0x00, 0xF0, 0x03, 0x7E, 0x01, 0xF7,
            0x00, 0xFF, 0x01, 0x02, 0x68, 0x69,  // text meta
            0x00, 0xFF, 0x03, 0x03, 0x42, 0x61, 0x73,  // "Bas"
            0x00, 0xC0, 5,                        // program change (1 data byte)
            0x00, 0x90, 40, 100,
            0x60, 0x80, 40, 0,
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let back = try MIDIFileIO.read(smf(format: 1, tracks: [track]))
        XCTAssertEqual(back.clips[0].name, "Bas")
        XCTAssertEqual(back.clips[0].notes.count, 1)
    }

    func testPPQRescale96() throws {
        // 96 ppq: quarter note = 96 ticks -> 480.
        let track: [UInt8] = [
            0x00, 0x90, 60, 100,
            0x60, 0x80, 60, 0,       // delta 96
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let back = try MIDIFileIO.read(smf(format: 0, division: [0x00, 0x60], tracks: [track]))
        XCTAssertEqual(back.clips[0].notes[0].duration, 480)
    }

    func testTempoFromFile() throws {
        let track: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xFF, 0x2F, 0x00] // 500000 us = 120 bpm
        let back = try MIDIFileIO.read(smf(format: 1, tracks: [track]))
        XCTAssertEqual(try XCTUnwrap(back.tempoBPM), 120, accuracy: 0.001)
        XCTAssertTrue(back.clips.isEmpty)
    }

    func testVLQEncoding() {
        XCTAssertEqual(MIDIFileIO.vlq(0), [0x00])
        XCTAssertEqual(MIDIFileIO.vlq(127), [0x7F])
        XCTAssertEqual(MIDIFileIO.vlq(128), [0x81, 0x00])
        XCTAssertEqual(MIDIFileIO.vlq(0x3FFF), [0xFF, 0x7F])
        XCTAssertEqual(MIDIFileIO.vlq(0x0FFFFFFF), [0xFF, 0xFF, 0xFF, 0x7F])
    }

    func testVLQRoundTripEdgeValues() throws {
        for start in [0, 127, 128, 0x0FFF_FFFF - 100] {
            let clip = Clip(name: "V", notes: [NoteEvent(start: start, duration: 100, pitch: 60)], lengthTicks: 1920)
            let back = try MIDIFileIO.read(MIDIFileIO.write(clip: clip))
            XCTAssertEqual(back.clips[0].notes[0].start, start)
        }
        // Delta of exactly 0x0FFFFFFF via a hand-built file.
        let track: [UInt8] = [0xFF, 0xFF, 0xFF, 0x7F, 0x90, 60, 100, 0x00, 0x80, 60, 0, 0x00, 0xFF, 0x2F, 0x00]
        let back = try MIDIFileIO.read(smf(format: 0, tracks: [track]))
        XCTAssertEqual(back.clips[0].notes[0].start, 0x0FFF_FFFF)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MIDIFileIO.read(Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]))) {
            XCTAssertEqual($0 as? MIDIFileError, .notMIDI)
        }
        XCTAssertThrowsError(try MIDIFileIO.read(Data())) { XCTAssertEqual($0 as? MIDIFileError, .notMIDI) }
        XCTAssertThrowsError(try MIDIFileIO.read(Data("MThd".utf8))) { XCTAssertEqual($0 as? MIDIFileError, .truncated) }
        let good = [UInt8](MIDIFileIO.write(clip: sampleClip()))
        XCTAssertThrowsError(try MIDIFileIO.read(Data(good.dropLast(5)))) { XCTAssertEqual($0 as? MIDIFileError, .truncated) }
    }

    func testRejectsFormat2AndSMPTE() {
        XCTAssertThrowsError(try MIDIFileIO.read(smf(format: 2, tracks: []))) {
            guard case .unsupportedFormat = $0 as? MIDIFileError else { return XCTFail("wrong error \($0)") }
        }
        XCTAssertThrowsError(try MIDIFileIO.read(smf(format: 0, division: [0xE7, 0x28], tracks: []))) {
            guard case .unsupportedFormat = $0 as? MIDIFileError else { return XCTFail("wrong error \($0)") }
        }
    }

    func testReadURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: url) }
        try MIDIFileIO.write(clip: sampleClip()).write(to: url)
        XCTAssertEqual(try MIDIFileIO.read(url: url).clips[0].notes, sampleClip().notes)
    }
}
