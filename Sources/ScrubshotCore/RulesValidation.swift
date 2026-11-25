import Foundation

/// Strict checks on rules JSON, so a typo fails with a message that says where it is
/// instead of being ignored.
enum RulesValidation {
    static let topKeys = ["detectors", "rules"]
    static let detectorKeys = ["email", "url"]

    /// Throws `ScrubError.rules` for unknown keys, wrong shapes and empty terms.
    static func check(_ data: Data, source: String) throws {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) } catch {
            throw ScrubError.rules("\(source) is not valid JSON: \(error.localizedDescription)")
        }
        guard let top = any as? [String: Any] else { throw ScrubError.rules("\(source): top level must be an object with \"rules\"") }
        try unknownKeys(in: top, allowed: topKeys, at: "top level", source: source)
        if let d = top["detectors"] {
            guard let dict = d as? [String: Any] else { throw ScrubError.rules("\(source): \"detectors\" must be an object") }
            try unknownKeys(in: dict, allowed: detectorKeys, at: "detectors", source: source)
        }
        guard let rules = top["rules"] else { return }
        guard let list = rules as? [Any] else { throw ScrubError.rules("\(source): \"rules\" must be an array") }
        for (i, r) in list.enumerated() {
            let at = "rules[\(i + 1)]"
            guard let rule = r as? [String: Any] else { throw ScrubError.rules("\(source): \(at) must be an object") }
            try unknownKeys(in: rule, allowed: RulesFile.Spec.knownKeys, at: at, source: source)
            if let t = rule["term"] as? String, t.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ScrubError.rules("\(source): \(at): \"term\" is empty")
            }
            if let ts = rule["terms"] as? [Any] {
                if ts.isEmpty { throw ScrubError.rules("\(source): \(at): \"terms\" is empty") }
                for (j, t) in ts.enumerated() {
                    guard let s = t as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw ScrubError.rules("\(source): \(at): \"terms\"[\(j + 1)] is empty or not text")
                    }
                }
            }
            if let re = rule["regex"] as? String, re.isEmpty { throw ScrubError.rules("\(source): \(at): \"regex\" is empty") }
        }
    }

    static func unknownKeys(in dict: [String: Any], allowed: [String], at: String, source: String) throws {
        for key in dict.keys.sorted() where !allowed.contains(key) {
            var msg = "\(source): \(at): unknown key \"\(key)\""
            if let near = allowed.first(where: { distance($0.lowercased(), key.lowercased()) <= 2 }) {
                msg += " (did you mean \"\(near)\"?)"
            } else {
                msg += " (allowed: \(allowed.joined(separator: ", ")))"
            }
            throw ScrubError.rules(msg)
        }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Best guess at what is wrong with a regex that ICU rejected, with a 1-based column.
    /// ICU does not say where the error is, so this scans for the common mistakes.
    static func diagnose(_ pattern: String) -> String? {
        let chars = Array(pattern)
        var groups: [Int] = []
        var classStart: Int?
        var i = 0
        func canRepeat(_ k: Int) -> Bool {
            guard k > 0 else { return false }
            let p = chars[k - 1]
            if p == "(" || p == "|" { return false }
            // "(?" is group syntax, not a quantifier target.
            if p == "?" && k >= 2 && chars[k - 2] == "(" { return false }
            return true
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                if i + 1 >= chars.count { return "dangling backslash at column \(i + 1)" }
                i += 2
                continue
            }
            if classStart != nil {
                if c == "]" { classStart = nil }
                i += 1
                continue
            }
            switch c {
            case "[": classStart = i
            case "(": groups.append(i)
            case ")":
                if groups.popLast() == nil { return "unmatched \")\" at column \(i + 1)" }
            case "*", "+", "?":
                if !canRepeat(i) && !(c == "?" && i > 0 && chars[i - 1] == "(") {
                    return "nothing to repeat before \"\(c)\" at column \(i + 1)"
                }
            case "{":
                let rest = String(chars[i...])
                if rest.range(of: #"^\{\d+(,\d*)?\}"#, options: .regularExpression) == nil {
                    return "malformed {n,m} repeat at column \(i + 1) (escape a literal brace as \\{)"
                }
            default: break
            }
            i += 1
        }
        if let s = classStart { return "unclosed \"[\" at column \(s + 1)" }
        if let g = groups.last { return "unclosed \"(\" at column \(g + 1)" }
        return nil
    }
}
