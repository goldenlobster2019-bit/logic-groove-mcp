import XCTest
@testable import MusicCore

final class GeneratorTests: XCTestCase {
    private let drumParts: Set<Part> = [.drums, .kick, .hats]

    private func allCombos() -> [(Genre, Part, String)] {
        var out: [(Genre, Part, String)] = []
        for g in Genre.allCases {
            for p in Part.allCases {
                for s in Generator.styles(genre: g, part: p) { out.append((g, p, s.name)) }
            }
        }
        return out
    }

    private func req(_ g: Genre, _ p: Part, style: String? = nil, key: String? = nil, scale: String? = nil,
                     bars: Int = 4, density: Double = 0.5, swing: Double = 0, humanize: Double = 0.2,
                     octave: Int? = nil, seed: UInt64 = 1) -> GenerationRequest {
        GenerationRequest(genre: g, part: p, key: key, scale: scale, bars: bars, style: style, density: density,
                          swing: swing, humanize: humanize, octave: octave, seed: seed)
    }

    private func analysis(tonic: Int = 5, minor: Bool = true, steps: [Int], chords: [DetectedChord] = []) -> ClipAnalysis {
        ClipAnalysis(keyName: "F minor", tonic: tonic, isMinor: minor, keyConfidence: 0.9, chords: chords,
                     onsetHistogram16: (0..<16).map { steps.contains($0) ? 4 : 0 }, mainOnsetSteps: steps,
                     lowestPitch: 53, highestPitch: 68, noteCount: 16, lengthBars: 4)
    }

    /// Nearest 16th step within the bar (robust against humanize jitter and swing).
    private func step(_ tick: Int) -> Int { ((tick % 1920) + 60) / 120 }

    // MARK: determinism

    func testDeterminismAndSeedSensitivity() {
        for (g, p, s) in allCombos() {
            let r1 = req(g, p, style: s, density: 0.6, humanize: 0.5, seed: 42)
            XCTAssertEqual(Generator.generate(r1), Generator.generate(r1), "\(g) \(p) \(s) not deterministic")
            let r2 = req(g, p, style: s, density: 0.6, humanize: 0.5, seed: 43)
            XCTAssertNotEqual(Generator.generate(r1).notes, Generator.generate(r2).notes, "\(g) \(p) \(s) ignores seed")
        }
    }

    // MARK: validity

    func testEveryStyleProducesValidMaterial() {
        for (g, p, s) in allCombos() {
            for density in [0.0, 0.5, 1.0] {
                for bars in [1, 4, 7] {
                    let r = req(g, p, style: s, bars: bars, density: density, swing: 0.5, humanize: 1.0, seed: 7)
                    let clip = Generator.generate(r)
                    let tag = "\(g) \(p) \(s) d=\(density) bars=\(bars)"
                    XCTAssertEqual(clip.lengthTicks, bars * 1920, tag)
                    XCTAssertFalse(clip.notes.isEmpty, tag)
                    let d = Generator.resolvedDefaults(r)
                    let scale = Scale.named(d.scale)!
                    let pcs = Set(scale.pitchClasses(tonic: NoteName.pitchClass(d.key)!))
                    for n in clip.notes {
                        XCTAssertTrue((0...127).contains(n.pitch), tag)
                        XCTAssertTrue((1...127).contains(n.velocity), tag)
                        XCTAssertGreaterThanOrEqual(n.start, 0, tag)
                        XCTAssertGreaterThan(n.duration, 0, tag)
                        XCTAssertLessThanOrEqual(n.end, clip.lengthTicks, tag)
                        if !drumParts.contains(p) {
                            XCTAssertTrue(pcs.contains(n.pitch % 12), "\(tag) out of scale: \(NoteName.name(n.pitch))")
                        }
                        if p == .bass { XCTAssertLessThan(n.pitch, 60, tag) }
                    }
                }
            }
        }
    }

    func testDensityChangesEventCount() {
        for (g, p, s) in allCombos() where s != "follow" {
            let lo = Generator.generate(req(g, p, style: s, bars: 8, density: 0, humanize: 0)).notes.count
            let hi = Generator.generate(req(g, p, style: s, bars: 8, density: 1, humanize: 0)).notes.count
            XCTAssertGreaterThan(hi, lo, "\(g) \(p) \(s): density 0 -> \(lo), density 1 -> \(hi)")
        }
    }

    // MARK: dub techno bass

