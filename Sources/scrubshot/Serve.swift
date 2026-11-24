import Foundation
import ImageIO
import ScrubshotCore

// `scrubshot serve`: a local web UI over a folder of screenshots. See the contract for the API.

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"]
let maxRequestBody = 64 * 1024 * 1024

struct ServeItem: Encodable {
    var name: String
    var status: String
    var output: String?
    var unsafe: String?
    var report: FileResult?
    var updated: Int64
    var error: String?

    enum CodingKeys: String, CodingKey { case name, status, output, unsafe, report, updated, error }

    // Optionals must encode as null, not be left out.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(output, forKey: .output)
        try c.encode(unsafe, forKey: .unsafe)
        try c.encode(report, forKey: .report)
        try c.encode(updated, forKey: .updated)
        try c.encode(error, forKey: .error)
    }
}

struct ServeRules: Encodable { let count: Int; let sources: [String] }
struct ServeState: Encodable {
    let workspace: String
    let version: String
    let rules: ServeRules
    let busy: Bool
    let items: [ServeItem]
}

/// In-memory cache of small rendered thumbnails, bounded by entry count and total bytes (oldest out first).
final class ThumbCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var order: [String] = []
    private var bytes = 0
    let maxEntries: Int
    let maxBytes: Int

    init(maxEntries: Int = 2000, maxBytes: Int = 48 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }

    func get(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func put(_ key: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let old = store[key] { bytes -= old.count } else { order.append(key) }
        store[key] = data
        bytes += data.count
        while (store.count > maxEntries || bytes > maxBytes) && !order.isEmpty {
            let k = order.removeFirst()
            if let d = store.removeValue(forKey: k) { bytes -= d.count }
        }
    }
}

/// Downscale an image file so its longest side is at most `maxPixel`, encoded as PNG. Nil when unreadable.
func makeThumbnail(path: String, maxPixel: Int) -> Data? {
    let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, srcOpts) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

final class ServeApp: @unchecked Sendable {
    let root: String
    let config: Config
    let rules: RuleSet
    let sources: [String]
    var port: Int
    /// Extra Host header names to accept, such as a .lab name a local reverse proxy forwards.
    var hostAliases: [String] = []

    private let lock = NSLock()
    private let jobs = DispatchQueue(label: "scrubshot.jobs")   // serial: scrubs and audits run one at a time
    private var queued: [String] = []
    private var running: String?
    private var auditsPending = 0
    private var errors: [String: String] = [:]
    private var auditCache: [String: (key: String, json: String)] = [:]
    let thumbs = ThumbCache()

    init(root: String, config: Config, rules: RuleSet, sources: [String], port: Int) {
        self.root = root
        self.config = config
        self.rules = rules
        self.sources = sources
        self.port = port
    }

    // MARK: names and files

    func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    /// A bare file name: no separators, no NUL, not hidden.
    func validName(_ name: String?) -> String? {
        guard let n = name, !n.isEmpty, !n.contains("/"), !n.contains("\\"), !n.contains("\0"), !n.hasPrefix(".") else { return nil }
        return n
    }

    func isImageName(_ name: String) -> Bool { imageExtensions.contains((name as NSString).pathExtension.lowercased()) }

    func isOutputStem(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return stem.hasSuffix("-scrubbed") || stem.hasSuffix("-scrubbed-UNSAFE")
    }

    func isInputName(_ name: String) -> Bool { isImageName(name) && !isOutputStem(name) }

