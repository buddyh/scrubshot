import Foundation
import ImageIO
import ScrubshotCore

// `scrubshot serve`: a local web UI over a folder of screenshots. See the contract for the API.

// Globals the serve routes read live here, not in main.swift: top-level values in main.swift are only set
// once the script runs, so a test that imports the module would see them uninitialized.
let version = "0.1.0"
let defaultRulesPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/scrubshot/rules.json").path
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

/// Downscale image bytes so its longest side is at most `maxPixel`, encoded as PNG. Nil when unreadable.
func makeThumbnail(data: Data, maxPixel: Int) -> Data? {
    let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
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
    static let stateTTL = 0.25
    private let stateLock = NSLock()   // guards the caches below; held while computing state
    private var generation = 0          // bumped (under `lock`) when job state changes, to drop the memo
    private var reportCache: [String: (sig: String, report: FileResult?)] = [:]
    private var itemCache: [String: CachedItem] = [:]
    private var stateMemo: (at: Date, gen: Int, body: String, etag: String)?
    private let rulesJSON: String
    private let versionJSON: String
    private let workspaceJSON: String

    init(root: String, config: Config, rules: RuleSet, sources: [String], port: Int) {
        self.root = root
        self.config = config
        self.rules = rules
        self.sources = sources
        self.port = port
        self.rulesJSON = (try? serveEncode(ServeRules(count: rules.rules.count, sources: sources))) ?? "{}"
        self.versionJSON = (try? serveEncode(version)) ?? "\"\""
        // Shown in the page header; "~" keeps the user name out of screenshots of the page.
        self.workspaceJSON = (try? serveEncode((root as NSString).abbreviatingWithTildeInPath)) ?? "\"\""
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

    /// True when the entry is a regular file itself. Symlinks are refused, even ones that stay inside the folder.
    func isPlainFile(_ name: String) -> Bool {
        var st = stat()
        return lstat(path(name), &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Largest workspace file the server reads into memory (thumbnails, audits, scrubs, image views).
    static let maxReadBytes: off_t = 256 << 20

    /// Read a regular file without following a symlink at the final path. The check and the read use one
    /// descriptor, so swapping the entry for a symlink after a listing cannot redirect the read.
    func readPlainFile(_ name: String) -> Data? {
        // O_NONBLOCK so a FIFO or device entry can't hang the worker before fstat rejects it.
        let fd = open(path(name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Self.maxReadBytes else { return nil }
        // Read at most one byte past the cap, so a file that grows after fstat is still refused.
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: Int(Self.maxReadBytes) + 1)
        return data.count > Int(Self.maxReadBytes) ? nil : data
    }

    func outputName(_ input: String) -> String { (outputPath(for: path(input), explicit: nil) as NSString).lastPathComponent }
    func unsafeName(_ input: String) -> String { (outputPath(for: path(input), explicit: nil, suffix: "-scrubbed-UNSAFE") as NSString).lastPathComponent }
    func reportName(_ input: String) -> String { (reportPath(for: outputPath(for: path(input), explicit: nil)) as NSString).lastPathComponent }

    // MARK: state

    /// Result of `lstat` (does not follow symlinks): modification time in ms, size, and whether it is a directory.
    struct FileInfo {
        let mtimeMs: Int64; let size: Int64; let isDir: Bool; let isRegular: Bool
        /// Changes on any rewrite or replacement: size, full-precision mtime and ctime, and inode.
        let version: String
    }

    static func fileInfo(_ path: String) -> FileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let ms = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
        let version = "\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)|\(st.st_ino)"
        return FileInfo(mtimeMs: ms, size: Int64(st.st_size), isDir: (st.st_mode & S_IFMT) == S_IFDIR,
                        isRegular: (st.st_mode & S_IFMT) == S_IFREG, version: version)
    }

    /// The folder could not be listed in time, usually because macOS is waiting for the user to allow access.
    struct FolderWait: Error { let message: String }

    private final class ListingJob {
        let group = DispatchGroup()
        var result: Result<[String], Error>?
    }

    static let listTimeout = 2.0
    private let listLock = NSLock()
    private let listQueue = DispatchQueue(label: "scrubshot.list")
    private var listing: ListingJob?

    /// Names of the entries in the workspace folder. The listing runs on its own queue; if it is still blocked
    /// after `listTimeout` (a privacy prompt can hold open() for as long as it stays unanswered) this throws
    /// `FolderWait`. Callers share one blocked job, so a stuck folder never uses more than one thread.
    func listNames() throws -> [String] {
        listLock.lock()
        let job: ListingJob
        if let running = listing {
            job = running
        } else {
            job = ListingJob()
            job.group.enter()
            listing = job
            listQueue.async {
                let r = Result { try FileManager.default.contentsOfDirectory(atPath: self.root) }
                self.listLock.lock()
                job.result = r
                if self.listing === job { self.listing = nil }
                self.listLock.unlock()
                job.group.leave()
            }
        }
        listLock.unlock()
        if job.group.wait(timeout: .now() + Self.listTimeout) == .timedOut {
            throw FolderWait(message: "waiting for access to \(root) (macOS privacy prompt?)")
        }
        listLock.lock(); let r = job.result; listLock.unlock()
        return try (r ?? .failure(CLIError(message: "folder listing did not run"))).get()
    }

    private struct CachedItem { let sig: String; let json: String }

    /// Items as (name, input mtime, encoded JSON). Reports and encoded items are cached by file times, so a
    /// poll that changes nothing does one directory listing and a few stat calls per file.
    private func itemFragments(_ all: [String]) throws -> [(name: String, mtime: Int64, status: String, json: String)] {
        let present = Set(all)
        lock.lock()
        let queuedNow = Set(queued), runningNow = running, errorsNow = errors
        lock.unlock()

        var fragments: [(name: String, mtime: Int64, status: String, json: String)] = []
        fragments.reserveCapacity(all.count)
        var keep = Set<String>()
        for name in all where isInputName(name) && !name.hasPrefix(".") {
            let inPath = path(name)
            // Symlinks are never listed: lstat reports the link itself, which is not a regular file.
            guard let inInfo = Self.fileInfo(inPath), inInfo.isRegular else { continue }
            keep.insert(name)

            let stem = (name as NSString).deletingPathExtension
            let outName = stem + "-scrubbed.png", unsafe = stem + "-scrubbed-UNSAFE.png", rep = stem + "-scrubbed.report.json"
            var outInfo = present.contains(outName) ? Self.fileInfo(path(outName)) : nil
            var unsafeInfo = present.contains(unsafe) ? Self.fileInfo(path(unsafe)) : nil
            let repInfo = present.contains(rep) ? Self.fileInfo(path(rep)) : nil

            var report: FileResult?
            if let repInfo {
                let rsig = "\(repInfo.mtimeMs)|\(repInfo.size)"
                if let hit = reportCache[rep], hit.sig == rsig { report = hit.report }
                else {
                    if let data = readPlainFile(rep) { report = try? JSONDecoder().decode(FileResult.self, from: data) }
                    reportCache[rep] = (rsig, report)
                }
            } else {
                reportCache[rep] = nil
            }
            // shot.png and shot.jpg share output names. Results whose report names another input are not this item's.
            if let r = report, (r.input as NSString).lastPathComponent != name {
                report = nil; outInfo = nil; unsafeInfo = nil
            }
            var status = report?.status ?? (errorsNow[name] != nil ? "error" : "new")
            if runningNow == name { status = "running" } else if queuedNow.contains(name) { status = "queued" }
            let updated = [inInfo.mtimeMs, outInfo?.mtimeMs ?? 0, repInfo?.mtimeMs ?? 0].max() ?? 0
            let sig = [status, "\(updated)", "\(inInfo.mtimeMs)", outInfo == nil ? "-" : "o", unsafeInfo == nil ? "-" : "u",
                       "\(repInfo?.mtimeMs ?? -1)|\(repInfo?.size ?? -1)", errorsNow[name] ?? ""].joined(separator: "\u{1f}")
            if let hit = itemCache[name], hit.sig == sig {
                fragments.append((name, inInfo.mtimeMs, status, hit.json))
            } else {
                let item = ServeItem(name: name, status: status, output: outInfo == nil ? nil : outName,
                                     unsafe: unsafeInfo == nil ? nil : unsafe, report: report, updated: updated, error: errorsNow[name])
                let json = try serveEncode(item)
                itemCache[name] = CachedItem(sig: sig, json: json)
                fragments.append((name, inInfo.mtimeMs, status, json))
            }
        }
        if itemCache.count > keep.count { itemCache = itemCache.filter { keep.contains($0.key) } }
        if reportCache.count > keep.count {
            let reps = Set(keep.map { (($0 as NSString).deletingPathExtension) + "-scrubbed.report.json" })
            reportCache = reportCache.filter { reps.contains($0.key) }
        }
        return fragments.sorted { a, b in a.mtime != b.mtime ? a.mtime > b.mtime : a.name < b.name }
    }

    /// The state JSON and its ETag. Computed at most once per `stateTTL` unless a job changed something.
    func state() throws -> (body: String, etag: String) {
        if let m = freshMemo() { return m }
        let names = try listNames()   // outside stateLock, so a stuck folder never queues callers behind it
        return try stateLock.withLock {
            if let m = freshMemo() { return m }
            lock.lock()
            let gen = generation
            let busy = running != nil || !queued.isEmpty || auditsPending > 0
            lock.unlock()
            let frags = try itemFragments(names)
            let body = "{\"busy\":\(busy),\"items\":[" + frags.map(\.json).joined(separator: ",") + "],\"rules\":" + rulesJSON
                + ",\"version\":" + versionJSON + ",\"workspace\":" + workspaceJSON + "}"
            let etag = "\"" + fnv1a(body) + "\""
            lock.withLock { stateMemo = (Date(), gen, body, etag) }   // freshMemo reads it under `lock`
            return (body, etag)
        }
    }

    private func freshMemo() -> (body: String, etag: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let m = stateMemo, m.gen == generation, Date().timeIntervalSince(m.at) < Self.stateTTL else { return nil }
        return (m.body, m.etag)
    }

    // MARK: jobs

    /// Queue a scrub. A name already queued or running is not queued twice.
    func enqueueScrub(_ name: String) {
        lock.lock()
        if queued.contains(name) || running == name { lock.unlock(); return }
        queued.append(name)
        errors[name] = nil
        generation += 1
        lock.unlock()
        jobs.async { self.runScrub(name) }
    }

    private func runScrub(_ name: String) {
        lock.lock()
        queued.removeAll { $0 == name }
        running = name
        generation += 1
        lock.unlock()
        defer { lock.lock(); running = nil; generation += 1; lock.unlock() }

        let input = path(name)
        // Read once through readPlainFile and scrub those bytes, so the entry can't be swapped for a symlink
        // between the check and the decode.
        guard isInputName(name), let bytes = readPlainFile(name) else { setError(name, "input file is gone"); return }
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
        var r = scrubOne(input, c, rules, data: bytes)
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
        lock.lock(); errors[name] = message; generation += 1; lock.unlock()
    }

    /// Audit one input on the job queue, cached by (name, size, mtime). Calls `done` when the audit finishes;
    /// the calling thread is not held while OCR runs.
    func audit(_ name: String, done: @escaping (Result<String, Error>) -> Void) {
        guard isPlainFile(name), let info = Self.fileInfo(path(name)) else { done(.failure(CLIError(message: "no such image"))); return }
        let key = info.version
        lock.lock()
        if let hit = auditCache[name], hit.key == key { lock.unlock(); done(.success(hit.json)); return }
        auditsPending += 1
        generation += 1
        lock.unlock()

        jobs.async {
            self.lock.lock()
            let hit = self.auditCache[name]
            self.lock.unlock()
            let result: Result<String, Error>
            if let hit, hit.key == key {
                result = .success(hit.json)
            } else {
                result = Result {
                    guard let bytes = self.readPlainFile(name) else { throw CLIError(message: "no such image") }
                    return try encode(try auditImage(self.path(name), data: bytes, rules: self.rules, ocrScale: self.config.ocrScale))
                }
                if case .success(let json) = result {
                    self.lock.lock(); self.auditCache[name] = (key, json); self.lock.unlock()
                }
            }
            self.lock.lock(); self.auditsPending -= 1; self.generation += 1; self.lock.unlock()
            done(result)
        }
    }

    // MARK: thumbnails

    /// A small PNG of an input image, cached by (name, size, mtime, width).
    func thumbnail(_ name: String, width: Int) -> Data? {
        guard let info = Self.fileInfo(path(name)), info.isRegular else { return nil }
        let key = "\(name)|\(info.size)|\(info.mtimeMs)|\(width)"
        if let hit = thumbs.get(key) { return hit }
        guard let bytes = readPlainFile(name), let data = makeThumbnail(data: bytes, maxPixel: width) else { return nil }
        thumbs.put(key, data)
        return data
    }

    // MARK: upload

    /// Save bytes under `name`, or `stem-2.ext`, `stem-3.ext`... when taken. Never overwrites.
    func save(_ data: Data, as name: String) throws -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...10_000 {
            let candidate = n == 1 ? name : "\(stem)-\(n).\(ext)"
            let fd = open(path(candidate), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
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

    /// Slow, CPU-heavy requests get their own small lane in the server.
    func isHeavy(_ req: HTTPRequest) -> Bool { req.path == "/api/thumb" }

    /// Audits answer when OCR finishes without holding a server thread; everything else answers at once.
    func handleAsync(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        guard req.method == "GET", req.path == "/api/audit" else { respond(handle(req)); return }
        let host = (req.headers["host"] ?? "").lowercased()
        guard allowedHost(host) else { respond(fail(403, "bad Host header")); return }
        guard let name = validName(req.query["name"]), isInputName(name) else { respond(fail(400, "bad name")); return }
        guard isPlainFile(name) else { respond(fail(404, "no such image")); return }
        audit(name) { [self] result in
            switch result {
            case .success(let json): respond(noStore(.json(json)))
            case .failure(let e): respond(fail(500, (e as? CLIError)?.message ?? "\(e)"))
            }
        }
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
                let st = try state()
                let since = req.query["since"] ?? req.headers["if-none-match"]?.replacingOccurrences(of: "\"", with: "")
                var r = HTTPResponse.json(st.body)
                if let since, "\"" + since.replacingOccurrences(of: "\"", with: "") + "\"" == st.etag { r = HTTPResponse(status: 304) }
                r.headers["ETag"] = st.etag
                return noStore(r)
            case ("GET", "/api/image"):
                guard let name = validName(req.query["name"]), isImageName(name) else { return fail(400, "bad name") }
                guard let data = readPlainFile(name) else { return fail(404, "no such image") }
                return noStore(.data(data, contentType: mimeType(name)))
            case ("GET", "/api/thumb"):
                guard let name = validName(req.query["name"]), isImageName(name) else { return fail(400, "bad name") }
                var width = 160
                if let w = req.query["w"] {
                    guard let n = Int(w), n >= 16, n <= 512 else { return fail(400, "bad w: use 16...512") }
                    width = n
                }
                guard isPlainFile(name) else { return fail(404, "no such image") }
                guard let data = thumbnail(name, width: width) else { return fail(404, "cannot read image") }
                var r = HTTPResponse.data(data, contentType: "image/png")
                r.headers["Cache-Control"] = "private, max-age=3600"
                return r
            case ("GET", "/api/audit"):
                return fail(500, "audit needs the async handler")
            case ("POST", "/api/upload"):
                guard let name = validName(req.query["name"]), isInputName(name) else { return fail(400, "bad name: need an image file name that does not end in -scrubbed") }
                guard !req.body.isEmpty else { return fail(400, "empty body") }
                let saved = try save(req.body, as: name)
                enqueueScrub(saved)
                return .json(try serveEncode(["name": saved]))
            case ("POST", "/api/scrub"):
                // One named image per request. There is no "scrub the whole folder" route on purpose.
                guard let name = validName(req.query["name"]), isInputName(name) else { return fail(400, "bad name") }
                guard isPlainFile(name) else { return fail(404, "no such image") }
                enqueueScrub(name)
                return .json(try serveEncode(["queued": [name]]))
            default:
                let known = ["/", "/api/state", "/api/image", "/api/thumb", "/api/audit", "/api/upload", "/api/scrub"]
                return known.contains(req.path) ? fail(405, "method not allowed") : fail(404, "not found")
            }
        } catch let e as FolderWait {
            return fail(503, e.message)
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

/// 64-bit FNV-1a as hex; a cheap content tag for ETags.
func fnv1a(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
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
    sources += c.rulesFiles.map { $0 == "-" ? "<stdin>" : $0 }
    sources += c.inlineRules.indices.map { "--rules-json #\($0 + 1)" }
    sources += c.replaces.map { "--replace \($0.0)=\($0.1)" }
    sources += c.terms.map { "--term \($0.0)" }
    if c.emails == true { sources.append("--emails") }
    if c.urls == true { sources.append("--urls") }

    let app = ServeApp(root: root, config: c, rules: rules, sources: sources, port: port)
    app.hostAliases = hostAliases
    let server = LocalHTTPServer(port: port, maxBody: maxRequestBody, isHeavy: { app.isHeavy($0) }) { app.handleAsync($0, $1) }
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
