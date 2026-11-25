import XCTest
@testable import ScrubshotCore

final class RulesValidationTests: XCTestCase {
    private func parseError(_ json: String) -> String? {
        do {
            _ = try RulesFile.parse(Data(json.utf8), source: "test.json")
            return nil
        } catch {
            return "\(error)"
        }
    }

    func testValidFileParses() {
        XCTAssertNil(parseError(#"{"detectors": {"email": true}, "rules": [{"term": "Globex", "replace": "Initech"}]}"#))
    }

    func testUnknownKeyNamesKeyAndSuggestsFix() throws {
        let msg = try XCTUnwrap(parseError(#"{"rules": [{"term": "Globex", "replcae": "Initech"}]}"#))
        XCTAssertTrue(msg.contains("test.json"), msg)
        XCTAssertTrue(msg.contains("rules[1]"), msg)
        XCTAssertTrue(msg.contains("\"replcae\""), msg)
        XCTAssertTrue(msg.contains("did you mean \"replace\""), msg)
    }

    func testUnknownTopLevelAndDetectorKeys() {
        XCTAssertNotNil(parseError(#"{"rulez": []}"#))
        XCTAssertNotNil(parseError(#"{"detectors": {"phone": true}, "rules": []}"#))
    }

    func testEmptyTermsAreRejected() {
        XCTAssertNotNil(parseError(#"{"rules": [{"term": "  "}]}"#))
        XCTAssertNotNil(parseError(#"{"rules": [{"terms": []}]}"#))
        XCTAssertNotNil(parseError(#"{"rules": [{"terms": ["Globex", ""]}]}"#))
        XCTAssertNotNil(parseError(#"{"rules": [{"regex": ""}]}"#))
    }

    func testWrongShapesAreRejected() {
        XCTAssertNotNil(parseError(#"[]"#))
        XCTAssertNotNil(parseError(#"{"rules": {}}"#))
        XCTAssertNotNil(parseError(#"{"rules": ["Globex"]}"#))
        XCTAssertNotNil(parseError("not json"))
    }

    func testRegexDiagnosisPointsAtTheMistake() {
        XCTAssertEqual(RulesValidation.diagnose("acme-(billing"), "unclosed \"(\" at column 6")
        XCTAssertEqual(RulesValidation.diagnose("acme)"), "unmatched \")\" at column 5")
        XCTAssertEqual(RulesValidation.diagnose("*acme"), "nothing to repeat before \"*\" at column 1")
        XCTAssertNil(RulesValidation.diagnose("acme-[a-z]+"))
    }

    func testBadRegexErrorShowsPattern() throws {
        let rules = try RulesFile.parse(Data(#"{"rules": [{"regex": "acme-(billing"}]}"#.utf8), source: "test.json")
        XCTAssertThrowsError(try RuleSet.build(files: [rules])) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("acme-(billing"), msg)
            XCTAssertTrue(msg.contains("column 6"), msg)
        }
    }
}
