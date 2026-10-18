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

    func testPositionStrings() {
        XCTAssertEqual(ComposeSupport.positionString(tick: 0), "1.1.1")
        XCTAssertEqual(ComposeSupport.positionString(tick: 240), "1.1.3")
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
}
