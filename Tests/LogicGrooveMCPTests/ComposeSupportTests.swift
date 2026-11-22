import Foundation
import XCTest
@testable import LogicGrooveMCP

final class ComposeSupportTests: XCTestCase {
    func testSanitizeFileName() {
        XCTAssertEqual(ComposeSupport.sanitizeFileName("Dub Stabs 01"), "Dub-Stabs-01")
        XCTAssertEqual(ComposeSupport.sanitizeFileName("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(ComposeSupport.sanitizeFileName("a/b\\c:d*e?"), "abcde")
        XCTAssertEqual(ComposeSupport.sanitizeFileName("!!!", fallback: "clip"), "clip")
        XCTAssertEqual(ComposeSupport.sanitizeFileName("keep_this-name"), "keep_this-name")
        XCTAssertLessThanOrEqual(ComposeSupport.sanitizeFileName(String(repeating: "a", count: 200)).count, 60)
    }

    func testPathsEqual() {
        let home = NSHomeDirectory()
        XCTAssertTrue(ComposeSupport.pathsEqual("/a/b/clip.mid", "/a/b/clip.mid"))
        XCTAssertTrue(ComposeSupport.pathsEqual("  /a/b/clip.mid\n", "/a/b/clip.mid"))
        XCTAssertTrue(ComposeSupport.pathsEqual("~/Music/x.mid", home + "/Music/x.mid"))
        XCTAssertTrue(ComposeSupport.pathsEqual("/a/b/../b//clip.mid", "/a/b/clip.mid"))
        XCTAssertFalse(ComposeSupport.pathsEqual("/a/b/clip.mid", "/a/b/clip2.mid"))
        XCTAssertFalse(ComposeSupport.pathsEqual("", ""))
        XCTAssertFalse(ComposeSupport.pathsEqual("/a", ""))
    }

    func testImportStagingURL() {
        let url = ComposeSupport.importStagingURL()
        XCTAssertEqual(url.lastPathComponent, "clip.mid")
        XCTAssertTrue(url.path.hasSuffix("Music/LogicGrooveMCP/Import/clip.mid"))
    }

    func testPositionStrings() {
        XCTAssertEqual(ComposeSupport.positionString(tick: 0), "1.1.1")
        XCTAssertEqual(ComposeSupport.positionString(tick: 240), "1.1.3")
        XCTAssertEqual(ComposeSupport.positionString(tick: 236), "1.1.3")
        XCTAssertEqual(ComposeSupport.positionString(tick: 1_915), "2.1.1")
        XCTAssertEqual(ComposeSupport.positionString(tick: 480), "1.2.1")
        XCTAssertEqual(ComposeSupport.positionString(tick: 1_920), "2.1.1")
        XCTAssertEqual(ComposeSupport.positionString(step16: 2), "1.1.3")
        XCTAssertEqual(ComposeSupport.positionString(step16: 15), "1.4.4")
        XCTAssertEqual(ComposeSupport.positionString(step16: 16), "2.1.1")
    }

    func testMenuTitleNormalization() {
        XCTAssertTrue(ComposeSupport.menuTitleEquals("MIDI File\u{2026}", "midi file..."))
        XCTAssertTrue(ComposeSupport.menuTitleEquals("MIDI File...", "MIDI File"))
        XCTAssertTrue(ComposeSupport.menuTitleHasPrefix("Selection as MIDI File\u{2026}", "Selection as MIDI File"))
        XCTAssertFalse(ComposeSupport.menuTitleEquals("Hide Editor", "Editor"))
        XCTAssertTrue(ComposeSupport.menuTitleEquals("Don\u{2019}t Import", "don't import"))
    }

    func testMIDIPathValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.MID")
        try Data([0]).write(to: file)

        if case .failure(let message) = ComposeSupport.validateMIDIPath(file.path) {
            XCTFail("Expected valid path, got: \(message)")
        }
        if case .success = ComposeSupport.validateMIDIPath("relative/clip.mid") {
            XCTFail("Relative path must be rejected")
        }
        if case .success = ComposeSupport.validateMIDIPath(root.appendingPathComponent("clip.txt").path) {
            XCTFail("Wrong extension must be rejected")
        }
        if case .success = ComposeSupport.validateMIDIPath(root.appendingPathComponent("missing.mid").path) {
            XCTFail("Missing file must be rejected")
        }
        if case .success = ComposeSupport.validateMIDIPath(root.path + "/x.mid", mustExist: true) {
            XCTFail("Nonexistent file must be rejected")
        }
        if case .failure(let message) = ComposeSupport.validateMIDIPath(
            root.appendingPathComponent("new.mid").path, mustExist: false
        ) {
            XCTFail("mustExist=false should accept: \(message)")
        }
    }

    func testParseDecibels() {
        XCTAssertEqual(ComposeSupport.parseDecibels("0,0 dB"), 0.0)
        XCTAssertEqual(ComposeSupport.parseDecibels("-7,9 dB") ?? 99, -7.9, accuracy: 0.0001)
        XCTAssertEqual(ComposeSupport.parseDecibels("3,9 dB") ?? 99, 3.9, accuracy: 0.0001)
        XCTAssertEqual(ComposeSupport.parseDecibels("-6.5 dB") ?? 99, -6.5, accuracy: 0.0001)
        XCTAssertEqual(ComposeSupport.parseDecibels("-12,0dB") ?? 99, -12.0, accuracy: 0.0001)
        XCTAssertEqual(ComposeSupport.parseDecibels("+1,5 dB") ?? 99, 1.5, accuracy: 0.0001)
        XCTAssertEqual(ComposeSupport.parseDecibels("\u{2212}2,0 dB") ?? 99, -2.0, accuracy: 0.0001)
        XCTAssertEqual(ComposeSupport.parseDecibels("-\u{221E} dB"), -Double.infinity)
        XCTAssertNil(ComposeSupport.parseDecibels(""))
        XCTAssertNil(ComposeSupport.parseDecibels("loud"))
        XCTAssertNil(ComposeSupport.parseDecibels("dB"))
    }

    func testTextAfterFirstComma() {
        XCTAssertEqual(ComposeSupport.textAfterFirstComma("volume fader level, 0,0 dB"), "0,0 dB")
        XCTAssertEqual(ComposeSupport.textAfterFirstComma("peak level meter, -7,9 dB"), "-7,9 dB")
        XCTAssertNil(ComposeSupport.textAfterFirstComma("peak level meter"))
        XCTAssertNil(ComposeSupport.textAfterFirstComma("peak level meter, "))
    }

    func testPluginNameMatches() {
        XCTAssertTrue(ComposeSupport.pluginNameMatches("Tape Delay", "tape delay"))
        XCTAssertTrue(ComposeSupport.pluginNameMatches("Tape Delay", "Tape"))
        XCTAssertTrue(ComposeSupport.pluginNameMatches("Diva", "Diva (Stereo)"))
        XCTAssertFalse(ComposeSupport.pluginNameMatches("Compressor", "Tape Delay"))
        XCTAssertFalse(ComposeSupport.pluginNameMatches("", "Diva"))
        XCTAssertFalse(ComposeSupport.pluginNameMatches("Diva", " "))
    }

    func testNonHiddenEntryCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lgmcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ComposeSupport.nonHiddenEntryCount(in: dir), 0)
        try Data().write(to: dir.appendingPathComponent("clip.mid"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(ComposeSupport.nonHiddenEntryCount(in: dir), 1)
        try Data().write(to: dir.appendingPathComponent("other.mid"))
        XCTAssertEqual(ComposeSupport.nonHiddenEntryCount(in: dir), 2)
        XCTAssertEqual(ComposeSupport.nonHiddenEntryCount(in: dir.appendingPathComponent("missing")), 0)
    }

    func testPluginSlotRequestParse() {
        XCTAssertEqual(PluginSlotRequest.parse(nil), .newEffect)
        XCTAssertEqual(PluginSlotRequest.parse(""), .newEffect)
        XCTAssertEqual(PluginSlotRequest.parse("new"), .newEffect)
        XCTAssertEqual(PluginSlotRequest.parse("Add"), .newEffect)
        XCTAssertEqual(PluginSlotRequest.parse("append"), .newEffect)
        XCTAssertEqual(PluginSlotRequest.parse("0"), .instrument)
        XCTAssertEqual(PluginSlotRequest.parse("Instrument"), .instrument)
        XCTAssertEqual(PluginSlotRequest.parse("1"), .effect(1))
        XCTAssertEqual(PluginSlotRequest.parse("3"), .effect(3))
        XCTAssertNil(PluginSlotRequest.parse("-1"))
        XCTAssertNil(PluginSlotRequest.parse("bogus"))
    }

    func testStripModelChainText() {
        var model = StripModel(
            trackName: "Stab", volumeRaw: 173, volumeText: "0,0 dB", peakText: nil, peakValue: nil, clipping: false,
            pan: 0, instrument: StripPlugin(name: "Diva", bypassed: false, y: 100),
            effects: [StripPlugin(name: "Tape Delay", bypassed: false, y: 140),
                      StripPlugin(name: "Compressor", bypassed: true, y: 160)],
            hasMidiPluginButton: true, hasEmptyInstrumentSlot: false, hasEmptyEffectSlot: true, master: nil)
        XCTAssertEqual(model.chainText, "Diva | Tape Delay, Compressor")
        XCTAssertEqual(model.plugins.count, 3)
        model.effects = []
        XCTAssertEqual(model.chainText, "Diva | -")
        XCTAssertTrue(model.compactJSON().contains("\"track_name\":\"Stab\""))
    }
}
