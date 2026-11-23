import Foundation
import XCTest
@testable import LogicGrooveMCP

final class PluginSupportTests: XCTestCase {
    func testParseBankProgram() {
        let parsed = ComposeSupport.parseBankProgram("0/29 029 HS Stabz")
        XCTAssertEqual(parsed?.bank, 0)
        XCTAssertEqual(parsed?.program, 29)
        XCTAssertNil(ComposeSupport.parseBankProgram("Studio Grand"))
        XCTAssertNil(ComposeSupport.parseBankProgram("a/b c"))
        XCTAssertEqual(ComposeSupport.presetNameFromBankName("0/29 029 HS Stabz"), "HS Stabz")
        XCTAssertNil(ComposeSupport.presetNameFromBankName("Studio Grand"))
    }

    func testFormatValueLikeSample() {
        XCTAssertEqual(ComposeSupport.formatValue(40, like: "12,5 %"), "40,0 %")
        XCTAssertEqual(ComposeSupport.formatValue(0.25, like: "0.50"), "0.25")
        XCTAssertEqual(ComposeSupport.formatValue(-3, like: "-6,0 dB"), "-3,0 dB")
    }

    func testParseDisplayedNumberAndDecimals() {
        XCTAssertEqual(ComposeSupport.parseDisplayedNumber("12,5 %"), 12.5)
        XCTAssertEqual(ComposeSupport.parseDisplayedNumber("-6.0 dB"), -6.0)
        XCTAssertEqual(ComposeSupport.parseDisplayedNumber("1.2 kHz"), 1.2)
        XCTAssertNil(ComposeSupport.parseDisplayedNumber("Saw"))
        XCTAssertEqual(ComposeSupport.displayedDecimals("12,50 %"), 2)
        XCTAssertEqual(ComposeSupport.displayedDecimals("40 Hz"), 0)
    }

    func testNearestStep() {
        XCTAssertEqual(ComposeSupport.nearestStep(target: -15, lower: -16, upper: -14), -16)
        XCTAssertEqual(ComposeSupport.nearestStep(target: -14.2, lower: -16, upper: -14), -14)
    }

    func testCompactLines() {
        XCTAssertEqual(
            ComposeSupport.compactPresetLine(name: "HS Stabz", folder: "1 BASS", categories: ["Bass:Sub", "Pads"], program: 29),
            "HS Stabz | 1 BASS | Bass:Sub, Pads | program 29")
        XCTAssertEqual(
            ComposeSupport.compactPresetLine(name: "X", folder: "F", categories: [], program: nil),
            "X | F | ")
        XCTAssertEqual(ComposeSupport.compactBankLine(program: 5, name: "X"), "  5  X")
    }

    func testSplitMenuPath() {
        XCTAssertEqual(ComposeSupport.splitMenuPath("Dub Delays/Dub Echo"), ["Dub Delays", "Dub Echo"])
        XCTAssertEqual(ComposeSupport.splitMenuPath(" /Kicks/ "), ["Kicks"])
    }

    func testValidateBouncePath() {
        if case .success(let path) = ComposeSupport.validateBouncePath(nil) {
            XCTAssertTrue(path.hasSuffix(".wav"))
            XCTAssertTrue(path.contains("LogicGrooveMCP/Bounces/bounce-"))
        } else {
            XCTFail("default path must validate")
        }
        if case .success = ComposeSupport.validateBouncePath("/etc/x.wav") { XCTFail("outside home must fail") }
        if case .success = ComposeSupport.validateBouncePath("~/a.txt") { XCTFail("wrong extension must fail") }
        if case .failure = ComposeSupport.validateBouncePath("~/Music/a.wav") { XCTFail("home path must validate") }
    }
}
