import Foundation

/// What kind of fake text an `auto` replacement should produce.
public enum Category: String, Codable, CaseIterable {
    case word, company, person, product, repo, acronym, email, url
}

/// Stable fake replacements. The same (category, seed) always gives the same output,
/// across runs and machines, so a series of screenshots stays consistent.
public enum Pseudonym {
    public static func make(for original: String, category: Category, seed: String) -> String {
        let key = category.rawValue + ":" + seed.lowercased()
        switch category {
        case .person:
            return person(original, key)
        case .repo:
            return repo(original, key)
        case .email:
            return email(original, key)
        case .url:
            return "https://example.com/" + pick(Words.product, near: 6, key: key + "#url").lowercased()
        case .acronym:
            return acronym(original, key)
        case .company, .product, .word:
            if looksLikeAcronym(original) { return acronym(original, key) }
            let list = category == .company ? Words.company : Words.product
            return phrase(original, list: list, key: key)
        }
    }

    // MARK: generators

    static func phrase(_ original: String, list: [String], key: String) -> String {
        let words = original.split(whereSeparator: { $0 == " " })
        if words.count <= 1 {
            return pickByWidth(list, like: original, key: key)
        }
        var out: [String] = []
        for (i, w) in words.enumerated() {
            out.append(pickByWidth(list, like: String(w), key: key + "#\(i)", avoid: out))
        }
        return out.joined(separator: " ")
    }

    static func person(_ original: String, _ key: String) -> String {
        let words = original.split(separator: " ")
        if words.count <= 1 {
            return pickByWidth(Words.firstNames, like: original, key: key)
        }
        let first = pickByWidth(Words.firstNames, like: String(words.first!), key: key + "#first")
        let last = pickByWidth(Words.lastNames, like: String(words.last!), key: key + "#last")
        return first + " " + last
    }

    static func repo(_ original: String, _ key: String) -> String {
        // Keep an owner prefix shape like "owner/name" but replace both parts.
        if let slash = original.lastIndex(of: "/") {
            let owner = String(original[..<slash]), name = String(original[original.index(after: slash)...])
            return repo(owner, key + "#owner") + "/" + repo(name, key)
        }
        let segments = original.split(separator: "-", omittingEmptySubsequences: false)
        var out: [String] = []
        for (i, s) in segments.prefix(5).enumerated() {
            out.append(pickByWidth(Words.repo, like: String(s), key: key + "#\(i)", avoid: out))
        }
        return out.joined(separator: "-")
    }

    /// Fake address with each name part about as wide as the original's, always at example.com.
    static func email(_ original: String, _ key: String) -> String {
        let local = original.split(separator: "@").first.map(String.init) ?? original
        let parts = local.split(whereSeparator: { ".-_".contains($0) })
        if parts.count >= 2 {
            let first = pickByWidth(Words.firstNames, like: String(parts[0]).lowercased(), key: key + "#first").lowercased()
            let last = pickByWidth(Words.lastNames, like: String(parts[1]).lowercased(), key: key + "#last").lowercased()
            return "\(first).\(last)@example.com"
        }
        return pickByWidth(Words.firstNames, like: local.lowercased(), key: key + "#first").lowercased() + "@example.com"
    }

    static func acronym(_ original: String, _ key: String) -> String {
        let letters = Array("ABDEFGHJKLMNPRSTVWXZ")
        var h = fnv1a(key)
        var out = ""
        for ch in original {
            if ch.isLetter {
                out.append(letters[Int(h % UInt64(letters.count))])
                h = h / UInt64(letters.count) ^ fnv1a(key + out)
            } else {
                out.append(ch)
            }
        }
        return applyCase(of: original, to: out)
    }

    static func looksLikeAcronym(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return !s.contains(" ") && letters.count >= 2 && letters.count <= 6 && letters.allSatisfy(\.isUppercase)
    }

    // MARK: helpers

    /// Advance widths of ASCII 32...126 in the macOS system font (SF Pro) at 13pt, measured once
    /// with CoreText and fixed here so auto picks don't depend on the fonts a machine has.
    /// Widths scale roughly with size and across similar sans fonts, so one table keeps the
    /// choice independent of the image.
    static let referenceAdvances: [Double] = [
        3.58, 3.97, 6.13, 8.11, 8.11, 11.95, 9.17, 3.78, 4.89, 4.89, 6.06, 8.11,
        3.78, 6.06, 3.78, 3.88, 8.11, 5.95, 7.77, 8.07, 8.29, 7.96, 8.20, 7.33,
        8.23, 8.20, 3.78, 3.78, 8.11, 8.11, 8.11, 6.59, 11.86, 8.68, 8.47, 9.23,
        9.37, 7.67, 7.36, 9.63, 9.57, 3.40, 6.92, 8.49, 7.31, 11.29, 9.57, 9.95,
        8.18, 9.95, 8.42, 8.21, 8.16, 9.51, 8.68, 12.50, 8.75, 8.44, 8.52, 4.89,
        3.88, 4.89, 8.11, 7.51, 6.42, 7.10, 7.91, 7.20, 7.91, 7.35, 4.63, 7.85,
        7.57, 3.14, 3.13, 6.98, 3.21, 11.24, 7.51, 7.60, 7.86, 7.85, 4.88, 6.73,
        4.65, 7.51, 6.97, 9.99, 6.74, 6.98, 6.93, 4.89, 3.29, 4.89, 8.11
    ]

