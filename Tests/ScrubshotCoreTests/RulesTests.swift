import Foundation
import XCTest
@testable import ScrubshotCore

final class RulesTests: XCTestCase {
    func set(_ specs: [RulesFile.Spec], email: Bool = false, url: Bool = false) throws -> RuleSet {
        try RuleSet.build(files: [RulesFile(detectors: .init(email: email, url: url), rules: specs)])
    }

    func testLiteralIsCaseInsensitiveAndToleratesOCRLookalikes() throws {
        let rs = try set([.init(term: "GLXIA", replace: "ACME")])
        XCTAssertEqual(rs.matches(in: "Fix the glxia login").map(\.original), ["glxia"])
        // OCR often reads I as l or 1.
        XCTAssertEqual(rs.matches(in: "Fix the GLXlA login").map(\.original), ["GLXlA"])
        XCTAssertEqual(rs.matches(in: "Fix the GLX1A login").map(\.original), ["GLX1A"])
    }

    func testCaseInsensitiveBeyondASCII() throws {
        let rs = try set([.init(term: "München", replace: "Springfield")])
        XCTAssertEqual(rs.matches(in: "Office: MÜNCHEN").map(\.original), ["MÜNCHEN"])
        XCTAssertEqual(Rule.fold("İSTANBUL").utf16.count, "İSTANBUL".utf16.count)
    }

    func testRedrawSpanStopsAtOCRBars() {
        let ns = "[7, octo/follow-up-1234|" as NSString
        let r = Scrubber.wordRange(ns, NSRange(location: 4, length: 5))
        XCTAssertEqual(ns.substring(with: r), "octo/follow-up-1234")
    }

    func testWholeWord() throws {
        let rs = try set([.init(term: "Orbis", wholeWord: true)])
        XCTAssertEqual(rs.matches(in: "the Orbis account").count, 1)
        XCTAssertEqual(rs.matches(in: "Orbisant").count, 0)
        XCTAssertEqual(rs.matches(in: "owner/Orbis-sync").count, 1)
    }

    func testSubstringInsideLongerToken() throws {
        let rs = try set([.init(term: "acme-", replace: "zeta-")])
        let m = rs.matches(in: "octo/acme-billing-api Meridian")
        XCTAssertEqual(m.map(\.original), ["acme-"])
        XCTAssertEqual(m.first?.range, NSRange(location: 5, length: 5))
    }

    func testRegexWithGroups() throws {
        let rs = try set([.init(regex: "acme-([a-z]+)", replace: "zeta-$1")])
        XCTAssertEqual(rs.matches(in: "see acme-billing now").map(\.replacement), ["zeta-billing"])
    }

    func testMultiWordTermMatchesAcrossExtraSpaces() throws {
        let rs = try set([.init(term: "Slide Forge", replace: "Deck Builder")])
        XCTAssertEqual(rs.matches(in: "Slide  Forge: Pick").map(\.original), ["Slide  Forge"])
    }

    func testOverlapsPreferEarliestThenLongest() throws {
        let rs = try set([.init(term: "Forge", replace: "X"), .init(term: "Slide Forge", replace: "Y")])
        XCTAssertEqual(rs.matches(in: "Slide Forge").map(\.replacement), ["Y"])
    }

    func testDetectors() throws {
        let rs = try set([], email: true, url: true)
        let m = rs.matches(in: "mail jane.doe@acme.test or open https://intranet.acme.test/x and acme.sharepoint.com/sites/a")
        XCTAssertEqual(m.map(\.original), ["jane.doe@acme.test", "https://intranet.acme.test/x", "acme.sharepoint.com/sites/a"])
        XCTAssertTrue(m[0].replacement.hasSuffix("@example.com"))
        XCTAssertTrue(m[1].replacement.hasPrefix("https://example.com/"))
        // Our own fake values must not count as leaks.
        XCTAssertEqual(rs.matches(in: "visit https://example.com/atlas").count, 0)
        XCTAssertEqual(rs.matches(in: "ask avery.gray@example.com").count, 0)
        // Look-alike hosts are real addresses and must still match.
        XCTAssertEqual(rs.matches(in: "ask jane@notexample.com").count, 1)
        XCTAssertEqual(rs.matches(in: "open https://example.com.evil.io/path").count, 1)
        XCTAssertEqual(rs.matches(in: "mail jane@corp.example.com.evil.io").count, 1)
    }

