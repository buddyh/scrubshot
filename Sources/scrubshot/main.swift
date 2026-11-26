import Foundation
import ScrubshotCore

let cliVersion = version

let usage = """
scrubshot \(version) - replace sensitive text in screenshots, locally

USAGE
  scrubshot <image>... [options]          scrub images, write <name>-scrubbed.png
  scrubshot scrub <image>... [options]    same as above, with the command spelled out
  scrubshot audit <image> [options]       list every text span OCR finds
  scrubshot serve [folder] [options]      local web UI for a folder of screenshots
  scrubshot rules-path                    print the default rules file path
  scrubshot schema                        print the JSON Schema of a rules file

SCRUB OPTIONS
  -o, --output <path>     output file (one input only). Never the input itself.
  -r, --rules <file>      rules JSON (repeatable). Use - to read it from stdin.
                          Default: ~/.config/scrubshot/rules.json
      --rules-json <json> rules JSON given inline (repeatable)
      --no-default-rules  skip the default rules file
      --replace <a=b>     replace literal text a with b (repeatable)
      --term <text>       replace text with a stable fake value (repeatable).
                          Prefix a category to choose the kind of fake value:
                          person:, company:, product:, repo:, acronym:, email:, url:, word:
      --emails / --no-emails   detect email addresses (default: from rules, else off)
      --urls / --no-urls       detect URLs and domains (default: from rules, else off)
      --report            write <output>.report.json (what was replaced, and where)
      --json              print a JSON result to stdout (for scripts and agents)
      --dry-run           do everything except write files
      --keep-failed       if the leak check fails, still write <name>-scrubbed-UNSAFE.png
      --ocr-scale <n>     OCR upscale for finding text (default 1)
      --verify-scales <list>  OCR scales for the leak check (default 1,2)

AUDIT OPTIONS
  --json, --ocr-scale, and the rule options above (matches are marked).

SERVE OPTIONS
      --port <n>          port on 127.0.0.1 (default 7317; 0 picks a free port)
      --open              open the page in the default browser
      --host-alias <name> also accept this Host header (repeatable), for a local
                          reverse proxy such as Caddy serving scrubshot.internal
  folder defaults to the current directory. The rule options above apply.
  Open http://127.0.0.1:<port>; drop in screenshots, review, copy. Ctrl-C stops it.

EXIT CODES
  0 ok   1 error   2 leak check failed (no output written)
"""

struct CLIError: Error { let message: String }
/// A file could not be found, read or written.
struct IOFailure: Error { let message: String }

/// Stable machine-readable error codes: usage, rules, image_decode, image_encode, ocr, io, leak.
func classify(_ e: Error) -> (code: String, message: String) {
    switch e {
    case let e as CLIError: return ("usage", e.message)
    case let e as IOFailure: return ("io", e.message)
    case let e as ScrubError:
        let code: String
        switch e {
        case .usage: code = "usage"
        case .rules: code = "rules"
        case .imageDecode: code = "image_decode"
        case .imageEncode: code = "image_encode"
        case .ocr: code = "ocr"
        }
        return (code, e.description)
    case is CocoaError, is POSIXError: return ("io", (e as NSError).localizedDescription)
    default: return ("io", "\(e)")
    }
}

func requireReadable(_ path: String) throws {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        throw IOFailure(message: "no such file: \(path)")
    }
    guard FileManager.default.isReadableFile(atPath: path) else { throw IOFailure(message: "cannot read \(path)") }
}

final class Args {
    var items: [String]
    init(_ a: [String]) { items = a }
    var isEmpty: Bool { items.isEmpty }
    func next() -> String? { items.isEmpty ? nil : items.removeFirst() }
    func value(_ flag: String) throws -> String {
        guard let v = next() else { throw CLIError(message: "\(flag) needs a value") }
        return v
    }
}

struct Config {
    var inputs: [String] = []
    var output: String?
    var rulesFiles: [String] = []
    var inlineRules: [String] = []
    var defaultRules = true
    var replaces: [(String, String)] = []
    var terms: [(String, ScrubshotCore.Category)] = []
    var emails: Bool?
    var urls: Bool?
    var report = false
    var json = false
    var dryRun = false
    var keepFailed = false
    var ocrScale = 1.0
    var verifyScales: [Double] = [1, 2]
}