    /// Approximate rendered width of `text` in the reference font, in points (no kerning).
    /// Characters outside printable ASCII count as an average lowercase letter.
    static func referenceWidth(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { sum, u in
            let v = Int(u.value)
            return sum + ((32...126).contains(v) ? referenceAdvances[v - 32] : 7.2)
        }
    }

    /// Picks a word from `list` that renders about as wide as `original` (after copying its casing).
    /// Takes the few nearest by width and chooses among them by hash, so the same key always
    /// gives the same word without every similar-width original mapping to one word.
    static func pickByWidth(_ list: [String], like original: String, key: String, avoid: [String] = [], nearest k: Int = 3) -> String {
        let target = referenceWidth(original)
        let avoided = Set(avoid.map { $0.lowercased() })
        var ranked: [(delta: Double, index: Int, word: String)] = []
        for (i, w) in list.enumerated() where !avoided.contains(w.lowercased()) {
            let cased = applyCase(of: original, to: w)
            ranked.append((abs(referenceWidth(cased) - target), i, cased))
        }
        if ranked.isEmpty { return applyCase(of: original, to: list[Int(fnv1a(key) % UInt64(list.count))]) }
        ranked.sort { $0.delta != $1.delta ? $0.delta < $1.delta : $0.index < $1.index }
        let top = ranked.prefix(k)
        return top[top.startIndex + Int(fnv1a(key) % UInt64(top.count))].word
    }

    /// Picks from `list` a word whose length is close to `target`, by hash.
    static func pick(_ list: [String], near target: Int, key: String, avoid: [String] = []) -> String {
        var pool: [String] = []
        for tol in [0, 1, 2, 3, 5, 1000] {
            pool = list.filter { abs($0.count - target) <= tol && !avoid.contains($0) }
            if pool.count >= 4 || tol == 1000 { break }
        }
        if pool.isEmpty { pool = list }
        return pool[Int(fnv1a(key) % UInt64(pool.count))]
    }

    /// Makes `fake` look like `original`: same word separator (space, dash, underscore)
    /// and the same casing style.
    public static func adaptShape(_ fake: String, to original: String) -> String {
        var out = fake
        let hasSpace = original.contains(" ")
        for sep in ["-", "_"] where !hasSpace && original.contains(sep) {
            out = out.replacingOccurrences(of: " ", with: sep)
        }
        if hasSpace && !original.contains("-") && !out.contains(" ") {
            out = out.replacingOccurrences(of: "-", with: " ")
        }
        return applyCase(of: original, to: out)
    }

    /// Copies the casing style of `original` (UPPER, lower, Title) onto `replacement`.
    public static func applyCase(of original: String, to replacement: String) -> String {
        let letters = original.filter(\.isLetter)
        guard !letters.isEmpty else { return replacement }
        if letters.count >= 2 && letters.allSatisfy(\.isUppercase) { return replacement.uppercased() }
        if letters.allSatisfy(\.isLowercase) { return replacement.lowercased() }
        if letters.first!.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// 64-bit FNV-1a. Swift's Hasher is seeded per process, so it cannot be used here.
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}

/// Word lists for fake names. Order matters for stable output: append only.
enum Words {
    static let company = [
        "Northwind", "Contoso", "Fabrikam", "Tailspin", "Litware", "Proseware", "Adatum", "Wingtip",
        "Lucerne", "Alder", "Birch", "Cedar", "Ashby", "Wren", "Quill", "Sable", "Umber", "Yarrow",
        "Juniper", "Kestrel", "Jasper", "Hollis", "Everly", "Verity", "Orchard", "Thistle", "Zephyr",
        "Redwing", "Quarry", "Nettle", "Upland", "Dunmore", "Fernhill", "Glenwood", "Inkwell", "Kingsley",
        "Larkspur", "Marigold", "Pembrook", "Rookwood", "Tamarack", "Valemont", "Northgate", "Oakridge",
        "Pinecrest", "Copperline", "Driftstone", "Elmhurst", "Foxglove", "Harborview", "Ironleaf",
        "Lakeshore", "Meadowlark", "Stonebridge", "Willowbrook", "Brightwater", "Clearbrook", "Granitebay",
        "Bramblewood", "Silverpine", "Summerfield", "Blue Heron", "Red Fern", "Oak", "Elm", "Ivy", "Fen",
        "Moss", "Ash", "Bay", "Cove", "Dale", "Glen", "Kiln", "Loft", "Mill", "Pier", "Vale", "Wynd",
        "Acorn", "Basil", "Clove", "Delta", "Fable", "Grove", "Haven", "Lumen", "Maple", "Otter", "Piper",
        "Rowan", "Slate", "Tidal", "Vista", "Willow", "Amberly", "Bellweather", "Cobalt", "Halcyon",
    ]