    func testDubBassOffbeatInFMinor() {
        let c0 = Generator.generate(req(.dubTechno, .bass, style: "offbeat", key: "F", scale: "minor", bars: 4, density: 0, humanize: 0))
        XCTAssertTrue(c0.notes.allSatisfy { $0.pitch == 41 })
        XCTAssertEqual(c0.notes.filter { $0.start < 1920 }.map(\.start), [240, 720, 1200, 1680])
        XCTAssertEqual(c0.notes.count, 16)

        for seed in 1...5 as ClosedRange<UInt64> {
            let c1 = Generator.generate(req(.dubTechno, .bass, style: "offbeat", key: "F", scale: "minor", density: 1, seed: seed))
            XCTAssertTrue(c1.notes.allSatisfy { [5, 0, 3].contains($0.pitch % 12) })
        }
        XCTAssertEqual(Generator.resolvedDefaults(req(.dubTechno, .bass)).octave, 1)
    }

    func testResolvedDefaultsAndFallbacks() {
        let d = Generator.resolvedDefaults(req(.dubTechno, .bass))
        XCTAssertEqual(d.key, "F"); XCTAssertEqual(d.scale, "minor"); XCTAssertEqual(d.octave, 1); XCTAssertEqual(d.style, "offbeat")
        let h = Generator.resolvedDefaults(req(.house, .bass))
        XCTAssertEqual(h.key, "A"); XCTAssertEqual(h.scale, "dorian"); XCTAssertEqual(h.style, "deep_groove")
        XCTAssertEqual(Generator.resolvedDefaults(req(.deepHouse, .stabs)).scale, "minor")
        XCTAssertEqual(Generator.resolvedDefaults(req(.dubTechno, .stabs)).octave, 2)

        let bad = Generator.generate(req(.dubTechno, .bass, style: "nonsense", key: "H#", scale: "klingon", bars: 0))
        let def = Generator.generate(req(.dubTechno, .bass, bars: 1))
        XCTAssertEqual(bad, def)
        XCTAssertEqual(bad.name, "Dub Techno Bass – F minor – offbeat")
        XCTAssertEqual(Generator.generate(req(.dubTechno, .bass, bars: 500)).lengthTicks, 64 * 1920)
        XCTAssertEqual(Generator.generate(req(.house, .drums, key: "Bb", scale: "dorian")).name, "House Drums – Bb dorian – classic")
        // Style aliases / odd casing
        XCTAssertEqual(Generator.resolvedDefaults(req(.dubTechno, .bass, style: "Monotone")).style, "monotone_pulse")
        // NaN inputs never crash
        _ = Generator.generate(req(.house, .stabs, density: .nan, swing: .nan, humanize: .nan))
    }

    func testStyleCatalogue() {
        for g in Genre.allCases {
            for p in Part.allCases {
                let styles = Generator.styles(genre: g, part: p)
                XCTAssertFalse(styles.isEmpty)
                XCTAssertEqual(Set(styles.map(\.name)).count, styles.count)
            }
        }
        XCTAssertEqual(Generator.styles(genre: .dubTechno, part: .bass).map(\.name),
                       ["offbeat", "monotone_pulse", "sustain", "rolling", "follow"])
        XCTAssertEqual(Generator.styles(genre: .dubTechno, part: .stabs).map(\.name), ["dub_chord", "offbeat", "dotted", "polymeter"])
        XCTAssertEqual(Generator.styles(genre: .house, part: .drums).map(\.name), ["classic", "deep", "garage"])
        XCTAssertEqual(Generator.styles(genre: .deepHouse, part: .bass).first?.name, "deep_groove")
    }

    // MARK: house drums

    func testHouseClassicDrums() {
        for humanize in [0.0, 1.0] {
            let clip = Generator.generate(req(.house, .drums, style: "classic", humanize: humanize))
            let bar1 = clip.notes.filter { $0.start < 1920 }
            XCTAssertEqual(bar1.filter { $0.pitch == DrumNote.kick }.map(\.start), [0, 480, 960, 1440])
            XCTAssertEqual(bar1.filter { $0.pitch == DrumNote.clap }.map(\.start), [480, 1440])
            XCTAssertTrue(bar1.contains { $0.pitch == DrumNote.openHat })
            XCTAssertTrue(bar1.contains { $0.pitch == DrumNote.closedHat })
        }
    }

    func testKicksStayOnGridWithFullHumanize() {
        for (g, p, s) in allCombos() where p == .kick || p == .drums {
            let clip = Generator.generate(req(g, p, style: s, bars: 4, density: 0.5, humanize: 1.0, seed: 9))
            let beats = clip.notes.filter { $0.pitch == DrumNote.kick && $0.start % 480 <= 4 }
            XCTAssertTrue(beats.allSatisfy { $0.start % 480 == 0 }, "\(g) \(p) \(s)")
            XCTAssertEqual(Set(beats.map(\.start)).count, 16)
        }
    }

