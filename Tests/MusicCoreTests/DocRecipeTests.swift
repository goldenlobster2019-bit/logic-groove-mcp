import XCTest
@testable import MusicCore

/// The ready-to-send recipes from docs/SKILL.md and the README must stay valid.
final class DocRecipeTests: XCTestCase {

    private let r1 = #"""
{"name": "Dub stab Fm9", "pattern_bars": 2, "bars": 8, "humanize": 0.15, "chords": [{"pos": "1.1.1", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 88}, {"pos": "1.1.4", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 64}, {"pos": "1.2.3", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 76}, {"pos": "2.1.4", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 70}, {"pos": "2.2.3", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 58}]}
"""#

    private let r2 = #"""
{"name": "Dub sub F", "bars": 8, "steps": {"F1": {"pattern": "..x...x...x...x.", "vel": 100, "len": "1/16"}}}
"""#

    private let r3 = #"""
{"name": "Dub drums minimal", "bars": 8, "humanize": 0.1, "steps": {"kick": {"pattern": "x...x...x...x...", "vel": 88}, "hh": {"pattern": "..x...x...x...x.", "vel": 70}, "shaker": "gggogggogggogggo", "rim": "........................x......."}}
"""#

    private let r4 = #"""
{"name": "Deep house i9 - iv9", "pattern_bars": 4, "bars": 8, "swing": 0.2, "humanize": 0.1, "chords": [{"pos": "1.1.1", "chord": "Am9", "octave": 2, "voicing": "spread", "len": "1/1", "vel": 72, "vel_top": 80}, {"pos": "2.1.1", "chord": "Dm9", "octave": 2, "voicing": "spread", "len": "1/1", "vel": 72, "vel_top": 80}, {"pos": "3.1.1", "chord": "Am9", "octave": 2, "voicing": "spread", "len": "1/1", "vel": 72, "vel_top": 80}, {"pos": "4.1.1", "chord": "Dm9", "octave": 2, "voicing": "spread", "len": "1/1", "vel": 72, "vel_top": 80}], "notes": [{"pos": "1.1.1", "pitch": "A1", "len": "1/8", "vel": 100}, {"pos": "1.2.3", "pitch": "A1", "len": "1/16", "vel": 80}, {"pos": "1.3.2", "pitch": "E2", "len": "1/16", "vel": 70}, {"pos": "1.4.3", "pitch": "A1", "len": "1/8", "vel": 90}, {"pos": "2.1.1", "pitch": "D1", "len": "1/8", "vel": 100}, {"pos": "2.2.3", "pitch": "D1", "len": "1/16", "vel": 80}, {"pos": "2.3.2", "pitch": "A1", "len": "1/16", "vel": 70}, {"pos": "2.4.3", "pitch": "D1", "len": "1/8", "vel": 90}, {"pos": "3.1.1", "pitch": "A1", "len": "1/8", "vel": 100}, {"pos": "3.2.3", "pitch": "A1", "len": "1/16", "vel": 80}, {"pos": "3.3.2", "pitch": "E2", "len": "1/16", "vel": 70}, {"pos": "3.4.3", "pitch": "A1", "len": "1/8", "vel": 90}, {"pos": "4.1.1", "pitch": "D1", "len": "1/8", "vel": 100}, {"pos": "4.2.3", "pitch": "D1", "len": "1/16", "vel": 80}, {"pos": "4.3.2", "pitch": "A1", "len": "1/16", "vel": 70}, {"pos": "4.4.3", "pitch": "D1", "len": "1/8", "vel": 90}]}
"""#

    private let r5 = #"""
{"name": "House drums and organ stab", "pattern_bars": 1, "bars": 4, "humanize": 0.1, "chords": [{"step": 3, "chord": "Am7", "octave": 3, "len": "1/16", "vel": 98}, {"step": 6, "chord": "Am7", "octave": 3, "len": "1/16", "vel": 84}, {"step": 10, "chord": "Am7", "octave": 3, "len": "1/16", "vel": 92}], "steps": {"kick": "x...x...x...x...", "clap": "....x.......x...", "oh": "..x...x...x...x.", "hh": ".g.g.g.g.g.g.g.g"}}
"""#

    private let readme1 = #"""
{"name": "Dub techno stab and drums", "pattern_bars": 2, "bars": 8, "humanize": 0.15, "chords": [{"pos": "1.1.1", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 88}, {"pos": "1.1.4", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 64}, {"pos": "1.2.3", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 76}, {"pos": "2.1.4", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 70}, {"pos": "2.2.3", "chord": "Fm9", "voicing": "dub", "len": "1/16", "vel": 58}], "steps": {"kick": {"pattern": "x...x...x...x...", "vel": 88}, "hh": {"pattern": "..x...x...x...x.", "vel": 70}}}
"""#

    func testRecipesParseWithoutWarnings() throws {
        for (name, spec) in [("r1", r1), ("r2", r2), ("r3", r3), ("r4", r4), ("r5", r5), ("readme1", readme1)] {
            let w = try ClipWriter.write(json: Data(spec.utf8), seed: 3)
            XCTAssertFalse(w.clip.notes.isEmpty, name)
            XCTAssertTrue(w.warnings.isEmpty, "\(name): \(w.warnings)")
        }
    }

    func testRecipeShapes() throws {
        let stab = try ClipWriter.write(json: Data(r1.utf8), seed: 3).clip
        XCTAssertEqual(stab.lengthTicks, 8 * 1920)
        XCTAssertEqual(stab.notes.count, 5 * 5 * 4)
        let progression = try ClipWriter.write(json: Data(r4.utf8), seed: 3).clip
        XCTAssertEqual(progression.lengthTicks, 8 * 1920)
        let key = Analyzer.analyze(progression)
        XCTAssertEqual(key.tonic, 9)
        XCTAssertTrue(key.isMinor)
        let house = try ClipWriter.write(json: Data(r5.utf8), seed: 3).clip
        XCTAssertEqual(house.notes.filter { $0.pitch == 39 }.count, 8)
    }
}
