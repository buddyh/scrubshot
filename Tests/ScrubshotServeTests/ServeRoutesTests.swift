import Foundation
import XCTest
@testable import ScrubshotCore
@testable import scrubshot

/// Calls ServeApp.handle directly with built requests, against a temp folder. No sockets, no OCR.
final class ServeRoutesTests: XCTestCase {
    var dir: String!        // the served workspace
    var outside: String!    // a sibling folder the server must never reach
    var app: ServeApp!
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "scrubshot-serve-\(UUID().uuidString)"
        dir = base + "/ws"
        outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        app = ServeApp(root: dir, config: Config(), rules: RuleSet(), sources: [], port: 7317)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent)
    }

    func req(_ path: String, query: [String: String] = [:], host: String = "127.0.0.1:7317") -> HTTPRequest {
        req("GET", path, query: query, host: host)
    }

    func req(_ method: String, _ path: String, query: [String: String] = [:], body: Data = Data(),
             host: String = "127.0.0.1:7317", post: Bool = true) -> HTTPRequest {
        var headers = ["host": host]
        if method == "POST" && post { headers["x-scrubshot"] = "1" }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    func names(_ r: HTTPResponse) throws -> [String] {
        let obj = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        return (obj["items"] as! [[String: Any]]).map { $0["name"] as! String }
    }

    func write(_ name: String, in folder: String? = nil, _ data: Data? = nil) throws {
        try (data ?? png).write(to: URL(fileURLWithPath: (folder ?? dir) + "/" + name))
    }

    // MARK: Host and header checks

    func testWrongHostRejected() {
        for host in ["evil.example", "127.0.0.1:9999", "localhost", ""] {
            XCTAssertEqual(app.handle(req("/api/state", host: host)).status, 403, host)
        }
        XCTAssertEqual(app.handle(req("/api/state")).status, 200)
    }

    func testPostWithoutHeaderRejected() throws {
        let r = app.handle(req("POST", "/api/upload", query: ["name": "a.png"], body: png, post: false))
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(app.handle(req("POST", "/api/scrub", post: false)).status, 403)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/a.png"))
    }

    // MARK: Names

    func testBadNamesRejected() throws {
        try write("secret.png", in: outside)
        let bad = ["../outside/secret.png", "/etc/passwd.png", dir + "/x.png", ".hidden.png", "a\\b.png", "", "x.txt"]
        for n in bad {
            XCTAssertEqual(app.handle(req("/api/image", query: ["name": n])).status, 400, "image \(n)")
            XCTAssertEqual(app.handle(req("/api/thumb", query: ["name": n])).status, 400, "thumb \(n)")
            XCTAssertEqual(app.handle(req("POST", "/api/upload", query: ["name": n], body: png)).status, 400, "upload \(n)")
            XCTAssertEqual(app.handle(req("POST", "/api/scrub", query: ["name": n])).status, 400, "scrub \(n)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), [])
    }

    func testOutputNamesCannotBeUploaded() {
        let r = app.handle(req("POST", "/api/upload", query: ["name": "x-scrubbed.png"], body: png))
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(app.handle(req("POST", "/api/upload", query: ["name": "x.png"], body: Data())).status, 400)
    }

    // MARK: Symlinks

    func testSymlinkToOutsideIsHiddenAndUnreadable() throws {
        try write("secret.png", in: outside)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.png", withDestinationPath: outside + "/secret.png")
        try write("real.png")

        XCTAssertEqual(try names(app.handle(req("/api/state"))), ["real.png"])
        XCTAssertEqual(app.handle(req("/api/image", query: ["name": "link.png"])).status, 404)
        XCTAssertEqual(app.handle(req("/api/thumb", query: ["name": "link.png"])).status, 404)
        XCTAssertEqual(app.handle(req("POST", "/api/scrub", query: ["name": "link.png"])).status, 404)
        XCTAssertEqual(app.handle(req("/api/image", query: ["name": "real.png"])).status, 200)
    }

    func testSymlinkInsideFolderIsAlsoRefused() throws {
        try write("real.png")
        try FileManager.default.createSymbolicLink(atPath: dir + "/alias.png", withDestinationPath: dir + "/real.png")
        XCTAssertEqual(try names(app.handle(req("/api/state"))), ["real.png"])
        XCTAssertEqual(app.handle(req("/api/image", query: ["name": "alias.png"])).status, 404)
    }

    func testSymlinkedFolderEntryIsRefused() throws {
        try FileManager.default.createDirectory(atPath: outside + "/dirs", withIntermediateDirectories: true)
        try write("a.png", in: outside + "/dirs")
        try FileManager.default.createSymbolicLink(atPath: dir + "/d.png", withDestinationPath: outside + "/dirs")
        XCTAssertEqual(try names(app.handle(req("/api/state"))), [])
        XCTAssertEqual(app.handle(req("/api/image", query: ["name": "d.png"])).status, 404)
    }

    func testPlainFileReadRefusesSymlinkSwap() throws {
        try write("secret.png", in: outside, Data("outside".utf8))
        try FileManager.default.createSymbolicLink(atPath: dir + "/x.png", withDestinationPath: outside + "/secret.png")
        XCTAssertNil(app.readPlainFile("x.png"))
        XCTAssertFalse(app.isPlainFile("x.png"))
    }

    func testFIFOEntryIsRefusedWithoutBlocking() throws {
        XCTAssertEqual(mkfifo(dir + "/pipe.png", 0o600), 0)
        let start = Date()
        XCTAssertNil(app.readPlainFile("pipe.png"))
        XCTAssertEqual(app.handle(req("/api/image", query: ["name": "pipe.png"])).status, 404)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "opening a FIFO blocked")
    }

    func testOversizedFileIsNotRead() throws {
        try write("big.png")
        let fd = open(dir + "/big.png", O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, ServeApp.maxReadBytes + 1), 0)   // sparse, so no real disk use
        close(fd)
        XCTAssertNil(app.readPlainFile("big.png"))
        XCTAssertEqual(app.handle(req("/api/thumb", query: ["name": "big.png"])).status, 404)
    }

    func testUploadDoesNotWriteThroughPlantedSymlink() throws {
        let target = outside + "/target.png"
        try FileManager.default.createSymbolicLink(atPath: dir + "/a.png", withDestinationPath: target)
        let r = app.handle(req("POST", "/api/upload", query: ["name": "a.png"], body: png))
        XCTAssertEqual(r.status, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "upload followed a symlink out of the folder")
        let saved = (try JSONSerialization.jsonObject(with: r.body) as! [String: String])["name"]
        XCTAssertEqual(saved, "a-2.png")
    }

    // MARK: Upload

    func testUploadExistingNameGetsNumberedAndKeepsOriginal() throws {
        let original = Data("original".utf8)
        try write("a.png", original)
        let r = app.handle(req("POST", "/api/upload", query: ["name": "a.png"], body: png))
        XCTAssertEqual(r.status, 200)
        let saved = (try JSONSerialization.jsonObject(with: r.body) as! [String: String])["name"]
        XCTAssertEqual(saved, "a-2.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/a.png")), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/a-2.png")), png)
    }

    func testUploadIsRoutedOnlyForPost() {
        XCTAssertEqual(app.handle(req("GET", "/api/upload")).status, 405)
        XCTAssertEqual(app.handle(req("GET", "/nope")).status, 404)
    }
}