    func testAliasesShareOneFakeValueReshapedPerMatch() throws {
        let rs = try set([.init(terms: ["Slide Forge", "slide-forge"], category: .product)])
        let a = rs.matches(in: "Slide Forge").first!.replacement
        let b = rs.matches(in: "the slide-forge repo").first!.replacement
        XCTAssertEqual(b, a.lowercased().replacingOccurrences(of: " ", with: "-"))
    }

    func testBadRulesAreRejected() {
        XCTAssertThrowsError(try set([.init()]))
        XCTAssertThrowsError(try set([.init(term: "a", regex: "b")]))
        XCTAssertThrowsError(try set([.init(regex: "(")]))
    }

    func testExampleRulesFileParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("examples/rules.example.json")
        let rs = try RuleSet.build(files: [RulesFile.load(url)])
        XCTAssertGreaterThan(rs.rules.count, 3)
    }
}

final class PseudonymTests: XCTestCase {
    func testStableValues() {
        // Locks the word lists: changing these breaks consistency across screenshot series.
        let a = Pseudonym.make(for: "Acme Corp", category: .company, seed: "acme corp")
        XCTAssertEqual(a, Pseudonym.make(for: "Acme Corp", category: .company, seed: "acme corp"))
        XCTAssertEqual(Pseudonym.fnv1a("scrubshot"), 579196082939297168, "hash function changed")
    }

    func testCasingFollowsOriginal() {
        XCTAssertEqual(Pseudonym.applyCase(of: "GLXIA", to: "Atlas"), "ATLAS")
        XCTAssertEqual(Pseudonym.applyCase(of: "report", to: "Atlas"), "atlas")
        XCTAssertEqual(Pseudonym.applyCase(of: "Report", to: "atlas"), "Atlas")
    }

    func testShapes() {
        let repo = Pseudonym.make(for: "acme-status-board", category: .repo, seed: "acme-status-board")
        XCTAssertEqual(repo.split(separator: "-").count, 3)
        XCTAssertEqual(repo, repo.lowercased())
        let person = Pseudonym.make(for: "Jane Doe", category: .person, seed: "jane doe")
        XCTAssertEqual(person.split(separator: " ").count, 2)
        let acro = Pseudonym.make(for: "GLXIA", category: .word, seed: "glxia")
        XCTAssertEqual(acro.count, 5)
        XCTAssertEqual(acro, acro.uppercased())
        XCTAssertNotEqual(acro, "GLXIA")
        XCTAssertTrue(Pseudonym.make(for: "a@b.co", category: .email, seed: "a@b.co").hasSuffix("@example.com"))
    }

    func testLengthStaysClose() {
        for word in ["Northwind", "Ace", "Brightwater"] {
            let fake = Pseudonym.make(for: word, category: .company, seed: word)
            XCTAssertLessThanOrEqual(abs(fake.count - word.count), 2, "\(word) -> \(fake)")
        }
    }
}

final class RulesParseTests: XCTestCase {
    func testParseNamesTheSourceInErrors() {
        XCTAssertThrowsError(try RulesFile.parse(Data("{nope".utf8), source: "<stdin>")) { e in
            XCTAssertTrue("\(e)".contains("<stdin>"), "\(e)")
        }
    }

    func testParseReadsInlineJSON() throws {
        let f = try RulesFile.parse(Data(#"{"rules":[{"term":"Globex","replace":"Initech"}]}"#.utf8), source: "--rules-json")
        XCTAssertEqual(f.rules?.first?.term, "Globex")
    }
}
