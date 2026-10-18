import XCTest
@testable import MusicCore

final class AnalyzerTests: XCTestCase {

    func testRepeatedFmTriadOffbeats() {
        // F2 Ab2 C3 (Logic numbering: C3 = 60) on every eighth-note offbeat for 4 bars.
        var notes = [NoteEvent]()
        for beat in 0..<16 {
            for p in [53, 56, 60] {
                notes.append(NoteEvent(start: beat * 480 + 240, duration: 120, pitch: p, velocity: 90))
            }
        }
        let a = Analyzer.analyze(Clip(name: "Fm", notes: notes, lengthTicks: 4 * 1920))
        XCTAssertEqual(a.keyName, "F minor")
        XCTAssertEqual(a.tonic, 5)
        XCTAssertTrue(a.isMinor)
        XCTAssertEqual(a.chords.first?.name, "Fm")
        XCTAssertEqual(a.chords.first?.occurrences, 16)
        XCTAssertEqual(a.chords.first?.pitches, [53, 56, 60])
        XCTAssertEqual(a.mainOnsetSteps, [2, 6, 10, 14])
        XCTAssertEqual(a.onsetHistogram16[2], 4)
        XCTAssertEqual(a.lowestPitch, 53)
        XCTAssertEqual(a.highestPitch, 60)
        XCTAssertEqual(a.noteCount, 48)
        XCTAssertEqual(a.lengthBars, 4)
    }

    func testFm7StabsIsFMinor() {
        var notes = [NoteEvent]()
        for bar in 0..<4 {
            for p in [53, 56, 60, 63] { notes.append(NoteEvent(start: bar * 1920 + 240, duration: 240, pitch: p)) }
        }
        let a = Analyzer.analyze(Clip(name: "Fm7", notes: notes, lengthTicks: 4 * 1920))
        XCTAssertEqual(a.keyName, "F minor")
        XCTAssertEqual(a.chords.first?.name, "Fm7")
    }

    func testAMinorScaleRun() {
        let pitches = [57, 59, 60, 62, 64, 65, 67, 69]   // A2 ... A3
        let notes = pitches.enumerated().map { NoteEvent(start: $0.offset * 240, duration: 240, pitch: $0.element) }
        let a = Analyzer.analyze(Clip(name: "Run", notes: notes, lengthTicks: 1920))
        XCTAssertEqual(a.keyName, "A minor")
        XCTAssertTrue(a.chords.isEmpty)
        XCTAssertEqual(a.keyConfidence, 0.7, accuracy: 0.3)
    }

    func testCMajorProgression() {
        // C - F - G - C, whole-note triads with bass.
        let chords: [[Int]] = [[36, 60, 64, 67], [41, 60, 65, 69], [43, 62, 67, 71], [36, 60, 64, 67]]
        var notes = [NoteEvent]()
        for (i, c) in chords.enumerated() {
            for p in c { notes.append(NoteEvent(start: i * 1920, duration: 1920, pitch: p)) }
        }
        let a = Analyzer.analyze(Clip(name: "Prog", notes: notes, lengthTicks: 4 * 1920))
        XCTAssertEqual(a.keyName, "C major")
        XCTAssertFalse(a.isMinor)
        XCTAssertEqual(a.chords.first?.name, "C")
        XCTAssertEqual(a.chords.first?.occurrences, 2)
        XCTAssertEqual(Set(a.chords.map { $0.name }), ["C", "F", "G"])
        XCTAssertEqual(a.mainOnsetSteps, [0])
    }

    func testEmptyClip() {
        let a = Analyzer.analyze(Clip(name: "Empty", notes: [], lengthTicks: 1920))
        XCTAssertEqual(a.keyName, "C minor")
        XCTAssertEqual(a.keyConfidence, 0)
        XCTAssertTrue(a.chords.isEmpty)
        XCTAssertEqual(a.onsetHistogram16, [Int](repeating: 0, count: 16))
        XCTAssertTrue(a.mainOnsetSteps.isEmpty)
        XCTAssertEqual(a.noteCount, 0)
        XCTAssertEqual(a.lengthBars, 1)
        XCTAssertEqual(Analyzer.analyze([Clip]()).noteCount, 0)
    }

    func testMergedClips() {
        let a = Clip(name: "a", notes: [NoteEvent(start: 0, duration: 480, pitch: 53)], lengthTicks: 1920)
        let b = Clip(name: "b", notes: [NoteEvent(start: 0, duration: 480, pitch: 56), NoteEvent(start: 0, duration: 480, pitch: 60)], lengthTicks: 3840)
        let r = Analyzer.analyze([a, b])
        XCTAssertEqual(r.noteCount, 3)
        XCTAssertEqual(r.chords.first?.name, "Fm")
        XCTAssertEqual(r.lengthBars, 2)
    }

    func testNonExactChordFallsBackToJaccard() {
        // F + Ab + Eb + G: no exact quality match; must still produce a named chord rooted on the lowest note.
        let notes = [53, 56, 63, 55].map { NoteEvent(start: 0, duration: 480, pitch: $0) }
        let a = Analyzer.analyze(Clip(name: "x", notes: notes, lengthTicks: 1920))
        XCTAssertEqual(a.chords.count, 1)
        XCTAssertFalse(a.chords[0].name.isEmpty)
    }
}
