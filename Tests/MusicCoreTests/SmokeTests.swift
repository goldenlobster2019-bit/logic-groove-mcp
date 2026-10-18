import XCTest
@testable import MusicCore
final class SmokeTests: XCTestCase { func testPPQ() { XCTAssertEqual(MusicCore.ticksPerBar(), 1920) } }