    static let product = [
        "Atlas", "Beacon", "Compass", "Drift", "Ember", "Fathom", "Glide", "Harbor", "Insight", "Junction",
        "Keystone", "Lumen", "Mosaic", "Nimbus", "Orbit", "Pulse", "Quartz", "Relay", "Signal", "Tandem",
        "Vector", "Waypoint", "Zenith", "Canvas", "Ledger", "Board", "Hub", "Desk", "Lens", "Forge",
        "Vault", "Grid", "Spark", "Pilot", "Scout", "Bridge", "Stream", "Deck", "Loom", "Kite", "Arc",
        "Bolt", "Core", "Dash", "Echo", "Flux", "Gem", "Hive", "Ion", "Jet", "Knot", "Lark", "Mint",
        "Nova", "Oak", "Peak", "Quay", "Reef", "Sage", "Tide", "Vale", "Wave", "Yard", "Prism", "Summit",
        "Tracer", "Cascade", "Horizon", "Meridian", "Paragon", "Sentinel", "Trellis", "Lantern", "Outpost",
        "Pathway", "Workshop", "Overview", "Pipeline", "Momentum", "Spotlight", "Northstar", "Blueprint",
        "Keel", "Fern", "Cove", "Mast", "Helm", "Tern", "Dune", "Crest", "Ridge", "Grove", "Haven",
        "Studio", "Builder", "Planner", "Monitor", "Tracker", "Console", "Toolkit", "Notebook", "Explorer",
    ]

    static let firstNames = [
        "Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Avery", "Quinn", "Jamie", "Drew", "Sam",
        "Robin", "Jesse", "Parker", "Reese", "Rowan", "Skyler", "Emerson", "Harper", "Kendall", "Logan",
        "Peyton", "Sasha", "Blair", "Cameron", "Dakota", "Elliot", "Finley", "Hayden", "Kai", "Lane",
        "Marlowe", "Noel", "Oakley", "Remy", "Sage", "Tatum", "Ari", "Bo", "Cory", "Dana", "Eden", "Frankie",
        "Gale", "Jules", "Kit", "Lee", "Max", "Nico", "Pat", "Ray", "Shay", "Toby", "Val", "Wren",
        "Arden", "Bailey", "Carmen", "Devon", "Ellis", "Francis", "Glenn", "Hollis", "Indigo", "Jody",
        "Kerry", "Lennon", "Micah", "Nova", "Oriel", "Perry", "Reagan", "Sidney", "Teagan", "Uri", "Vesper",
    ]

    static let lastNames = [
        "Smith", "Rivera", "Chen", "Patel", "Brooks", "Carter", "Diaz", "Ellis", "Foster", "Gray", "Hughes",
        "Ibarra", "James", "Kim", "Lopez", "Moore", "Nguyen", "Owens", "Price", "Reed", "Shaw", "Torres",
        "Vance", "Ward", "Young", "Zhang", "Bennett", "Collins", "Dawson", "Fischer", "Grant", "Hale",
        "Irwin", "Keller", "Lambert", "Mercer", "Nolan", "Ortiz", "Porter", "Quinlan", "Russo", "Sutton",
        "Tran", "Underwood", "Vaughn", "Walsh", "Abbott", "Ng", "Li", "Fox", "Ruiz", "Lund", "Okafor",
        "Castillo", "Donovan", "Fairbanks", "Holloway", "Kowalski", "Lindqvist", "Montgomery", "Pemberton",
    ]

    static let repo = [
        "app", "api", "web", "ui", "cli", "kit", "hub", "ops", "lab", "sdk", "bot", "log", "db", "io",
        "core", "data", "sync", "feed", "tool", "docs", "site", "jobs", "auth", "edge", "grid", "flow",
        "panel", "board", "atlas", "relay", "orbit", "ledger", "beacon", "harbor", "signal", "studio",
        "report", "weekly", "digest", "tracker", "portal", "engine", "summit", "canvas", "insight",
        "pipeline", "dashboard", "workbench", "scheduler", "notifier", "exporter", "importer", "planner",
        "metrics", "monitor", "console", "service", "gateway", "toolkit", "explorer", "inventory",
        "north", "lumen", "drift", "ember", "glide", "vector", "pulse", "quartz", "scout", "forge",
        "sun", "oak", "fox", "elm", "bay", "owl", "kite", "fern", "moss", "reef", "tern", "wren",
    ]
}