    func mtimeMs(_ name: String) -> Int64? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: path(name)))?[.modificationDate] as? Date else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    /// True when the file is a regular file that really lives in the workspace (symlinks may not leave it).
    func insideWorkspace(_ name: String) -> Bool {
        let real = URL(fileURLWithPath: path(name)).resolvingSymlinksInPath().deletingLastPathComponent().path
        return real == URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    func outputName(_ input: String) -> String { (outputPath(for: path(input), explicit: nil) as NSString).lastPathComponent }
    func unsafeName(_ input: String) -> String { (outputPath(for: path(input), explicit: nil, suffix: "-scrubbed-UNSAFE") as NSString).lastPathComponent }
    func reportName(_ input: String) -> String { (reportPath(for: outputPath(for: path(input), explicit: nil)) as NSString).lastPathComponent }

    // MARK: state

    func items() -> [ServeItem] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { n in
            guard isInputName(n), !n.hasPrefix("."), insideWorkspace(n) else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path(n), isDirectory: &isDir) && !isDir.boolValue
        }
        lock.lock()
        let queuedNow = queued, runningNow = running, errorsNow = errors
        lock.unlock()
        let out: [ServeItem] = names.map { name in
            let outName = outputName(name), unsafe = unsafeName(name), rep = reportName(name)
            var report: FileResult?
            if let data = FileManager.default.contents(atPath: path(rep)) { report = try? JSONDecoder().decode(FileResult.self, from: data) }
            var status = report?.status ?? (errorsNow[name] != nil ? "error" : "new")
            if runningNow == name { status = "running" } else if queuedNow.contains(name) { status = "queued" }
            let updated = [name, outName, rep].compactMap { mtimeMs($0) }.max() ?? 0
            return ServeItem(name: name, status: status, output: exists(outName) ? outName : nil,
                             unsafe: exists(unsafe) ? unsafe : nil, report: report, updated: updated, error: errorsNow[name])
        }
        // Read each input's mtime once; stat calls inside the comparator stall on big folders.
        let keyed = out.map { ($0, mtimeMs($0.name) ?? 0) }
        return keyed.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.name < b.0.name }.map(\.0)
    }

    func state() throws -> String {
        lock.lock()
        let busy = running != nil || !queued.isEmpty || auditsPending > 0
        lock.unlock()
        return try serveEncode(ServeState(workspace: root, version: version,
                                          rules: ServeRules(count: rules.rules.count, sources: sources),
                                          busy: busy, items: items()))
    }

    // MARK: jobs

    /// Queue a scrub. A name already queued or running is not queued twice.
    func enqueueScrub(_ name: String) {
        lock.lock()
        if queued.contains(name) || running == name { lock.unlock(); return }
        queued.append(name)
        errors[name] = nil
        lock.unlock()
        jobs.async { self.runScrub(name) }
    }

    private func runScrub(_ name: String) {
        lock.lock()
        queued.removeAll { $0 == name }
        running = name
        lock.unlock()
        defer { lock.lock(); running = nil; lock.unlock() }

        let input = path(name)
        guard isInputName(name), exists(name) else { setError(name, "input file is gone"); return }
        guard !rules.rules.isEmpty else { setError(name, "no rules: pass --rules, --replace or --term, or add \(defaultRulesPath)"); return }
        // Remove this item's own earlier results so a failed re-run never leaves a stale output behind.
        for f in [outputName(name), unsafeName(name), reportName(name)] { try? FileManager.default.removeItem(atPath: path(f)) }

        var c = config
        c.inputs = [input]
        c.output = nil
        c.report = true
        c.json = false
        c.dryRun = false
        c.keepFailed = false
        var r = scrubOne(input, c, rules)
        if r.status == "error" {
            setError(name, r.error ?? "unknown error")
            if r.report == nil {   // scrubOne writes no report on early errors; write one so the UI can show it
                let rp = reportPath(for: outputPath(for: input, explicit: nil))
                r.report = rp
                try? encode(r).write(toFile: rp, atomically: true, encoding: .utf8)
            }
        }
    }

    private func setError(_ name: String, _ message: String) {
        lock.lock(); errors[name] = message; lock.unlock()
    }

    /// Audit one input on the job queue, cached by (name, size, mtime). Blocks the calling thread.
    func audit(_ name: String) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path(name))
        let key = "\(attrs[.size] ?? 0)|\(attrs[.modificationDate] ?? Date.distantPast)"
        lock.lock()
        if let hit = auditCache[name], hit.key == key { lock.unlock(); return hit.json }
        auditsPending += 1
        lock.unlock()

        final class Box { var value: Result<String, Error> = .failure(CLIError(message: "audit did not run")) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        jobs.async {
            self.lock.lock()
            let hit = self.auditCache[name]
            self.lock.unlock()
            if let hit, hit.key == key {
                box.value = .success(hit.json)
            } else {
                box.value = Result {
                    try encode(try auditImage(self.path(name), rules: self.rules, ocrScale: self.config.ocrScale))
                }
                if case .success(let json) = box.value {
                    self.lock.lock(); self.auditCache[name] = (key, json); self.lock.unlock()
                }
            }
            self.lock.lock(); self.auditsPending -= 1; self.lock.unlock()
            done.signal()
        }
        done.wait()
        return try box.value.get()
    }

    // MARK: thumbnails

    /// A small PNG of an input image, cached by (name, size, mtime, width).
    func thumbnail(_ name: String, width: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path(name)) else { return nil }
        let mtime = Int64(((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000)
        let key = "\(name)|\(attrs[.size] ?? 0)|\(mtime)|\(width)"
        if let hit = thumbs.get(key) { return hit }
        guard let data = makeThumbnail(path: path(name), maxPixel: width) else { return nil }
        thumbs.put(key, data)
        return data
    }

    // MARK: upload

    /// Save bytes under `name`, or `stem-2.ext`, `stem-3.ext`... when taken. Never overwrites.
    func save(_ data: Data, as name: String) throws -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...10_000 {
            let candidate = n == 1 ? name : "\(stem)-\(n).\(ext)"
            let fd = open(path(candidate), O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw CLIError(message: "cannot save \(candidate): \(String(cString: strerror(errno)))")
            }
            defer { close(fd) }
            let ok = data.withUnsafeBytes { buf -> Bool in
                var off = 0
                while off < buf.count {
                    let w = write(fd, buf.baseAddress! + off, buf.count - off)
                    if w <= 0 { return false }
                    off += w
                }
                return true
            }
            if !ok { try? FileManager.default.removeItem(atPath: path(candidate)); throw CLIError(message: "cannot write \(candidate)") }
            return candidate
        }
        throw CLIError(message: "too many files named \(name)")
    }

    // MARK: routing

    /// Loopback on our port, or a configured alias with or without a port.
    func allowedHost(_ host: String) -> Bool {
        if host == "127.0.0.1:\(port)" || host == "localhost:\(port)" { return true }
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        return hostAliases.contains(name)
    }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        let host = (req.headers["host"] ?? "").lowercased()
        guard allowedHost(host) else { return fail(403, "bad Host header") }
        if req.method == "POST" && req.headers["x-scrubshot"] != "1" { return fail(403, "missing X-Scrubshot header") }
        do {
            switch (req.method, req.path) {
            case ("GET", "/"):
                return .text(webPageHTML, contentType: "text/html; charset=utf-8")
            case ("GET", "/api/state"):
                return noStore(.json(try state()))
            case ("GET", "/api/image"):
                guard let name = validName(req.query["name"]) else { return fail(400, "bad name") }
                guard isImageName(name), exists(name), insideWorkspace(name),
                      let data = FileManager.default.contents(atPath: path(name)) else { return fail(404, "no such image") }
                return noStore(.data(data, contentType: mimeType(name)))
            case ("GET", "/api/thumb"):
                guard let name = validName(req.query["name"]), isImageName(name) else { return fail(400, "bad name") }
                var width = 160
                if let w = req.query["w"] {
                    guard let n = Int(w), n >= 16, n <= 512 else { return fail(400, "bad w: use 16...512") }
                    width = n
                }
                guard exists(name), insideWorkspace(name) else { return fail(404, "no such image") }
                guard let data = thumbnail(name, width: width) else { return fail(404, "cannot read image") }
                var r = HTTPResponse.data(data, contentType: "image/png")
                r.headers["Cache-Control"] = "private, max-age=3600"
                return r
            case ("GET", "/api/audit"):
                guard let name = validName(req.query["name"]), isInputName(name) else { return fail(400, "bad name") }
                guard exists(name), insideWorkspace(name) else { return fail(404, "no such image") }
                return noStore(.json(try audit(name)))
            case ("POST", "/api/upload"):
                guard let name = validName(req.query["name"]), isInputName(name) else { return fail(400, "bad name: need an image file name that does not end in -scrubbed") }
                guard !req.body.isEmpty else { return fail(400, "empty body") }
                let saved = try save(req.body, as: name)
                enqueueScrub(saved)
                return .json(try serveEncode(["name": saved]))
            case ("POST", "/api/scrub"):
                var names: [String]
                if req.query["name"] != nil {
                    guard let name = validName(req.query["name"]), isInputName(name) else { return fail(400, "bad name") }
                    guard exists(name), insideWorkspace(name) else { return fail(404, "no such image") }
                    names = [name]
                } else {
                    names = items().filter { $0.status == "new" }.map(\.name)
                }
                for n in names { enqueueScrub(n) }
                return .json(try serveEncode(["queued": names]))
            default:
                let known = ["/", "/api/state", "/api/image", "/api/thumb", "/api/audit", "/api/upload", "/api/scrub"]
                return known.contains(req.path) ? fail(405, "method not allowed") : fail(404, "not found")
            }
        } catch let e as CLIError {
            return fail(500, e.message)
        } catch {
            return fail(500, "\(error)")
        }
    }

    func fail(_ status: Int, _ message: String) -> HTTPResponse {
        .json((try? serveEncode(["error": message])) ?? "{}", status: status)
    }

    func noStore(_ r: HTTPResponse) -> HTTPResponse {
        var r = r
        r.headers["Cache-Control"] = "no-store"
        return r
    }

    func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}

