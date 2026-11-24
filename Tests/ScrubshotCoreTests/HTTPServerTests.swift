import XCTest
@testable import ScrubshotCore

final class HTTPServerTests: XCTestCase {
    private func parse(_ s: String, maxBody: Int = 1024) -> HTTPRequest.ParseResult {
        HTTPRequest.parse(Data(s.utf8), maxBody: maxBody)
    }

    func testGetWithQueryAndPercentDecoding() {
        let raw = "GET /api/image?name=my%20file%2B1.png&x=a+b HTTP/1.1\r\nHost: 127.0.0.1:7317\r\nX-Test:  yes \r\n\r\n"
        guard case .request(let req, let consumed) = parse(raw) else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/api/image")
        XCTAssertEqual(req.query["name"], "my file+1.png")
        XCTAssertEqual(req.query["x"], "a b")
        XCTAssertEqual(req.headers["host"], "127.0.0.1:7317")
        XCTAssertEqual(req.headers["x-test"], "yes")
        XCTAssertTrue(req.body.isEmpty)
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testPostBodySplitOverTwoChunks() {
        let head = "POST /api/upload?name=a.png HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        let first = Data((head + "hello").utf8)
        guard case .needMore = HTTPRequest.parse(first, maxBody: 1024) else { return XCTFail("expected needMore") }
        let full = first + Data("world".utf8)
        guard case .request(let req, let consumed) = HTTPRequest.parse(full, maxBody: 1024) else { return XCTFail("expected request") }
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), "helloworld")
        XCTAssertEqual(consumed, full.count)
    }

    func testHeadersSplitNeedMore() {
        guard case .needMore = parse("GET / HTTP/1.1\r\nHost: x") else { return XCTFail("expected needMore") }
    }

    func testOversizeBody() {
        guard case .tooLarge = parse("POST /x HTTP/1.1\r\nContent-Length: 2000\r\n\r\n", maxBody: 1024) else { return XCTFail("expected tooLarge") }
    }

    func testGarbage() {
        guard case .bad = parse("not http at all\r\n\r\n") else { return XCTFail("expected bad") }
        guard case .bad = parse("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") else { return XCTFail("chunked should be bad") }
        guard case .bad = parse("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n") else { return XCTFail("bad length") }
    }

    func testLoopbackRoundTrip() async throws {
        let server = LocalHTTPServer(port: 0, maxBody: 1024) { req in
            .text("hello \(req.query["who"] ?? "nobody") via \(req.method)")
        }
        let port = try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(port, 0)
        let url = URL(string: "http://127.0.0.1:\(port)/hi?who=world")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello world via GET")
    }
}
