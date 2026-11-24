import CoreGraphics
import Foundation

/// One entry of a rule's `"replace": [..]` list, as reported in the JSON record.
public struct CandidateOption: Codable, Equatable {
    public var text: String
    /// New text width minus the original's, in pixels, in the font fitted to the first
    /// occurrence of the rule (same meaning as `render.widthDelta`). Nil when the rule
    /// had nothing measurable.
    public var widthDelta: Double?
    public var chosen: Bool
}

extension Scrubber {
    /// For every rule with a candidate list, picks the candidate whose drawn width is closest
    /// to the original and applies it to all matches of that rule, so one real name always
    /// becomes one fake name in a run. The width is measured at the rule's first measurable
    /// occurrence, in the font and size the renderer chose for it. Ties go to the earlier
    /// candidate. Returns the report per rule id.
    static func resolveCandidates(plan: inout [PlannedEdit], analyses: inout [Renderer.Analysis?],
                                  choices: [(String, CGFloat)?]) -> [String: [CandidateOption]] {
        var picked: [String: Int] = [:]
        var reports: [String: [CandidateOption]] = [:]

        for (i, edit) in plan.enumerated() {
            guard let a = analyses[i], let (fontName, size) = choices[i], let fit = a.fit(named: fontName) else { continue }
            for (k, rep) in edit.reps.enumerated() where !rep.text.isEmpty {
                let rule = rep.match.rule
                guard picked[rule] == nil, let all = rep.match.candidates else { continue }
                let font = fit.cand.make(size)
                let prefix = (a.request.originalText as NSString).substring(to: a.request.keepPrefix)
                let deltas = all.map { cand -> Double in
                    var e = edit
                    e.reps[k].text = cand
                    e.recompose()
                    let line = Renderer.makeLine(prefix + e.newText, font: font)
                    return Double(fit.origin.x + Renderer.pathBounds(line).maxX - CGFloat(a.ink.x1))
                }
                var best = 0
                for (j, d) in deltas.enumerated() where abs(d) < abs(deltas[best]) - 0.05 { best = j }
                picked[rule] = best
                reports[rule] = all.enumerated().map {
                    CandidateOption(text: $1, widthDelta: (deltas[$0] * 10).rounded() / 10, chosen: $0 == best)
                }
            }
        }

        for i in plan.indices {
            for k in plan[i].reps.indices where !plan[i].reps[k].text.isEmpty {
                let m = plan[i].reps[k].match
                guard let all = m.candidates else { continue }
                // Rules never measured (no usable pixels) use their first candidate.
                let j = picked[m.rule] ?? 0
                if reports[m.rule] == nil {
                    reports[m.rule] = all.enumerated().map { CandidateOption(text: $1, widthDelta: nil, chosen: $0 == 0) }
                }
                plan[i].reps[k].text = all[j]
                plan[i].reps[k].match.replacement = all[j]
                if let mi = plan[i].matches.firstIndex(where: { $0.range == m.range && $0.rule == m.rule }) {
                    plan[i].matches[mi].replacement = all[j]
                }
            }
            plan[i].recompose()
            analyses[i]?.request.newText = plan[i].newText
        }
        return reports
    }
}
