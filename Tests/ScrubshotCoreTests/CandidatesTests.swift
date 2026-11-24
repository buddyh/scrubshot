import Foundation
import XCTest
@testable import ScrubshotCore

final class CandidatesTests: XCTestCase {
    func testReplaceListDecodesAndRoundTrips() throws {
        let json = #"{"rules":[{"term":"Globex","replace":["Relay","Beacon"]},{"term":"Initech","replace":"Signal"}]}"#
        let f = try JSONDecoder().decode(RulesFile.self, from: Data(json.utf8))
        XCTAssertEqual(f.rules?[0].candidates, ["Relay", "Beacon"])
        XCTAssertNil(f.rules?[0].replace)
        XCTAssertEqual(f.rules?[1].replace, "Signal")
        XCTAssertNil(f.rules?[1].candidates)
        let again = try JSONDecoder().decode(RulesFile.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(again.rules?[0].candidates, ["Relay", "Beacon"])
    }

    func testMatchCarriesAllCandidatesWithFirstAsDefault() throws {
        let rs = try RuleSet.build(files: [RulesFile(rules: [.init(term: "Globex", candidates: ["Relay", "Beacon"])])])
        let m = rs.matches(in: "Ask Globex today")
        XCTAssertEqual(m.first?.replacement, "Relay")
        XCTAssertEqual(m.first?.candidates, ["Relay", "Beacon"])
    }

    func testRegexCandidatesExpandGroups() throws {
        let rs = try RuleSet.build(files: [RulesFile(rules: [.init(regex: "ticket-(\\d+)", candidates: ["case-$1", "t-$1"])])])
        XCTAssertEqual(rs.matches(in: "see ticket-42").first?.candidates, ["case-42", "t-42"])
    }

    func testBadListsAreRejected() {
        for list in [[], [""], ["auto"]] {
            XCTAssertThrowsError(try RuleSet.rule(from: .init(term: "x", candidates: list), id: "r"))
        }
        XCTAssertThrowsError(try RuleSet.rule(from: .init(term: "x", replace: "a", candidates: ["b"]), id: "r"))
    }

    /// The rule is used on lines of two different sizes. One candidate is chosen, it is the
    /// one with the smallest reported width delta, and both lines use it.
    func testPicksClosestWidthAndStaysConsistent() throws {
        let img = Fixtures.image(Fixtures.light, scale: 2)
        let list = ["Tiny", "Harbor Console", "Orchid Console Pro Max"]
        let rules = try RuleSet.build(files: [RulesFile(rules: [.init(term: "Falcon Console", candidates: list)])])
        let result = try Scrubber.scrub(img, options: ScrubOptions(rules: rules))
        XCTAssertEqual(result.leaks, [])
        let recs = result.replacements.filter { $0.rule == "file1.rule1" }
        XCTAssertEqual(recs.count, 2)
        let chosen = Set(recs.map(\.replacement))
        XCTAssertEqual(chosen.count, 1)
        let opts = try XCTUnwrap(recs[0].candidates)
        XCTAssertEqual(opts.map(\.text), list)
        XCTAssertEqual(opts.filter(\.chosen).count, 1)
        let best = try XCTUnwrap(opts.min { abs($0.widthDelta ?? 1e9) < abs($1.widthDelta ?? 1e9) })
        XCTAssertEqual(chosen.first, best.text)
        XCTAssertEqual(chosen.first, "Harbor Console")
        XCTAssertEqual(recs[0].candidates, recs[1].candidates)
        XCTAssertTrue(recs.allSatisfy { $0.redrawnTo.contains("Harbor Console") })
    }

    func testResultIsDeterministic() throws {
        let img = Fixtures.image(Fixtures.dark, scale: 1)
        let rules = try RuleSet.build(files: [RulesFile(rules: [.init(term: "Falcon Console", candidates: ["Relay Desk", "Harbor Console"])])])
        let a = try Scrubber.scrub(img, options: ScrubOptions(rules: rules))
        let b = try Scrubber.scrub(img, options: ScrubOptions(rules: rules))
        XCTAssertEqual(a.replacements.map(\.replacement), b.replacements.map(\.replacement))
        XCTAssertEqual(try Bitmap(image: a.image).data, try Bitmap(image: b.image).data)
    }
}
