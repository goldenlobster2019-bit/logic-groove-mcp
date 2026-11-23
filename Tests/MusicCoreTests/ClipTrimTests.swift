import XCTest
@testable import MusicCore

final class ClipTrimTests: XCTestCase {
    let bar = MusicCore.ticksPerBar()

    func note(_ start: Int, _ pitch: Int = 60) -> NoteEvent {
        NoteEvent(start: start, duration: 120, pitch: pitch, velocity: 100)
    }

    func testLeadingEmptyBars() {
        XCTAssertEqual(Clip(name: "a", notes: [note(bar * 2 + 10)], lengthTicks: bar * 4).leadingEmptyBars, 2)
        XCTAssertEqual(Clip(name: "a", notes: [note(0)], lengthTicks: bar).leadingEmptyBars, 0)
        XCTAssertEqual(Clip(name: "a", notes: [], lengthTicks: bar).leadingEmptyBars, 0)
    }

    func testTrimShiftsNotesAndLength() {
        let clip = Clip(name: "a", notes: [note(bar * 8), note(bar * 8 + 240, 64)], lengthTicks: bar * 10, program: 5)
        let (t, bars) = clip.trimmingLeadingEmptyBars()
        XCTAssertEqual(bars, 8)
        XCTAssertEqual(t.notes.map { $0.start }, [0, 240])
        XCTAssertEqual(t.lengthTicks, bar * 2)
        XCTAssertEqual(t.program, 5)
    }

    func testLengthNeverBelowOneBar() {
        let clip = Clip(name: "a", notes: [note(bar * 3)], lengthTicks: bar * 3)
        XCTAssertEqual(clip.trimmingLeadingEmptyBars().clip.lengthTicks, bar)
    }

    func testControlsCollapse() {
        let shift = bar * 2
        let controls = [
            ControlEvent(tick: 0, controller: 1, value: 10),
            ControlEvent(tick: 100, controller: 1, value: 20),
            ControlEvent(tick: 50, controller: 74, value: 5),
            ControlEvent(tick: shift, controller: 74, value: 99),
            ControlEvent(tick: shift + 240, controller: 1, value: 30),
        ]
        let clip = Clip(name: "a", notes: [note(shift)], lengthTicks: bar * 4, controls: controls)
        let t = clip.trimmingLeadingEmptyBars().clip
        // cc1: last before shift (20) placed at 0; cc74: event exactly at boundary wins, earlier dropped.
        XCTAssertEqual(t.controls, [
            ControlEvent(tick: 0, controller: 1, value: 20),
            ControlEvent(tick: 0, controller: 74, value: 99),
            ControlEvent(tick: 240, controller: 1, value: 30),
        ])
    }

    func testNoOpAndNoNotes() {
        let clip = Clip(name: "a", notes: [note(10)], lengthTicks: bar, controls: [ControlEvent(tick: 5, controller: 1, value: 1)])
        let r = clip.trimmingLeadingEmptyBars()
        XCTAssertEqual(r.leadingBars, 0)
        XCTAssertEqual(r.clip, clip)
        let empty = Clip(name: "e", notes: [], lengthTicks: bar * 4)
        XCTAssertEqual(empty.trimmingLeadingEmptyBars().leadingBars, 0)
        XCTAssertEqual(empty.trimmingLeadingEmptyBars().clip, empty)
    }

    func testMIDIFileContentsLeadingBarsRoundTrip() throws {
        let late = Clip(name: "late", notes: [note(bar * 8)], lengthTicks: bar * 10)
        let later = Clip(name: "later", notes: [note(bar * 9)], lengthTicks: bar * 10)
        let data = MIDIFileIO.write(clips: [late, later])
        let contents = try MIDIFileIO.read(data)
        XCTAssertEqual(contents.leadingEmptyBars, 8)
        let none = MIDIFileContents(clips: [Clip(name: "e", notes: [], lengthTicks: bar)])
        XCTAssertEqual(none.leadingEmptyBars, 0)
        let early = Clip(name: "early", notes: [note(0)], lengthTicks: bar)
        XCTAssertEqual(MIDIFileContents(clips: [late, early]).leadingEmptyBars, 0)
    }
}
