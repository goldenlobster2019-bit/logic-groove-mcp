import XCTest
@testable import MusicCore

final class ClipWriterTests: XCTestCase {

    // MARK: - Helpers

    private func write(_ json: String, seed: UInt64 = 1) throws -> WrittenClip {
        try ClipWriter.write(json: Data(json.utf8), seed: seed)
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

    private func notes(_ json: String) throws -> [NoteEvent] {
        try write(json).clip.notes
    }

    /// Pitches of a single whole-bar chord, ascending.
    private func chordPitches(_ symbol: String, voicing: String = "close", extra: String = "") throws -> [Int] {
        let json = "{\"chords\":[{\"pos\":\"1.1.1\",\"chord\":\"\(symbol)\",\"voicing\":\"\(voicing)\",\"len\":\"1/1\"\(extra)}]}"
        return try notes(json).map { $0.pitch }
    }

    private func start(_ pos: String) throws -> Int {
        try notes("{\"notes\":[{\"pos\":\"\(pos)\",\"pitch\":60}],\"bars\":8}")[0].start
    }

    private func duration(_ len: String) throws -> Int {
        try notes("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60,\"len\":\(len)}],\"bars\":8}")[0].duration
    }

    // MARK: - Positions

    func testPosParsing() throws {
        XCTAssertEqual(try start("1.1.1"), 0)
        XCTAssertEqual(try start("2.3.3"), 1920 + 960 + 240)
        XCTAssertEqual(try start("1.1.3.60"), 300)
        XCTAssertEqual(try start("3"), 3840)
        XCTAssertEqual(try start("2.2"), 1920 + 480)
        XCTAssertEqual(try start("1.4.4.119"), 1440 + 360 + 119)
    }

    func testStepPositions() throws {
        func startAt(_ step: String, grid: Int) throws -> Int {
            try notes("{\"grid\":\(grid),\"notes\":[{\"step\":\(step),\"pitch\":60}],\"bars\":2}")[0].start
        }
        XCTAssertEqual(try startAt("0", grid: 16), 0)
        XCTAssertEqual(try startAt("2.5", grid: 16), 300)
        XCTAssertEqual(try startAt("4", grid: 16), 480)
        XCTAssertEqual(try startAt("2", grid: 12), 320)
        XCTAssertEqual(try startAt("2.5", grid: 12), 400)
        XCTAssertEqual(try startAt("\"3\"", grid: 8), 720)
    }

    // MARK: - Lengths

    func testLengthSyntaxes() throws {
        XCTAssertEqual(try notes("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}]}")[0].duration, 120)
        XCTAssertEqual(try duration("1"), 120)
        XCTAssertEqual(try duration("0.5"), 60)
        XCTAssertEqual(try duration("6"), 720)
        XCTAssertEqual(try duration("\"4\""), 480)
        XCTAssertEqual(try duration("\"1/1\""), 1920)
        XCTAssertEqual(try duration("\"1/2\""), 960)
        XCTAssertEqual(try duration("\"1/4\""), 480)
        XCTAssertEqual(try duration("\"1/8\""), 240)
        XCTAssertEqual(try duration("\"1/16\""), 120)
        XCTAssertEqual(try duration("\"1/32\""), 60)
        XCTAssertEqual(try duration("\"1/8.\""), 360)
        XCTAssertEqual(try duration("\"1/8t\""), 160)
        XCTAssertEqual(try duration("\"1/4.\""), 720)
        XCTAssertEqual(try duration("\"1bar\""), 1920)
        XCTAssertEqual(try duration("\"2bars\""), 3840)
        XCTAssertEqual(try duration("0.001"), 1)
    }

    func testInvalidLength() throws {
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60,\"len\":\"1/3\"}]}"),
                       "notes[0]: invalid len '1/3'")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60,\"len\":0}]}"),
                       "notes[0]: len must be greater than 0")
    }

    // MARK: - Pitches

    func testPitchForms() throws {
        func pitch(_ p: String) throws -> Int {
            try notes("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":\(p)}]}")[0].pitch
        }
        XCTAssertEqual(try pitch("60"), 60)
        XCTAssertEqual(try pitch("1"), 1)
        XCTAssertEqual(try pitch("\"40\""), 40)
        XCTAssertEqual(try pitch("\"C3\""), 60)
        XCTAssertEqual(try pitch("\"F1\""), 41)
        XCTAssertEqual(try pitch("\"C#3\""), 61)
        XCTAssertEqual(try pitch("\"Bb-1\""), 22)
        XCTAssertEqual(try pitch("\"kick\""), 36)
        XCTAssertEqual(try pitch("\"BD\""), 36)
        XCTAssertEqual(try pitch("\"Closed-Hat\""), 42)
        XCTAssertEqual(try pitch("\"open hat\""), 46)
        XCTAssertEqual(try pitch("\"oh\""), 46)
        XCTAssertEqual(try pitch("\"sidestick\""), 37)
        XCTAssertEqual(try pitch("\"shaker\""), 70)
        XCTAssertEqual(try pitch("\"clave\""), 75)
    }

    func testDrumTableMatchesDrumNote() {
        XCTAssertEqual(ClipWriter.drumNames["kick"], DrumNote.kick)
        XCTAssertEqual(ClipWriter.drumNames["rim"], DrumNote.rim)
        XCTAssertEqual(ClipWriter.drumNames["snare"], DrumNote.snare)
        XCTAssertEqual(ClipWriter.drumNames["clap"], DrumNote.clap)
        XCTAssertEqual(ClipWriter.drumNames["closed_hat"], DrumNote.closedHat)
        XCTAssertEqual(ClipWriter.drumNames["pedal_hat"], DrumNote.pedalHat)
        XCTAssertEqual(ClipWriter.drumNames["open_hat"], DrumNote.openHat)
        XCTAssertEqual(ClipWriter.drumNames["low_tom"], DrumNote.lowTom)
        XCTAssertEqual(ClipWriter.drumNames["mid_tom"], DrumNote.midTom)
        XCTAssertEqual(ClipWriter.drumNames["crash"], DrumNote.crash)
        XCTAssertEqual(ClipWriter.drumNames["ride"], DrumNote.ride)
        XCTAssertEqual(ClipWriter.drumNames["shaker"], DrumNote.shaker)
        XCTAssertEqual(ClipWriter.drumNames["cowbell"], DrumNote.cowbell)
    }

    func testTransposeSkipsDrumNames() throws {
        let n = try notes("""
        {"transpose":12,"notes":[
          {"pos":"1.1.1","pitch":"F1"},{"pos":"1.2.1","pitch":"kick"},
          {"pos":"1.3.1","pitch":60},{"pos":"1.4.1","pitch":"hh"}]}
        """)
        XCTAssertEqual(n.map { $0.pitch }, [53, 36, 72, 42])
    }

    func testTransposeAppliesToChordsAndPitchedLanes() throws {
        let n = try notes("""
        {"transpose":-12,"bars":1,"chords":[{"pos":"1.1.1","chord":"F","len":"1/1"}],
         "steps":{"F2":"x...","kick":"x..."}}
        """)
        XCTAssertEqual(Set(n.map { $0.pitch }), [41, 45, 48, 36, 53 - 12])
    }

    func testTransposeClamps() throws {
        XCTAssertEqual(try notes("{\"transpose\":48,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":120}]}")[0].pitch, 127)
    }

    // MARK: - Steps

    func testStepPatternBasic() throws {
        let n = try notes("{\"bars\":1,\"steps\":{\"kick\":\"x...x...x...x...\"}}")
        XCTAssertEqual(n.map { $0.start }, [0, 480, 960, 1440])
        XCTAssertTrue(n.allSatisfy { $0.pitch == 36 && $0.duration == 120 && $0.velocity == 100 })
    }

    func testStepAccentSoftGhost() throws {
        let n = try notes("{\"bars\":1,\"steps\":{\"snare\":\"xXog\"}}")
        XCTAssertEqual(n.map { $0.velocity }.prefix(4), [100, 120, 70, 45])
    }

    func testStepVelocityClamping() throws {
        let n = try notes("{\"bars\":1,\"steps\":{\"snare\":{\"pattern\":\"Xg\",\"vel\":120}}}")
        XCTAssertEqual(n[0].velocity, 127)
        XCTAssertEqual(n[1].velocity, 65)
        let low = try notes("{\"bars\":1,\"steps\":{\"snare\":{\"pattern\":\"g\",\"vel\":20}}}")
        XCTAssertEqual(low[0].velocity, 1)
    }

    func testStepTie() throws {
        let n = try notes("{\"bars\":1,\"steps\":{\"F1\":\"x__.\"}}")
        XCTAssertEqual(n.count, 4)
        XCTAssertEqual(n[0].duration, 360)
    }

    func testStepTieAcrossRepeatBoundary() throws {
        let w = try write("{\"bars\":1,\"grid\":4,\"steps\":{\"F1\":\"_x\"}}")
        XCTAssertEqual(w.clip.notes.map { $0.start }, [480, 1440])
        XCTAssertEqual(w.clip.notes[0].duration, 960)
        XCTAssertEqual(w.clip.notes[1].duration, 480)
        XCTAssertEqual(w.warnings.count, 1)
        XCTAssertTrue(w.warnings[0].contains("steps.F1"))
    }

    func testStepCyclingFillsBars() throws {
        let n = try notes("{\"bars\":2,\"steps\":{\"kick\":\"x...\"}}")
        XCTAssertEqual(n.count, 8)
        XCTAssertEqual(n.last?.start, 1920 + 1440)
        let two = try notes("{\"bars\":4,\"steps\":{\"kick\":\"x...............x...............\"}}")
        XCTAssertEqual(two.map { $0.start }, [0, 1920, 3840, 5760])
        let one = try notes("{\"bars\":4,\"steps\":{\"kick\":\"x...............................\"}}")
        XCTAssertEqual(one.map { $0.start }, [0, 3840])
    }

    func testStepSeparatorsIgnored() throws {
        let a = try notes("{\"bars\":1,\"steps\":{\"kick\":\"x... x... | x... x...\"}}")
        let b = try notes("{\"bars\":1,\"steps\":{\"kick\":\"x...x...x...x...\"}}")
        XCTAssertEqual(a, b)
    }

    func testStepLaneObjectForm() throws {
        let n = try notes("{\"bars\":1,\"steps\":{\"clap\":{\"pattern\":\"x.x.\",\"vel\":80,\"len\":\"1/8\"}}}")
        XCTAssertEqual(n.map { $0.start }, [0, 240, 480, 720, 960, 1200, 1440, 1680])
        XCTAssertTrue(n.allSatisfy { $0.pitch == 39 && $0.velocity == 80 && $0.duration == 240 })
    }

    func testStepLaneKeys() throws {
        let n = try notes("{\"bars\":1,\"steps\":{\"hh\":\"x\",\"36\":\"x\",\"F1\":\"x\"}}")
        XCTAssertEqual(Set(n.map { $0.pitch }), [42, 36, 41])
    }

    func testStepTripletGrid() throws {
        let n = try notes("{\"bars\":1,\"grid\":12,\"steps\":{\"kick\":\"x...\"}}")
        XCTAssertEqual(n.map { $0.start }, [0, 640, 1280])
        XCTAssertEqual(n[0].duration, 160)
    }

    func testStepsDeriveBars() throws {
        let w = try write("{\"steps\":{\"kick\":\"x...............x...............\"}}")
        XCTAssertEqual(w.clip.lengthTicks, 3840)
        XCTAssertEqual(w.clip.notes.map { $0.start }, [0, 1920])
        XCTAssertEqual(try write("{\"steps\":{\"kick\":\"x...\"}}").clip.lengthTicks, 1920)
    }

    // MARK: - Chord symbols (close voicing, root octave 2, F2 = 53)

    func testChordSymbols() throws {
        let expected: [(String, [Int])] = [
            ("F", [53, 57, 60]), ("Fm", [53, 56, 60]), ("Fmin", [53, 56, 60]), ("F-", [53, 56, 60]),
            ("Fmaj", [53, 57, 60]), ("FM", [53, 57, 60]),
            ("Fdim", [53, 56, 59]), ("Faug", [53, 57, 61]), ("F+", [53, 57, 61]),
            ("Fsus2", [53, 55, 60]), ("Fsus4", [53, 58, 60]), ("Fsus", [53, 58, 60]),
            ("F5", [53, 60]), ("F6", [53, 57, 60, 62]), ("Fm6", [53, 56, 60, 62]),
            ("F7", [53, 57, 60, 63]), ("Fm7", [53, 56, 60, 63]),
            ("Fmaj7", [53, 57, 60, 64]), ("FM7", [53, 57, 60, 64]),
            ("Fmmaj7", [53, 56, 60, 64]), ("Fm(maj7)", [53, 56, 60, 64]),
            ("Fdim7", [53, 56, 59, 62]), ("Fm7b5", [53, 56, 59, 63]),
            ("F9", [53, 57, 60, 63, 67]), ("Fm9", [53, 56, 60, 63, 67]), ("Fmaj9", [53, 57, 60, 64, 67]),
            ("F11", [53, 60, 63, 67, 70]), ("Fm11", [53, 56, 60, 63, 67, 70]),
            ("F13", [53, 57, 60, 63, 67, 74]), ("Fm13", [53, 56, 60, 63, 67, 74]),
            ("Fadd9", [53, 57, 60, 67]), ("Fm(add9)", [53, 56, 60, 67]), ("Fmadd9", [53, 56, 60, 67]),
            ("Fadd11", [53, 57, 60, 70]),
            ("F7sus4", [53, 58, 60, 63]), ("F9sus4", [53, 58, 60, 63, 67]), ("Fm7sus4", [53, 58, 60, 63]),
            ("F7#9", [53, 57, 60, 63, 68]), ("F7b9", [53, 57, 60, 63, 66]),
            ("Fmaj7#11", [53, 57, 60, 64, 71]), ("F7b5", [53, 57, 59, 63]),
            ("F7#5", [53, 57, 61, 63]), ("F7b13", [53, 57, 60, 63, 73]),
            ("Bb", [58, 62, 65]), ("F#m7", [54, 57, 61, 64]), ("Dbmaj7", [49, 53, 56, 60]), ("C", [48, 52, 55]),
        ]
        XCTAssertGreaterThanOrEqual(expected.count, 20)
        for (symbol, pitches) in expected {
            XCTAssertEqual(try chordPitches(symbol), pitches, "chord \(symbol)")
        }
    }

    func testChordOctave() throws {
        XCTAssertEqual(try chordPitches("Fm", extra: ",\"octave\":1"), [41, 44, 48])
    }

    func testVoicings() throws {
        XCTAssertEqual(try chordPitches("Fm9", voicing: "close"), [53, 56, 60, 63, 67])
        XCTAssertEqual(try chordPitches("Fm9", voicing: "dub"), [53, 60, 63, 67, 68])
        XCTAssertEqual(try chordPitches("F13", voicing: "dub"), [53, 60, 63, 67, 69])
        XCTAssertEqual(try chordPitches("Fm7", voicing: "spread"), [53, 60, 63, 68])
        XCTAssertEqual(try chordPitches("F13", voicing: "spread"), [53, 60, 63, 67, 69, 74])
        XCTAssertEqual(try chordPitches("Fsus4", voicing: "spread"), [53, 60, 70])
        XCTAssertEqual(try chordPitches("Fm7", voicing: "shell"), [53, 56, 63])
        XCTAssertEqual(try chordPitches("Fmaj9", voicing: "shell"), [53, 57, 64])
        XCTAssertEqual(try chordPitches("F11", voicing: "shell"), [53, 60, 63])
        XCTAssertEqual(try chordPitches("Fsus4", voicing: "shell"), [53, 58, 60])
        XCTAssertEqual(try chordPitches("Fadd9", voicing: "shell"), [53, 57, 60])
        XCTAssertEqual(try chordPitches("Fm9", voicing: "rootless"), [56, 60, 63, 67])
        XCTAssertEqual(try chordPitches("F5", voicing: "rootless"), [53, 60])
    }

    func testInvalidVoicing() {
        XCTAssertEqual(errorMessage("{\"chords\":[{\"pos\":\"1.1.1\",\"chord\":\"F\",\"voicing\":\"wide\"}]}"),
                       "chords[0]: voicing must be one of close, dub, spread, shell, rootless")
    }

    func testInversion() throws {
        XCTAssertEqual(try chordPitches("Fm7", extra: ",\"inversion\":1"), [56, 60, 63, 65])
        XCTAssertEqual(try chordPitches("Fm7", extra: ",\"inversion\":2"), [60, 63, 65, 68])
    }

    func testStrum() throws {
        let n = try notes("{\"chords\":[{\"pos\":\"1.1.1\",\"chord\":\"Fm7\",\"strum\":10,\"len\":\"1/2\"}]}")
        XCTAssertEqual(n.map { $0.pitch }, [53, 56, 60, 63])
        XCTAssertEqual(n.map { $0.start }, [0, 10, 20, 30])
    }

    func testSlashBass() throws {
        XCTAssertEqual(try chordPitches("Fm7/C"), [36, 53, 56, 60, 63])
        XCTAssertEqual(try chordPitches("Fm7/C", extra: ",\"inversion\":1"), [36, 56, 60, 63, 65])
        XCTAssertEqual(try chordPitches("F/A"), [45, 53, 57, 60])
    }

    func testExplicitPitchesAndVelTop() throws {
        let n = try notes("""
        {"chords":[{"pos":"1.1.1","pitches":[41,"C2","Eb3"],"vel":70,"vel_top":110,"len":"1/2"}]}
        """)
        XCTAssertEqual(n.map { $0.pitch }, [41, 48, 63])
        XCTAssertEqual(n.map { $0.velocity }, [70, 70, 110])
        let t = try notes("{\"transpose\":2,\"chords\":[{\"pos\":\"1.1.1\",\"pitches\":[41,\"C2\",63]}]}")
        XCTAssertEqual(t.map { $0.pitch }, [43, 50, 65])
    }

    func testChordViaStep() throws {
        let n = try notes("{\"chords\":[{\"step\":4,\"chord\":\"C\"}]}")
        XCTAssertEqual(n.first?.start, 480)
    }

    // MARK: - Tiling and length

    func testPatternBarsTiling() throws {
        let w = try write("{\"pattern_bars\":1,\"bars\":4,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":36,\"len\":2}]}")
        XCTAssertEqual(w.clip.notes.map { $0.start }, [0, 1920, 3840, 5760])
        XCTAssertEqual(w.clip.lengthTicks, 7680)
        XCTAssertTrue(w.warnings.isEmpty)
    }

    func testPatternBarsPartialTileIsSilent() throws {
        let w = try write("{\"pattern_bars\":2,\"bars\":3,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":36},{\"pos\":\"2.1.1\",\"pitch\":40}]}")
        XCTAssertEqual(w.clip.notes.map { $0.start }, [0, 1920, 3840])
        XCTAssertTrue(w.warnings.isEmpty)
    }

    func testPatternBarsDerivedLength() throws {
        XCTAssertEqual(try write("{\"pattern_bars\":2,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":36}]}").clip.lengthTicks, 3840)
    }

    func testBarsDerivedFromContent() throws {
        XCTAssertEqual(try write("{\"notes\":[{\"pos\":\"3.1.1\",\"pitch\":36}]}").clip.lengthTicks, 3 * 1920)
        XCTAssertEqual(try write("{\"notes\":[{\"pos\":\"1.4.4\",\"pitch\":36}]}").clip.lengthTicks, 1920)
        XCTAssertEqual(try write("{\"notes\":[{\"pos\":\"1.4.4\",\"pitch\":36,\"len\":2}]}").clip.lengthTicks, 3840)
    }

    func testNameAndChannel() throws {
        let w = try write("{\"name\":\"Stab\",\"channel\":10,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":36}]}")
        XCTAssertEqual(w.clip.name, "Stab")
        XCTAssertEqual(w.clip.notes[0].channel, 10)
        XCTAssertEqual(try write("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":36}]}").clip.name, "Written clip")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(try write("{\"name\":\"\(long)\",\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":36}]}").clip.name.count, 80)
    }

    func testNumericStringsAndUnknownKeys() throws {
        let n = try notes("{\"foo\":1,\"bars\":\"2\",\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":\"36\",\"vel\":\"90\",\"len\":\"2\",\"bar\":1}]}")
        XCTAssertEqual(n[0].velocity, 90)
        XCTAssertEqual(n[0].duration, 240)
    }

    // MARK: - Swing and humanize

    func testSwingOffsets() throws {
        let n = try notes("{\"bars\":1,\"swing\":0.5,\"steps\":{\"kick\":\"xxxx............\"}}")
        XCTAssertEqual(n.map { $0.start }, [0, 144, 240, 384])
        let full = try notes("{\"bars\":1,\"swing\":1,\"steps\":{\"kick\":\"xxxx............\"}}")
        XCTAssertEqual(full.map { $0.start }, [0, 168, 240, 408])
        // Off-grid notes are not swung.
        let off = try notes("{\"swing\":1,\"notes\":[{\"pos\":\"1.1.2.10\",\"pitch\":36}]}")
        XCTAssertEqual(off[0].start, 130)
    }

    func testHumanizeDeterministicAndBounded() throws {
        let spec = "{\"bars\":2,\"humanize\":0.5,\"steps\":{\"kick\":\"x...x...x...x...\",\"hh\":\"..x...x...x...x.\"}}"
        let a = try write(spec, seed: 7).clip
        let b = try write(spec, seed: 7).clip
        let c = try write(spec, seed: 8).clip
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        let exact = try write("{\"bars\":2,\"steps\":{\"kick\":\"x...x...x...x...\",\"hh\":\"..x...x...x...x.\"}}").clip
        XCTAssertEqual(a.notes.count, exact.notes.count)
        for n in a.notes {
            XCTAssertTrue((88...112).contains(n.velocity), "velocity \(n.velocity)")
            XCTAssertEqual(n.start % 120 <= 4 || n.start % 120 >= 116, true)
        }
    }

    func testNoHumanizeIsExactRegardlessOfSeed() throws {
        let spec = "{\"bars\":1,\"steps\":{\"kick\":\"x...x...x...x...\"}}"
        XCTAssertEqual(try write(spec, seed: 1).clip, try write(spec, seed: 99).clip)
        XCTAssertEqual(try write(spec).clip.notes.map { $0.start }, [0, 480, 960, 1440])
    }

    // MARK: - Post-processing

    func testOverlapTrimming() throws {
        let w = try write("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":40,\"len\":4},{\"pos\":\"1.1.3\",\"pitch\":40}]}")
        XCTAssertEqual(w.clip.notes.map { $0.duration }, [240, 120])
        XCTAssertEqual(w.warnings.count, 1)
        XCTAssertTrue(w.warnings[0].contains("1 overlapping"))
    }

    func testDuplicateMerge() throws {
        let w = try write("""
        {"notes":[{"pos":"1.1.1","pitch":40,"vel":80,"len":1},{"pos":"1.1.1","pitch":40,"vel":100,"len":2}]}
        """)
        XCTAssertEqual(w.clip.notes.count, 1)
        XCTAssertEqual(w.clip.notes[0].velocity, 100)
        XCTAssertEqual(w.clip.notes[0].duration, 240)
        XCTAssertTrue(w.warnings.isEmpty)
    }

    func testDropAndTruncateWarnings() throws {
        let w = try write("""
        {"bars":1,"notes":[
          {"pos":"1.1.1","pitch":40,"len":"2bars"},
          {"pos":"1.4.1","pitch":41,"len":"1/2"},
          {"pos":"2.1.1","pitch":42},{"pos":"3.1.1","pitch":43}]}
        """)
        XCTAssertEqual(w.clip.notes.count, 2)
        XCTAssertEqual(w.clip.notes[0].duration, 1920)
        XCTAssertEqual(w.warnings.count, 2)
        XCTAssertTrue(w.warnings.contains { $0.hasPrefix("2 note(s) started at or after the clip end") })
        XCTAssertTrue(w.warnings.contains { $0.hasPrefix("2 note(s) ran past the clip end") })
    }

    // MARK: - Errors

    func testErrorMessages() {
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60},{\"pos\":\"1.1.1\",\"pitch\":60},{\"pos\":\"1.1.1\",\"pitch\":60},{\"pos\":\"1.1.1\",\"pitch\":\"H2\"}]}"),
                       "notes[3]: unknown pitch 'H2'")
        XCTAssertEqual(errorMessage("{\"chords\":[{\"pos\":\"1.5.1\",\"chord\":\"Fm\"}]}"),
                       "chords[0]: pos '1.5.1' is invalid (beat must be 1-4)")
        XCTAssertEqual(errorMessage("{\"steps\":{\"kick\":\"x..q\"}}"),
                       "steps.kick: invalid character 'q' in pattern")
        XCTAssertEqual(errorMessage("{\"bars\":300,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}]}"),
                       "bars must be between 1 and 256")
        XCTAssertEqual(errorMessage("{\"bars\":true,\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60}]}"),
                       "bars must be between 1 and 256")
        XCTAssertEqual(errorMessage("{\"chords\":[{\"pos\":\"1.1.1\",\"chord\":\"Xyz\"}]}"),
                       "chords[0]: unknown chord symbol 'Xyz'")
        XCTAssertEqual(errorMessage("{\"chords\":[{\"pos\":\"1.1.1\",\"chord\":\"Fm13b2\"}]}"),
                       "chords[0]: unknown chord symbol 'Fm13b2'")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"0.1.1\",\"pitch\":60}]}"),
                       "notes[0]: pos '0.1.1' is invalid (bar must be 1 or more)")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.5\",\"pitch\":60}]}"),
                       "notes[0]: pos '1.1.5' is invalid (sixteenth must be 1-4)")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1.120\",\"pitch\":60}]}"),
                       "notes[0]: pos '1.1.1.120' is invalid (tick offset must be 0-119)")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"step\":1,\"pitch\":60}]}"),
                       "notes[0]: give either pos or step, not both")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pitch\":60}]}"),
                       "notes[0]: one of pos or step is required")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\"}]}"), "notes[0]: pitch is required")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":60,\"vel\":0}]}"),
                       "notes[0]: vel must be between 1 and 127")
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":128}]}"),
                       "notes[0]: unknown pitch '128' (MIDI numbers are 0-127)")
        XCTAssertEqual(errorMessage("{\"steps\":{\"kick\":\"\"}}"), "steps.kick: pattern is empty")
        XCTAssertEqual(errorMessage("{\"steps\":{\"bongo\":\"x\"}}"),
                       "steps.bongo: unknown lane 'bongo' (use a drum name, a note name or a MIDI number)")
        XCTAssertEqual(errorMessage("{\"grid\":10,\"steps\":{\"kick\":\"x\"}}"),
                       "grid must be one of 4, 8, 12, 16, 24, 32, 48")
        XCTAssertEqual(errorMessage("{\"transpose\":60,\"steps\":{\"kick\":\"x\"}}"),
                       "transpose must be between -48 and 48")
        XCTAssertEqual(errorMessage("{\"swing\":2,\"steps\":{\"kick\":\"x\"}}"),
                       "swing must be between 0 and 1")
        XCTAssertEqual(errorMessage("{\"pattern_bars\":1,\"notes\":[{\"pos\":\"2.1.1\",\"pitch\":60}]}"),
                       "notes[0]: position is beyond pattern_bars (1 bars)")
        XCTAssertEqual(errorMessage("{\"chords\":[{\"pos\":\"1.1.1\"}]}"),
                       "chords[0]: either chord or pitches is required")
        XCTAssertEqual(errorMessage("{}"), "the spec produced no notes (give at least one of notes, chords, steps)")
        XCTAssertEqual(errorMessage("[]"), "the spec must be a JSON object")
        XCTAssertTrue(errorMessage("{nope").hasPrefix("invalid JSON"))
        XCTAssertEqual(errorMessage("{\"bars\":1,\"notes\":[{\"pos\":\"3.1.1\",\"pitch\":60}]}"),
                       "no notes remain inside the clip (1 bars)")
    }

    func testJSONNumbersAreNotBooleans() throws {
        XCTAssertEqual(try notes("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":1,\"vel\":1}]}")[0].pitch, 1)
        XCTAssertEqual(try notes("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":0,\"vel\":1}]}")[0].pitch, 0)
        XCTAssertEqual(errorMessage("{\"notes\":[{\"pos\":\"1.1.1\",\"pitch\":true}]}"),
                       "notes[0]: pitch must be a MIDI number, a note name or a drum name")
    }

    func testLimits() {
        let many = (0..<4001).map { _ in "{\"pos\":\"1.1.1\",\"pitch\":60}" }.joined(separator: ",")
        XCTAssertEqual(errorMessage("{\"notes\":[\(many)]}"), "notes has 4001 entries (max 4000)")
        XCTAssertTrue(errorMessage("{\"bars\":256,\"grid\":48,\"steps\":{\"kick\":\"x\",\"snare\":\"x\"}}")
            .hasPrefix("too many notes"))
        let lanes = (0..<65).map { "\"\($0)\":\"x\"" }.joined(separator: ",")
        XCTAssertEqual(errorMessage("{\"steps\":{\(lanes)}}"), "steps has 65 lanes (max 64)")
    }

    // MARK: - Round trip and musical fixture

    func testMIDIRoundTrip() throws {
        let w = try write("""
        {"name":"Round trip","channel":3,"bars":2,"swing":0.3,"humanize":0.4,
         "chords":[{"pos":"1.1.1","chord":"Fm9","voicing":"dub","len":"1/8.","vel":80}],
         "steps":{"kick":"x...x...x...x...","hh":"..x...x...x...x."}}
        """, seed: 42)
        let data = MIDIFileIO.write(clip: w.clip)
        let back = try MIDIFileIO.read(data)
        XCTAssertEqual(back.clips.count, 1)
        XCTAssertEqual(back.clips[0].notes, w.clip.notes)
        XCTAssertEqual(back.clips[0].lengthTicks, w.clip.lengthTicks)
    }

    func testDubTechnoFixtureAnalyzesAsFMinor() throws {
        // Fm9 stabs in the dub voicing, doubled with the root one octave down (slash bass F),
        // on dotted-eighth positions. Without the bass root the bare Fm9 colour is ambiguous
        // with C minor for the key analyzer.
        let chords = """
        "chords":[
           {"pos":"1.1.1","chord":"Fm9/F","voicing":"dub","len":"1/16","vel":84},
           {"pos":"1.1.4","chord":"Fm9/F","voicing":"dub","len":"1/16","vel":70},
           {"pos":"1.2.3","chord":"Fm9/F","voicing":"dub","len":"1/16","vel":78},
           {"pos":"1.3.2","chord":"Fm9/F","voicing":"dub","len":"1/16","vel":64}]
        """
        let full = try write("""
        {"name":"Dub stabs","pattern_bars":1,"bars":4,"grid":16,\(chords),
         "steps":{"kick":"x...x...x...x...","hh":"..x...x...x...x."}}
        """)
        XCTAssertEqual(full.clip.lengthTicks, 4 * 1920)
        XCTAssertEqual(full.clip.notes.filter { $0.pitch == 36 }.count, 16)
        XCTAssertEqual(full.clip.notes.filter { $0.pitch == 42 }.count, 16)
        XCTAssertEqual(full.clip.notes.count, 16 + 16 + 4 * 4 * 6)

        let stabs = try write("{\"pattern_bars\":1,\"bars\":4,\(chords)}").clip
        XCTAssertEqual(stabs.notes.count, 96)
        XCTAssertEqual(Set(stabs.notes.filter { $0.start == 0 }.map { $0.pitch }), [41, 53, 60, 63, 67, 68])
        let analysis = Analyzer.analyze([stabs])
        XCTAssertEqual(analysis.tonic, 5)
        XCTAssertTrue(analysis.isMinor)
    }
}
