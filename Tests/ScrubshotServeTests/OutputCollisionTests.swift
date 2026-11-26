import Foundation
import XCTest
@testable import scrubshot

/// A batch must not write over one of its own inputs, or write two inputs to one output.
final class OutputCollisionTests: XCTestCase {
    func config(_ inputs: [String], output: String? = nil) -> Config {
        var c = Config()
        c.inputs = inputs
        c.output = output
        return c
    }

    func testOutputOverAnotherInputIsRefused() {
        XCTAssertThrowsError(try checkOutputCollisions(config(["/t/shot.png", "/t/shot-scrubbed.png"])))
        XCTAssertThrowsError(try checkOutputCollisions(config(["/t/shot-scrubbed.png", "/t/shot.png"])))
        XCTAssertThrowsError(try checkOutputCollisions(config(["/t/shot.png", "/t/SHOT-scrubbed.report.json"])))
    }

    func testTwoInputsWithOneOutputAreRefused() {
        XCTAssertThrowsError(try checkOutputCollisions(config(["/t/shot.png", "/t/shot.jpg"])))
        XCTAssertThrowsError(try checkOutputCollisions(config(["/t/shot.png", "/t/Shot.jpg"])))
    }

    func testSeparateNamesAreFine() throws {
        try checkOutputCollisions(config(["/t/a.png", "/t/b.png", "/u/a.png"]))
        try checkOutputCollisions(config(["/t/a.png"], output: "/t/out.png"))
    }
}
