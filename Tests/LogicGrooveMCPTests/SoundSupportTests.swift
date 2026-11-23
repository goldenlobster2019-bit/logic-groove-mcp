import Foundation
import MCP
import XCTest
@testable import LogicGrooveMCP

final class SoundSupportTests: XCTestCase {
    func testPluginFolderNameValidation() {
        for good in ["Diva", " Hive ", "Zebra2", "My-Synth_2", "Repro 5"] {
            if case .failure(let message) = ComposeSupport.validatePluginFolderName(good) {
                XCTFail("Expected '\(good)' to be valid: \(message)")
            }
        }
        for bad in ["", "   ", "../Diva", "Diva/Presets", "Di\u{00E9}va", "a;b", String(repeating: "a", count: 41)] {
            if case .success = ComposeSupport.validatePluginFolderName(bad) {
                XCTFail("Expected '\(bad)' to be rejected")
            }
        }
        if case .success(let value) = ComposeSupport.validatePluginFolderName("  Diva ") {
            XCTAssertEqual(value, "Diva")
        } else {
            XCTFail("Expected trimmed name")
        }
    }

    func testPresetReferenceSafety() {
        XCTAssertTrue(ComposeSupport.isSafePresetReference("HS Stabz"))
        XCTAssertTrue(ComposeSupport.isSafePresetReference("1 BASS/MK Bass Sub Tri"))
        XCTAssertFalse(ComposeSupport.isSafePresetReference(""))
        XCTAssertFalse(ComposeSupport.isSafePresetReference("../../etc/passwd"))
        XCTAssertFalse(ComposeSupport.isSafePresetReference("a\u{0}b"))
        XCTAssertFalse(ComposeSupport.isSafePresetReference(String(repeating: "a", count: 513)))
    }

    func testPathInsideRoots() {
        let roots = [URL(fileURLWithPath: "/Library/Audio/Presets/u-he/Diva")]
        XCTAssertTrue(ComposeSupport.path("/Library/Audio/Presets/u-he/Diva/1 BASS/x.h2p", isInside: roots))
        XCTAssertTrue(ComposeSupport.path("/Library/Audio/Presets/u-he/Diva", isInside: roots))
        XCTAssertFalse(ComposeSupport.path("/Library/Audio/Presets/u-he/Diva2/x.h2p", isInside: roots))
        XCTAssertFalse(ComposeSupport.path("/Library/Audio/Presets/u-he/Diva/../Hive/x.h2p", isInside: roots))
        XCTAssertFalse(ComposeSupport.path("/etc/passwd", isInside: roots))
    }

    func testSoundPaths() {
        XCTAssertEqual(ComposeSupport.uheLocalRoot(plugin: "Diva").path, "/Library/Audio/Presets/u-he/Diva")
        XCTAssertEqual(ComposeSupport.uheBankFolder(plugin: "Diva").path, "/Library/Audio/Presets/u-he/Diva/MIDI Programs")
        XCTAssertTrue(ComposeSupport.uheUserRoot(plugin: "Diva").path.hasSuffix("Library/Audio/Presets/u-he/Diva"))
        XCTAssertTrue(ComposeSupport.soundBankManifestURL(plugin: "Diva").path.hasSuffix("Music/LogicGrooveMCP/Diva-bank.json"))
    }

    func testFormatDecibels() {
        XCTAssertEqual(ComposeSupport.formatDecibels(-6, like: "0,0 dB"), "-6,0 dB")
        XCTAssertEqual(ComposeSupport.formatDecibels(-6.5, like: "0.0 dB"), "-6.5 dB")
        XCTAssertEqual(ComposeSupport.formatDecibels(3.5, like: "-1,2 dB"), "3,5 dB")
        XCTAssertEqual(ComposeSupport.parseDecibels(ComposeSupport.formatDecibels(-12.3, like: "0,0 dB")), -12.3)
    }

    func testLooseNumbers() {
        XCTAssertEqual(InputValidation.looseDouble(.int(-6)), -6)
        XCTAssertEqual(InputValidation.looseDouble(.double(-6.5)), -6.5)
        XCTAssertEqual(InputValidation.looseDouble(.string("-3")), -3)
        XCTAssertNil(InputValidation.looseDouble(.bool(true)))
        XCTAssertNil(InputValidation.looseDouble(nil))
        XCTAssertEqual(InputValidation.looseInt(.int(4)), 4)
        XCTAssertEqual(InputValidation.looseInt(.double(4.0)), 4)
        XCTAssertNil(InputValidation.looseInt(.double(4.5)))
        XCTAssertEqual(InputValidation.looseInt(.string("7")), 7)
        XCTAssertNil(InputValidation.looseInt(nil))
    }

    func testProjectWindowTitles() {
        XCTAssertTrue(AXLogicProElements.isProjectWindowTitle("Song.logicx - Tracks"))
        XCTAssertTrue(AXLogicProElements.isProjectWindowTitle("Untitled - Tracks"))
        XCTAssertFalse(AXLogicProElements.isProjectWindowTitle("Import"))
        XCTAssertFalse(AXLogicProElements.isProjectWindowTitle("Studio Grand"))
    }
}
