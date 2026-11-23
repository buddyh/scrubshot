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
            return applyCase(of: original, to: pick(list, near: original.count, key: key))
        }
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let p = pick(list, near: w.count, key: key + "#\(i)", avoid: out)
            out.append(applyCase(of: String(w), to: p))
        }
        return out.joined(separator: " ")
    }

    static func person(_ original: String, _ key: String) -> String {
        let words = original.split(separator: " ")
        if words.count <= 1 {
            return applyCase(of: original, to: pick(Words.firstNames, near: original.count, key: key))
        }
        let first = pick(Words.firstNames, near: words.first!.count, key: key + "#first")
        let last = pick(Words.lastNames, near: words.last!.count, key: key + "#last")
        return applyCase(of: String(words.first!), to: first) + " " + applyCase(of: String(words.last!), to: last)
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
            out.append(pick(Words.repo, near: max(2, s.count), key: key + "#\(i)", avoid: out))
        }
        return out.joined(separator: "-")
    }

    /// Fake address about as long as the original, always at example.com.
    static func email(_ original: String, _ key: String) -> String {
        let local = original.split(separator: "@").first.map(String.init) ?? original
        let parts = local.split(whereSeparator: { ".-_".contains($0) })
        // Budget the local part so the whole address stays near the original length.
        let budget = max(3, original.count - "@example.com".count)
        if parts.count >= 2 {
            let f = max(2, budget * parts[0].count / max(1, parts[0].count + parts[1].count))
            let first = pick(Words.firstNames, near: f, key: key + "#first").lowercased()
            let last = pick(Words.lastNames, near: max(2, budget - f - 1), key: key + "#last").lowercased()
            return "\(first).\(last)@example.com"
        }
        return pick(Words.firstNames, near: budget, key: key + "#first").lowercased() + "@example.com"
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