    // MARK: groove

    func testSwingDelaysOddSixteenthsAndHumanizeIsBounded() {
        let straight = Generator.generate(req(.house, .hats, style: "sixteenths", density: 1, swing: 0, humanize: 0))
        let swung = Generator.generate(req(.house, .hats, style: "sixteenths", density: 1, swing: 1, humanize: 0))
        XCTAssertEqual(straight.notes.count, swung.notes.count)
        for n in swung.notes {
            let off = n.start % 240
            XCTAssertTrue(off == 0 || off == 120 + 48, "unexpected offset \(off)")
        }
        XCTAssertTrue(swung.notes.contains { $0.start % 240 == 168 })

        // humanize: timing within +-8 ticks, velocity within +-12 of the clean version
        let clean = Generator.generate(req(.dubTechno, .stabs, style: "dub_chord", density: 0.5, humanize: 0))
        let human = Generator.generate(req(.dubTechno, .stabs, style: "dub_chord", density: 0.5, humanize: 1))
        XCTAssertEqual(clean.notes.count, human.notes.count)
        for n in human.notes {
            XCTAssertTrue(clean.notes.contains { abs($0.start - n.start) <= 8 && $0.pitch == n.pitch && abs($0.velocity - n.velocity) <= 12 })
        }
    }

    // MARK: complement

    func testComplementBassAvoidsStabOnsetsAndKeepsRoot() {
        let a = analysis(tonic: 5, steps: [2, 6, 10, 14])
        for style in ["offbeat", "monotone_pulse", "rolling", "sustain"] {
            let clip = Generator.complement(a, request: req(.dubTechno, .bass, style: style, density: 0.5, seed: 3))
            XCTAssertFalse(clip.notes.isEmpty, style)
            XCTAssertTrue(clip.notes.allSatisfy { [5, 0, 3].contains($0.pitch % 12) }, style)
            XCTAssertTrue(clip.notes.filter { $0.pitch % 12 == 5 }.count > 0)
            XCTAssertTrue(clip.notes.allSatisfy { ![2, 6, 10, 14].contains(step($0.start)) }, "\(style) lands on stab onset")
        }
        let off = Generator.complement(a, request: req(.dubTechno, .bass, style: "offbeat", density: 0, humanize: 0))
        XCTAssertTrue(off.notes.allSatisfy { $0.pitch == 41 })
        XCTAssertEqual(off.notes.filter { $0.start < 1920 }.map(\.start), [360, 840, 1320, 1800])
    }

    func testComplementFollowLandsOnStabSteps() {
        let a = analysis(tonic: 5, steps: [2, 6, 10, 14])
        let clip = Generator.complement(a, request: req(.dubTechno, .bass, style: "follow", density: 0, humanize: 0))
        XCTAssertEqual(clip.notes.filter { $0.start < 1920 }.map(\.start), [240, 720, 1200, 1680])
        XCTAssertTrue(clip.notes.allSatisfy { $0.pitch == 41 })
        // Uses the analysis key, with the request key overriding it
        let g = Generator.complement(analysis(tonic: 7, steps: [3, 6, 11]), request: req(.dubTechno, .bass, style: "follow", density: 0, humanize: 0))
        XCTAssertTrue(g.notes.allSatisfy { $0.pitch % 12 == 7 })
        XCTAssertEqual(g.notes.filter { $0.start < 1920 }.map(\.start), [360, 720, 1320])
        let o = Generator.complement(analysis(tonic: 7, steps: [3]), request: req(.dubTechno, .bass, style: "follow", key: "D", density: 0, humanize: 0))
        XCTAssertTrue(o.notes.allSatisfy { $0.pitch % 12 == 2 })
    }

    func testComplementUsesAnalysedChord() {
        let chord = DetectedChord(name: "Gm7", root: 7, pitches: [55, 62, 65, 70], occurrences: 4)
        let a = analysis(tonic: 7, steps: [3, 6, 11], chords: [chord])
        let clip = Generator.complement(a, request: req(.dubTechno, .stabs, style: "dub_chord", density: 0.5, humanize: 0))
        let pcs = Set(clip.notes.map { $0.pitch % 12 })
        XCTAssertEqual(pcs, [7, 2, 5, 10])
        let house = Generator.complement(a, request: req(.house, .chords, density: 0.2, humanize: 0))
        XCTAssertFalse(house.notes.isEmpty)
        XCTAssertEqual(Set(house.notes.map { $0.pitch % 12 }), [7, 10, 2, 5])
    }
}