func parse(_ args: Args) throws -> Config {
    var c = Config()
    while let a = args.next() {
        switch a {
        case "-o", "--output": c.output = try args.value(a)
        case "-r", "--rules": c.rulesFiles.append(try args.value(a))
        case "--rules-json": c.inlineRules.append(try args.value(a))
        case "--no-default-rules": c.defaultRules = false
        case "--replace":
            let v = try args.value(a)
            guard let eq = v.firstIndex(of: "="), eq != v.startIndex else {
                throw CLIError(message: "--replace wants old=new, got \(v)")
            }
            c.replaces.append((String(v[..<eq]), String(v[v.index(after: eq)...])))
        case "--term":
            let v = try args.value(a)
            if let colon = v.firstIndex(of: ":"), let cat = ScrubshotCore.Category(rawValue: String(v[..<colon])) {
                c.terms.append((String(v[v.index(after: colon)...]), cat))
            } else {
                c.terms.append((v, .word))
            }
        case "--emails": c.emails = true
        case "--no-emails": c.emails = false
        case "--urls": c.urls = true
        case "--no-urls": c.urls = false
        case "--report": c.report = true
        case "--json": c.json = true
        case "--dry-run": c.dryRun = true
        case "--keep-failed": c.keepFailed = true
        case "--ocr-scale":
            guard let s = Double(try args.value(a)), s >= 1, s <= 4 else { throw CLIError(message: "--ocr-scale must be 1...4") }
            c.ocrScale = s
        case "--verify-scales":
            let list = try args.value(a).split(separator: ",").compactMap { Double($0) }
            guard !list.isEmpty, list.allSatisfy({ $0 >= 1 && $0 <= 4 }) else {
                throw CLIError(message: "--verify-scales wants a list like 1,2")
            }
            c.verifyScales = list
        case "-h", "--help": print(usage); exit(0)
        default:
            if a.hasPrefix("-") && a.count > 1 { throw CLIError(message: "unknown option \(a)") }
            c.inputs.append(a)
        }
    }
    return c
}

func buildRules(_ c: Config) throws -> RuleSet {
    var files: [RulesFile] = []
    var paths = c.rulesFiles
    if c.defaultRules && FileManager.default.fileExists(atPath: defaultRulesPath) { paths.insert(defaultRulesPath, at: 0) }
    var stdinUsed = false
    for p in paths {
        if p == "-" {
            guard !stdinUsed else { throw CLIError(message: "-r - can only be used once") }
            stdinUsed = true
            files.append(try RulesFile.parse(FileHandle.standardInput.readDataToEndOfFile(), source: "<stdin>"))
        } else {
            files.append(try RulesFile.load(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)))
        }
    }
    for (i, json) in c.inlineRules.enumerated() {
        files.append(try RulesFile.parse(Data(json.utf8), source: "--rules-json #\(i + 1)"))
    }
    var extra: [Rule] = []
    for (i, (a, b)) in c.replaces.enumerated() {
        extra.append(try RuleSet.rule(from: .init(term: a, replace: b), id: "replace\(i + 1)"))
    }
    for (i, (t, cat)) in c.terms.enumerated() {
        extra.append(try RuleSet.rule(from: .init(term: t, replace: "auto", category: cat), id: "term\(i + 1)"))
    }
    return try RuleSet.build(files: files, extra: extra, emailDetector: c.emails, urlDetector: c.urls)
}

func encode<T: Encodable>(_ v: T) throws -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try e.encode(v), as: UTF8.self)
}

func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: audit

struct AuditSpan: Codable {
    let text: String; let box: PixelRect; let confidence: Double
    /// Height of the span's text line in pixels, and the font size that line most likely
    /// has. Use them to judge how wide a replacement can be.
    let lineHeight: Int; let estFontSize: Double
}
struct AuditMatch: Codable {
    let text: String; let replacement: String; let rule: String
    let category: String?; let candidates: [String]?
}
struct AuditLine: Codable { let text: String; let box: PixelRect; let spans: [AuditSpan]; let matches: [AuditMatch] }
struct AuditResult: Codable { let schemaVersion: Int; let version: String; let image: String; let width: Int; let height: Int; let lines: [AuditLine] }

/// Vision's text box is a little taller than the font size; this ratio comes from system-font
/// screenshots and is an estimate, good to about a point.
func estimateFontSize(lineHeight: Double) -> Double { (lineHeight / 1.2 * 2).rounded() / 2 }

