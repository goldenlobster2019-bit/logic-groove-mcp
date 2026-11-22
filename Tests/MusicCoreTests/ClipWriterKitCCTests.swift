import XCTest
@testable import MusicCore

/// Tests for the 0.4.0 spec keys: kit, program, cc.
final class ClipWriterKitCCTests: XCTestCase {

    private func write(_ json: String) throws -> WrittenClip {
        try ClipWriter.write(json: Data(json.utf8), seed: 1)
    }

    private func errorMessage(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try write(json)
            XCTFail("expected an error", file: file, line: line)
            return ""
        } catch let e as ClipWriterError {
            return e.message
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return ""
        }
    }

    private func pitch(of lane: String, kit: String?) throws -> Int {
        let kitPart = kit.map { ",\"kit\":\"\($0)\"" } ?? ""
        let json = "{\"steps\":{\"\(lane)\":\"x\"}\(kitPart)}"
        return try write(json).clip.notes[0].pitch
    }

    // MARK: - kit

    func testGMDefaultAndNewAliases() throws {
        XCTAssertEqual(try pitch(of: "kick", kit: nil), 36)
        XCTAssertEqual(try pitch(of: "kick", kit: "gm"), 36)
        XCTAssertEqual(try pitch(of: "hat2", kit: "gm"), 46)
        XCTAssertEqual(try pitch(of: "perc", kit: "gm"), 56)
        XCTAssertEqual(try pitch(of: "tom", kit: "gm"), 45)
        XCTAssertEqual(ClipWriter.drumNames["hat2"], 46)
    }

    func testUltrabeatMapping() throws {
        let expected: [String: Int] = [
            "kick": 37, "bd": 37, "snare": 38, "sd": 38,
            "closed_hat": 39, "ch": 39, "hh": 39, "hat": 39,
            "open_hat": 40, "oh": 40, "hat2": 40,
            "low_tom": 41, "mid_tom": 41, "high_tom": 41, "lt": 41, "mt": 41, "ht": 41, "tom": 41,
            "clap": 42, "cp": 42,
            "rim": 43, "rimshot": 43, "sidestick": 43, "perc": 43, "cowbell": 43, "clave": 43,
            "conga_high": 43, "conga_low": 43, "tambourine": 43, "tamb": 43,
            "shaker": 44, "sh": 44, "pedal_hat": 44, "ph": 44,
        ]
        for (name, pitch) in expected {
            XCTAssertEqual(try self.pitch(of: name, kit: "ultrabeat_init"), pitch, name)
            XCTAssertEqual(ClipWriter.drumNames(kit: "ultrabeat_init")?[name], pitch, name)
        }
        XCTAssertEqual(ClipWriter.drumNames(kit: "gm")?["kick"], 36)
        XCTAssertNil(ClipWriter.drumNames(kit: "nope"))
    }

    func testUltrabeatNotesEntries() throws {
        let clip = try write("{\"kit\":\"ultrabeat_init\",\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":\"snare\"},{\"pos\":\"1.2.1\",\"pitch\":\"clap\"}]}").clip
        XCTAssertEqual(clip.notes.map { $0.pitch }, [38, 42])
    }

    func testUltrabeatMissingVoicesAreErrors() {
        for name in ["ride", "ride_bell", "crash"] {
            let m = errorMessage("{\"kit\":\"ultrabeat_init\",\"steps\":{\"\(name)\":\"x\"}}")
            XCTAssertTrue(m.contains("steps.\(name)") && m.contains("ultrabeat_init"), m)
            let n = errorMessage("{\"kit\":\"ultrabeat_init\",\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":\"\(name)\"}]}")
            XCTAssertTrue(n.contains("notes[0]") && n.contains("ultrabeat_init"), n)
        }
        // Still fine in GM.
        XCTAssertEqual(try pitch(of: "ride", kit: "gm"), 51)
    }

    func testUnknownKit() {
        XCTAssertEqual(errorMessage("{\"kit\":\"tr808\",\"steps\":{\"kick\":\"x\"}}"), "kit must be gm or ultrabeat_init")
        XCTAssertEqual(errorMessage("{\"kit\":5,\"steps\":{\"kick\":\"x\"}}"), "kit must be gm or ultrabeat_init")
    }

    func testKitDoesNotAffectPitchedNames() throws {
        let clip = try write("{\"kit\":\"ultrabeat_init\",\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":\"C3\"}]}").clip
        XCTAssertEqual(clip.notes[0].pitch, 60)
    }

    func testUltrabeatStepsLanes() throws {
        let clip = try write("{\"kit\":\"ultrabeat_init\",\"steps\":{\"kick\":\"x...x...\",\"snare\":\"....x...\",\"hat\":\"..x...x.\"},\"pattern_bars\":1}").clip
        XCTAssertEqual(Set(clip.notes.map { $0.pitch }), [37, 38, 39])
    }

    // MARK: - program

    private func bytes(_ clip: Clip) -> [UInt8] { [UInt8](MIDIFileIO.write(clip: clip)) }

    private func firstIndex(of pattern: [UInt8], in b: [UInt8]) -> Int? {
        guard b.count >= pattern.count else { return nil }
        for i in 0...(b.count - pattern.count) where Array(b[i..<i + pattern.count]) == pattern { return i }
        return nil
    }

    func testProgramRoundTripAndPosition() throws {
        let clip = try write("{\"program\":5,\"channel\":10,\"steps\":{\"kick\":\"x...\"}}").clip
        XCTAssertEqual(clip.program, 5)
        let b = bytes(clip)
        let pc = try XCTUnwrap(firstIndex(of: [0xC9, 0x05], in: b))
        let on = try XCTUnwrap(firstIndex(of: [0x99, 0x24], in: b))
        XCTAssertLessThan(pc, on)
        // Program change sits at delta 0 directly after the track name meta.
        XCTAssertEqual(b[pc - 1], 0x00)
        let back = try MIDIFileIO.read(Data(b)).clips[0]
        XCTAssertEqual(back.program, 5)
        XCTAssertEqual(back.notes.first?.channel, 10)
    }

    func testProgramRange() {
        XCTAssertTrue(errorMessage("{\"program\":128,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}]}").contains("program must be between 0 and 127"))
        XCTAssertTrue(errorMessage("{\"program\":-1,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}]}").contains("program"))
    }

    func testNoProgramByDefault() throws {
        let clip = try write("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}]}").clip
        XCTAssertNil(clip.program)
        XCTAssertTrue(clip.controls.isEmpty)
        XCTAssertNil(try MIDIFileIO.read(MIDIFileIO.write(clip: clip)).clips[0].program)
    }

    // MARK: - cc

    private func ccJSON(_ lane: String, bars: Int = 1) -> String {
        "{\"bars\":\(bars),\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}],\"cc\":[\(lane)]}"
    }

    func testLinearInterpolation() throws {
        let clip = try write(ccJSON("{\"cc\":1,\"resolution\":1,\"points\":[{\"step\":0,\"value\":0},{\"step\":8,\"value\":80}]}")).clip
        XCTAssertEqual(clip.controls.map { $0.tick }, [0, 120, 240, 360, 480, 600, 720, 840, 960])
        XCTAssertEqual(clip.controls.map { $0.value }, [0, 10, 20, 30, 40, 50, 60, 70, 80])
        XCTAssertTrue(clip.controls.allSatisfy { $0.controller == 1 && $0.channel == 1 })
    }

    func testDefaultResolutionIsHalfSixteenth() throws {
        let clip = try write(ccJSON("{\"cc\":74,\"points\":[{\"step\":0,\"value\":0},{\"step\":2,\"value\":100}]}")).clip
        // stride 60 ticks: 0, 60, 120, 180, exact 240
        XCTAssertEqual(clip.controls.map { $0.tick }, [0, 60, 120, 180, 240])
        XCTAssertEqual(clip.controls.map { $0.value }, [0, 25, 50, 75, 100])
    }

    func testPointsAnyOrderAndPosSyntax() throws {
        let clip = try write(ccJSON("{\"cc\":1,\"curve\":\"step\",\"points\":[{\"pos\":\"1.2.1\",\"value\":90},{\"pos\":\"1.1.1\",\"value\":10}]}")).clip
        XCTAssertEqual(clip.controls.map { $0.tick }, [0, 480])
        XCTAssertEqual(clip.controls.map { $0.value }, [10, 90])
    }

    func testStepCurveEmitsOnlyAtPoints() throws {
        let clip = try write(ccJSON("{\"cc\":1,\"curve\":\"step\",\"points\":[{\"step\":0,\"value\":10},{\"step\":4,\"value\":20},{\"step\":8,\"value\":30}]}")).clip
        XCTAssertEqual(clip.controls.map { $0.tick }, [0, 480, 960])
        XCTAssertEqual(clip.controls.map { $0.value }, [10, 20, 30])
    }

    func testEqualConsecutiveValuesAreSkipped() throws {
        let flat = try write(ccJSON("{\"cc\":1,\"resolution\":1,\"points\":[{\"step\":0,\"value\":64},{\"step\":8,\"value\":64}]}")).clip
        XCTAssertEqual(flat.controls.map { $0.tick }, [0, 960])   // only the exact point values
        let ramp = try write(ccJSON("{\"cc\":1,\"resolution\":1,\"points\":[{\"step\":0,\"value\":0},{\"step\":8,\"value\":2}]}")).clip
        XCTAssertEqual(ramp.controls.map { $0.value }, [0, 1, 2, 2])
        XCTAssertEqual(ramp.controls.map { $0.tick }, [0, 240, 720, 960])
    }

    func testEventsBeyondClipEndAreDropped() throws {
        let w = try write(ccJSON("{\"cc\":1,\"resolution\":4,\"points\":[{\"step\":0,\"value\":0},{\"step\":32,\"value\":127}]}"))
        XCTAssertEqual(w.clip.controls.map { $0.tick }, [0, 480, 960, 1440])
        XCTAssertTrue(w.clip.controls.allSatisfy { $0.tick < w.clip.lengthTicks })
        XCTAssertTrue(w.warnings.contains { $0.contains("cc point") })
    }

    func testCCNotTiledByPatternBars() throws {
        let json = "{\"pattern_bars\":1,\"bars\":4,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}],\"cc\":[{\"cc\":1,\"curve\":\"step\",\"points\":[{\"step\":0,\"value\":0},{\"step\":16,\"value\":127}]}]}"
        let clip = try write(json).clip
        XCTAssertEqual(clip.notes.count, 4)
        XCTAssertEqual(clip.controls.count, 2)
        XCTAssertEqual(clip.controls.map { $0.tick }, [0, 1920])
    }

    func testCCRoundTripThroughMIDIFile() throws {
        let clip = try write(ccJSON("{\"cc\":1,\"resolution\":1,\"points\":[{\"step\":0,\"value\":0},{\"step\":8,\"value\":80}]},{\"cc\":74,\"curve\":\"step\",\"points\":[{\"step\":0,\"value\":5},{\"step\":4,\"value\":6}]}")).clip
        let back = try MIDIFileIO.read(MIDIFileIO.write(clip: clip)).clips[0]
        XCTAssertEqual(back.controls, clip.controls)
        XCTAssertEqual(back.notes, clip.notes)
    }

    func testControllerBeforeNoteOnAtSameTick() throws {
        let clip = try write(ccJSON("{\"cc\":1,\"curve\":\"step\",\"points\":[{\"step\":0,\"value\":7},{\"step\":4,\"value\":8}]}")).clip
        let b = bytes(clip)
        let cc = try XCTUnwrap(firstIndex(of: [0xB0, 0x01, 0x07], in: b))
        let on = try XCTUnwrap(firstIndex(of: [0x90, 0x3C], in: b))
        XCTAssertLessThan(cc, on)
    }

    func testCCValidation() {
        XCTAssertTrue(errorMessage(ccJSON("{\"cc\":128,\"points\":[{\"step\":0,\"value\":0},{\"step\":1,\"value\":1}]}")).contains("cc must be between 0 and 127"))
        XCTAssertTrue(errorMessage(ccJSON("{\"cc\":1,\"points\":[{\"step\":0,\"value\":0}]}")).contains("between 2 and 512"))
        XCTAssertTrue(errorMessage(ccJSON("{\"cc\":1,\"points\":[{\"step\":0,\"value\":0},{\"step\":1,\"value\":200}]}")).contains("value must be between 0 and 127"))
        XCTAssertTrue(errorMessage(ccJSON("{\"cc\":1,\"curve\":\"smooth\",\"points\":[{\"step\":0,\"value\":0},{\"step\":1,\"value\":1}]}")).contains("curve must be linear or step"))
        XCTAssertTrue(errorMessage(ccJSON("{\"cc\":1,\"resolution\":0.1,\"points\":[{\"step\":0,\"value\":0},{\"step\":1,\"value\":1}]}")).contains("resolution must be between 0.25 and 4"))
        XCTAssertTrue(errorMessage(ccJSON("{\"cc\":1,\"resolution\":5,\"points\":[{\"step\":0,\"value\":0},{\"step\":1,\"value\":1}]}")).contains("resolution"))
        let lane = "{\"cc\":1,\"points\":[{\"step\":0,\"value\":0},{\"step\":1,\"value\":1}]}"
        let many = Array(repeating: lane, count: 17).joined(separator: ",")
        XCTAssertTrue(errorMessage(ccJSON(many)).contains("max 16"))
    }

    func testControlEventLimit() {
        // 512 points zig-zagging 0/127 every 8 steps at the finest resolution: about 16k events per lane.
        let points = (0..<512).map { "{\"step\":\($0 * 8),\"value\":\($0 % 2 == 0 ? 0 : 127)}" }.joined(separator: ",")
        let lanes = (0..<3).map { "{\"cc\":\($0),\"resolution\":0.25,\"points\":[\(points)]}" }.joined(separator: ",")
        let m = errorMessage(ccJSON(lanes, bars: 256))
        XCTAssertTrue(m.contains("too many cc events"), m)
    }

    // MARK: - backwards compatibility

    func testSpecWithoutNewKeysIsByteIdenticalToOldClip() throws {
        let written = try write("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60,\"len\":1,\"vel\":100}]}").clip
        let old = Clip(name: written.name, notes: written.notes, lengthTicks: written.lengthTicks)
        XCTAssertEqual(MIDIFileIO.write(clip: written), MIDIFileIO.write(clip: old))
        // Fixed expectation: note-on, note-off after 120 ticks, end of track at the bar line.
        let b = [UInt8](MIDIFileIO.write(clip: old))
        XCTAssertNotNil(firstIndex(of: [0x00, 0x90, 0x3C, 0x64, 0x78, 0x80, 0x3C, 0x40, 0x8E, 0x08, 0xFF, 0x2F, 0x00], in: b))
    }
}
