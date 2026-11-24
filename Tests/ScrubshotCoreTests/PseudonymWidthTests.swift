import XCTest
@testable import ScrubshotCore

final class PseudonymWidthTests: XCTestCase {
    private let samples: [(String, ScrubshotCore.Category)] = [
        ("Falcon Console", .product), ("Mapleton Billing Suite", .product), ("Ox", .word),
        ("Quartermaster", .word), ("Hartwell Logistics", .company), ("Zed", .company),
        ("Brightwater Holdings", .company), ("Jordan Reyes", .person), ("Li Wu", .person),
        ("Bartholomew Featherstone", .person), ("acme-billing-api", .repo), ("octo/acme-web", .repo),
        ("zz-tracker", .repo), ("jordan.reyes@mapleton.test", .email), ("li@mapleton.test", .email),
    ]

    private func width(_ s: String) -> Double { Pseudonym.referenceWidth(s) }

    /// The old pick: nearest character count, by hash.
    private func oldStyle(_ original: String, _ category: ScrubshotCore.Category) -> String {
        let list: [String]
        switch category {
        case .company: list = Words.company
        case .person: list = Words.firstNames
        case .repo: list = Words.repo
        default: list = Words.product
        }
        let words = original.split(separator: " ")
        let out = words.map { w in
            Pseudonym.applyCase(of: String(w), to: Pseudonym.pick(list, near: w.count, key: category.rawValue + ":" + w.lowercased()))
        }
        return out.joined(separator: " ")
    }

    func testSameInputGivesSameFake() {
        for (text, cat) in samples {
            let seed = Rule.fold(text)
            XCTAssertEqual(Pseudonym.make(for: text, category: cat, seed: seed),
                           Pseudonym.make(for: text, category: cat, seed: seed), text)
        }
    }

    func testWidthIsCloserThanCharacterCountPick() {
        var newTotal = 0.0, oldTotal = 0.0
        let words = ["Falcon", "Northwind", "Ox", "Quartermaster", "Mapleton", "Zed", "Brightwater", "Hartwell",
                     "Reyes", "Featherstone", "Billing", "Wu", "Immigrant", "Willow", "Mill"]
        var within = 0
        for w in words {
            let fake = Pseudonym.make(for: w, category: .company, seed: Rule.fold(w))
            let old = oldStyle(w, .company)
            let target = width(w)
            newTotal += abs(width(fake) - target)
            oldTotal += abs(width(old) - target)
            if abs(width(fake) - target) / target <= 0.15 { within += 1 }
        }
        XCTAssertLessThan(newTotal, oldTotal, "width pick should beat character-count pick on average")
        XCTAssertGreaterThanOrEqual(within, words.count * 2 / 3, "most fakes within 15% of original width")
    }

    func testPersonAndRepoWidthsStayClose() {
        for (text, cat) in samples where cat == .person || cat == .repo {
            let fake = Pseudonym.make(for: text, category: cat, seed: Rule.fold(text))
            let ratio = width(fake) / width(text)
            XCTAssertTrue((0.5...1.6).contains(ratio), "\(text) -> \(fake) ratio \(ratio)")
        }
    }

    func testShapesArePreserved() {
        let repo = Pseudonym.make(for: "acme-billing-api", category: .repo, seed: "acme-billing-api")
        XCTAssertEqual(repo.split(separator: "-").count, 3)
        XCTAssertEqual(repo, repo.lowercased())
        let owned = Pseudonym.make(for: "octo/acme-web", category: .repo, seed: "octo/acme-web")
        XCTAssertEqual(owned.split(separator: "/").count, 2)
        XCTAssertEqual(owned.split(separator: "/")[1].split(separator: "-").count, 2)
        let person = Pseudonym.make(for: "Jordan Reyes", category: .person, seed: "jordan reyes")
        XCTAssertEqual(person.split(separator: " ").count, 2)
        XCTAssertTrue(person.first!.isUppercase)
        let mail = Pseudonym.make(for: "jordan.reyes@mapleton.test", category: .email, seed: "x")
        XCTAssertTrue(mail.hasSuffix("@example.com"))
        XCTAssertEqual(mail.split(separator: "@")[0].split(separator: ".").count, 2)
        let acro = Pseudonym.make(for: "QXTV", category: .company, seed: "qxtv")
        XCTAssertEqual(acro.count, 4)
        XCTAssertEqual(acro, acro.uppercased())
        let upper = Pseudonym.make(for: "FALCON CONSOLE", category: .product, seed: "falcon console")
        XCTAssertEqual(upper, upper.uppercased())
    }
}