/// Compact JSON with sorted keys.
func serveEncode<T: Encodable>(_ v: T) throws -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try e.encode(v), as: UTF8.self)
}

func runServe(_ args: Args) throws -> Int32 {
    var port = 7317
    var openBrowser = false
    var hostAliases: [String] = []
    var rest: [String] = []
    while let a = args.next() {
        switch a {
        case "--port":
            guard let p = Int(try args.value(a)), p >= 0, p <= 65535 else { throw CLIError(message: "--port must be 0...65535") }
            port = p
        case "--open": openBrowser = true
        case "--host-alias":
            let h = try args.value(a).lowercased()
            guard !h.isEmpty, !h.contains(":"), !h.contains("/"), h != "*" else { throw CLIError(message: "--host-alias wants a bare host name like scrubshot.internal") }
            hostAliases.append(h)
        default: rest.append(a)
        }
    }
    let c = try parse(Args(rest))
    guard c.inputs.count <= 1 else { throw CLIError(message: "serve takes one folder") }
    let folder = (((c.inputs.first ?? ".") as NSString).expandingTildeInPath)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
        throw CLIError(message: "not a folder: \(folder)")
    }
    let root = URL(fileURLWithPath: folder).standardizedFileURL.path
    let rules = try buildRules(c)
    if rules.rules.isEmpty { stderr("scrubshot: warning: no rules, scrubs will fail. Add \(defaultRulesPath), or pass --rules, --replace or --term") }

    var sources: [String] = []
    if c.defaultRules && FileManager.default.fileExists(atPath: defaultRulesPath) { sources.append("~/.config/scrubshot/rules.json") }
    sources += c.rulesFiles
    sources += c.replaces.map { "--replace \($0.0)=\($0.1)" }
    sources += c.terms.map { "--term \($0.0)" }
    if c.emails == true { sources.append("--emails") }
    if c.urls == true { sources.append("--urls") }

    let app = ServeApp(root: root, config: c, rules: rules, sources: sources, port: port)
    app.hostAliases = hostAliases
    let server = LocalHTTPServer(port: port, maxBody: maxRequestBody) { app.handle($0) }
    do { app.port = try server.start() } catch let e as LocalHTTPServer.StartError { throw CLIError(message: e.description) }
    let url = "http://127.0.0.1:\(app.port)"
    print("scrubshot: serving \(root) at \(url)")
    for h in hostAliases { print("scrubshot: also accepting Host \(h) (from a local reverse proxy)") }
    fflush(stdout)
    if openBrowser {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url]
        try? p.run()
    }
    dispatchMain()
}
