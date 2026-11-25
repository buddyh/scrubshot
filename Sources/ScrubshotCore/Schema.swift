import Foundation

/// Version of the JSON that `scrub --json`, `audit --json` and `--report` print. It only
/// goes up when a field is removed or changes meaning; new fields do not change it.
public let jsonSchemaVersion = 1

public enum RulesSchema {
    /// JSON Schema (draft 2020-12) for a rules file, as pretty JSON with sorted keys.
    public static func json() -> String {
        let str: [String: Any] = ["type": "string"]
        let bool: [String: Any] = ["type": "boolean"]
        let texts: [String: Any] = ["type": "array", "items": ["type": "string", "minLength": 1], "minItems": 1]
        let rule: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "description": "One rule. Give exactly one of term, terms or regex.",
            "anyOf": [["required": ["term"]], ["required": ["terms"]], ["required": ["regex"]]],
            "properties": [
                "term": ["type": "string", "minLength": 1, "description": "Literal text to replace."],
                "terms": ["type": "array", "items": ["type": "string", "minLength": 1], "minItems": 1,
                          "description": "Aliases that share one replacement."],
                "regex": ["type": "string", "minLength": 1, "description": "ICU regular expression."],
                "replace": [
                    "description": "Replacement text, \"auto\" (the default) for a stable fake value, or a list of "
                        + "candidates: scrubshot picks the one whose drawn width best matches the original, "
                        + "once per rule. Regex rules may use $1.",
                    "oneOf": [str, texts],
                ],
                "category": ["enum": Category.allCases.map(\.rawValue).sorted(),
                             "description": "Kind of fake value for \"auto\"."],
                "wholeWord": bool.merging(["description": "Do not match inside longer words."]) { a, _ in a },
                "caseSensitive": bool,
            ] as [String: Any],
        ]
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "scrubshot rules",
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "detectors": [
                    "type": "object", "additionalProperties": false,
                    "properties": ["email": bool, "url": bool],
                ],
                "rules": ["type": "array", "items": rule],
            ] as [String: Any],
            "x-scrubshot": ["jsonOutputSchemaVersion": jsonSchemaVersion],
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