/// OCR one image and mark the spans the rules match.
/// `data`, when given, is the already-read file; `path` is then only used for naming.
func auditImage(_ path: String, data: Data? = nil, rules: RuleSet, ocrScale: Double) throws -> AuditResult {
    let loaded = try data.map { try ImageFile.load(data: $0, name: path) } ?? ImageFile.load(URL(fileURLWithPath: path))
    let lines = OCR.lines(try OCR.recognize(loaded.image, scale: ocrScale))
    let out = lines.map { l in
        AuditLine(text: l.text, box: PixelRect(l.box),
                  spans: l.parts.map { AuditSpan(text: $0.piece.text, box: PixelRect($0.piece.box),
                                                 confidence: (Double($0.piece.confidence) * 100).rounded() / 100,
                                                 lineHeight: PixelRect($0.piece.box).height,
                                                 estFontSize: estimateFontSize(lineHeight: $0.piece.box.height)) },
                  matches: rules.matches(in: l.text).map {
                      AuditMatch(text: $0.original, replacement: $0.replacement, rule: $0.rule,
                                 category: $0.category, candidates: $0.candidates)
                  })
    }
    return AuditResult(schemaVersion: jsonSchemaVersion, version: cliVersion, image: path, width: loaded.image.width, height: loaded.image.height, lines: out)
}

func audit(_ c: Config) throws -> Int32 {
    guard c.inputs.count == 1 else { throw CLIError(message: "audit takes exactly one image") }
    let path = c.inputs[0]
    try requireReadable(path)
    let result = try auditImage(path, rules: try buildRules(c), ocrScale: c.ocrScale)
    let out = result.lines
    if c.json {
        print(try encode(result))
    } else {
        print("\(path): \(result.width)x\(result.height), \(out.count) lines")
        for l in out {
            let conf = l.spans.map(\.confidence).min() ?? 0
            print(String(format: "%5d,%-5d %4dx%-3d %.2f  ", l.box.x0, l.box.y0, l.box.width, l.box.height, conf) + l.text)
            for m in l.matches { print("                         match: \(m.text) -> \(m.replacement)  [\(m.rule)]") }
        }
    }
    return 0
}

// MARK: scrub

struct FileResult: Codable {
    var schemaVersion: Int? = jsonSchemaVersion
    var version: String? = cliVersion
    let input: String
    var output: String?
    var report: String?
    var status: String
    var replacements: [ReplacementRecord]
    var leaks: [Leak]
    var warnings: [String]
    var error: String?
    /// Stable code for `error` (usage, rules, image_decode, image_encode, ocr, io) or "leak".
    var errorCode: String?
}

func outputPath(for input: String, explicit: String?, suffix: String = "-scrubbed") -> String {
    if let e = explicit { return (e as NSString).expandingTildeInPath }
    let url = URL(fileURLWithPath: input)
    let stem = url.deletingPathExtension().lastPathComponent
    return url.deletingLastPathComponent().appendingPathComponent(stem + suffix + ".png").path
}

func reportPath(for output: String) -> String {
    (output as NSString).deletingPathExtension + ".report.json"
}

func samePath(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
        == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
}

/// `data`, when given, is the already-read input; `input` is then only used for naming the outputs.
func scrubOne(_ input: String, _ c: Config, _ rules: RuleSet, data: Data? = nil) -> FileResult {
    var r = FileResult(input: input, status: "error", replacements: [], leaks: [], warnings: [])
    do {
        let out = outputPath(for: input, explicit: c.output)
        if samePath(out, input) { throw CLIError(message: "refusing to overwrite the input \(input)") }
        let loaded: ImageFile.Loaded
        if let data {
            loaded = try ImageFile.load(data: data, name: input)
        } else {
            try requireReadable(input)
            loaded = try ImageFile.load(URL(fileURLWithPath: input))
        }
        let result = try Scrubber.scrub(loaded.image, options: ScrubOptions(
            rules: rules, ocrScale: c.ocrScale, verifyScales: c.verifyScales))
        r.replacements = result.replacements
        r.leaks = result.leaks
        r.warnings = result.warnings
        var written: String?
        if result.leaks.isEmpty {
            r.status = "ok"
            if !c.dryRun {
                try ImageFile.writePNG(result.image, dpi: loaded.dpi, to: URL(fileURLWithPath: out))
                written = out
            }
        } else {
            r.status = "leak"
            r.errorCode = "leak"
            if c.keepFailed && !c.dryRun {
                let unsafe = outputPath(for: input, explicit: nil, suffix: "-scrubbed-UNSAFE")
                if !samePath(unsafe, input) {
                    try ImageFile.writePNG(result.image, dpi: loaded.dpi, to: URL(fileURLWithPath: unsafe))
                    written = unsafe
                }
            }
        }
        r.output = written
        if c.report && !c.dryRun {
            let rp = reportPath(for: written ?? out)
            r.report = rp
            try encode(r).write(toFile: rp, atomically: true, encoding: .utf8)
        }
    } catch {
        let (code, message) = classify(error)
        r.error = message
        r.errorCode = code
    }
    return r
}

/// Refuse a batch, before anything is written, when one file's outputs would replace another input
/// (`shot.png` and `shot-scrubbed.png`) or two inputs would write the same output (`shot.png` and `shot.jpg`).
/// Paths compare case-insensitively, as on a default macOS volume.
func checkOutputCollisions(_ c: Config) throws {
    func key(_ p: String) -> String {
        URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }
    var inputs: [String: String] = [:]
    for input in c.inputs { inputs[key(input)] = inputs[key(input)] ?? input }
    var owner: [String: String] = [:]
    for input in c.inputs {
        let out = outputPath(for: input, explicit: c.output)
        let unsafe = outputPath(for: input, explicit: nil, suffix: "-scrubbed-UNSAFE")
        for p in [out, reportPath(for: out), unsafe, reportPath(for: unsafe)] {
            let k = key(p)
            if let other = inputs[k] {
                throw CLIError(message: "\(input) would write over the input \(other); rename one")
            }
            if let prev = owner[k], key(prev) != key(input) {
                throw CLIError(message: "\(prev) and \(input) would write the same file \(p); rename one")
            }
            owner[k] = input
        }
    }
}

func scrub(_ c: Config) throws -> Int32 {
    guard !c.inputs.isEmpty else { throw CLIError(message: "no input images\n\n" + usage) }
    if c.output != nil && c.inputs.count > 1 { throw CLIError(message: "-o works with one input only") }
    try checkOutputCollisions(c)
    let rules = try buildRules(c)
    if rules.rules.isEmpty { throw CLIError(message: "no rules: add \(defaultRulesPath), or pass --rules, --replace or --term") }
    var results: [FileResult] = []
    for input in c.inputs {
        let r = scrubOne(input, c, rules)
        results.append(r)
        if c.json { continue }
        switch r.status {
        case "ok":
            let dest = r.output ?? "(dry run, nothing written)"
            print("ok    \(input) -> \(dest)  (\(r.replacements.count) replaced)")
        case "leak":
            print("LEAK  \(input): sensitive text still readable after scrubbing; no output written")
            for l in r.leaks { print("      \"\(l.text)\" at \(l.box) [\(l.rule), OCR x\(l.ocrScale)] in: \(l.line)") }
            if let o = r.output { print("      unsafe copy kept at \(o)") }
        default:
            print("ERROR \(input): \(r.error ?? "unknown error")")
        }
        for rep in r.replacements { print("      \(rep.original) -> \(rep.replacement)") }
        for w in r.warnings { stderr("      warning: \(w)") }
        if let rp = r.report { print("      report: \(rp)") }
    }
    if c.json { print(try encode(results)) }
    if results.contains(where: { $0.status == "error" }) { return 1 }
    if results.contains(where: { $0.status == "leak" }) { return 2 }
    return 0
}

// MARK: main

let args = Args(Array(CommandLine.arguments.dropFirst()))
do {
    switch args.items.first {
    case nil, "help", "-h", "--help":
        print(usage)
        exit(0)
    case "--version", "version":
        print(version)
        exit(0)
    case "schema":
        print(RulesSchema.json())
        exit(0)
    case "rules-path":
        print(defaultRulesPath)
        exit(0)
    case "audit":
        _ = args.next()
        exit(try audit(try parse(args)))
    case "serve":
        _ = args.next()
        exit(try runServe(args))
    case "scrub":
        _ = args.next()
        exit(try scrub(try parse(args)))
    default:
        exit(try scrub(try parse(args)))
    }
} catch {
    let (code, message) = classify(error)
    stderr("scrubshot: \(message)")
    // Under --json a failed run still gives a parseable answer on stdout.
    if CommandLine.arguments.contains("--json"), !["serve"].contains(CommandLine.arguments.dropFirst().first) {
        struct Failure: Encodable {
            struct Body: Encodable { let code: String; let message: String }
            let error: Body; let schemaVersion: Int; let version: String
        }
        if let out = try? encode(Failure(error: .init(code: code, message: message), schemaVersion: jsonSchemaVersion, version: cliVersion)) { print(out) }
    }
    exit(1)
}
