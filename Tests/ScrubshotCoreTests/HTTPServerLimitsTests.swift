import XCTest
@testable import ScrubshotCore

final class HTTPServerLimitsTests: XCTestCase {
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private(set) var peak = 0
        func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
    }

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 64
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }

    private func statuses(port: Int, count: Int) async -> [Int] {
        let s = session()
        return await withTaskGroup(of: Int.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)/x")!
                    guard let (_, r) = try? await s.data(from: url) else { return -1 }
                    return (r as? HTTPURLResponse)?.statusCode ?? -1
                }
            }
            var out: [Int] = []
            for await code in group { out.append(code) }
            return out
        }
    }

    /// Open a socket to the server and return the bytes it sends before closing, or after `wait` seconds.
    private func rawRead(port: Int, send: String = "", wait: TimeInterval) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return "connect failed" }
        if !send.isEmpty { _ = send.withCString { write(fd, $0, strlen($0)) } }
        var tv = timeval(tv_sec: Int(wait), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    func testHandlerConcurrencyIsBounded() async throws {
        let gauge = Gauge()
        var limits = LocalHTTPServer.Limits()
        limits.maxConcurrent = 2
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits) { _ in
            gauge.enter(); defer { gauge.leave() }
            Thread.sleep(forTimeInterval: 0.2)
            return .text("ok")
        }
        let port = try server.start()
        defer { server.stop() }
        let codes = await statuses(port: port, count: 8)
        XCTAssertEqual(codes.filter { $0 == 200 }.count, 8)
        XCTAssertLessThanOrEqual(gauge.peak, 2)
        XCTAssertGreaterThanOrEqual(gauge.peak, 1)
    }

    func testFullQueueAnswers503() async throws {
        var limits = LocalHTTPServer.Limits()
        limits.maxConcurrent = 1
        limits.maxQueued = 1
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits) { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .text("ok")
        }
        let port = try server.start()
        defer { server.stop() }
        let codes = await statuses(port: port, count: 6)
        XCTAssertTrue(codes.contains(503), "got \(codes)")
        XCTAssertTrue(codes.contains(200), "got \(codes)")
        XCTAssertFalse(codes.contains(-1), "got \(codes)")
    }

    func testAsyncHandlerDoesNotHoldASlot() async throws {
        var limits = LocalHTTPServer.Limits()
        limits.maxConcurrent = 1
        let later = DispatchQueue(label: "test.later", attributes: .concurrent)
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits, asyncHandler: { _, respond in
            later.asyncAfter(deadline: .now() + 0.4) { respond(.text("late")) }
        })
        let port = try server.start()
        defer { server.stop() }
        let start = Date()
        let codes = await statuses(port: port, count: 6)
        XCTAssertEqual(codes.filter { $0 == 200 }.count, 6)
        // One slot, but the handler returns at once; six 0.4s answers overlap instead of taking 2.4s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.8)
    }

    func testIdleConnectionGets408() throws {
        var limits = LocalHTTPServer.Limits()
        limits.readTimeout = 0.5
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits) { _ in .text("ok") }
        let port = try server.start()
        defer { server.stop() }
        let start = Date()
        let reply = rawRead(port: port, send: "GET / HTTP/1.1\r\nHost: x\r\n", wait: 5)   // headers never finish
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 408"), "got \(reply.prefix(40))")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testTricklingClientGets408AtDeadline() throws {
        var limits = LocalHTTPServer.Limits()
        limits.readTimeout = 1
        limits.requestDeadline = 2
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits) { _ in .text("ok") }
        let port = try server.start()
        defer { server.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let start = Date()
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // One byte every 0.5s keeps the idle timer fresh, so only the deadline can end this.
        for byte in Array("GET / HTTP/1.1\r\nHost: x\r\nX-Slow: aaaaaaaaaaaaaaaaaaaa".utf8) where Date().timeIntervalSince(start) < 6 {
            var b = byte
            if write(fd, &b, 1) <= 0 { break }
            let until = Date().addingTimeInterval(0.5)
            while Date() < until {
                let n = read(fd, &buf, buf.count)
                if n > 0 { out.append(contentsOf: buf[0..<n]) }
                if n == 0 { break }
            }
            if !out.isEmpty { break }
        }
        let reply = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 408"), "got \(reply.prefix(40))")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testConnectionCapAnswers503() throws {
        var limits = LocalHTTPServer.Limits()
        limits.maxConnections = 2
        limits.readTimeout = 3
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits) { _ in .text("ok") }
        let port = try server.start()
        defer { server.stop() }
        // Hold two idle connections open, then a third must be refused.
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<2 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            held.append(fd)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let reply = rawRead(port: port, send: "GET / HTTP/1.1\r\nHost: x\r\n\r\n", wait: 2)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 503"), "got \(reply.prefix(40))")
    }

    func testHeavyLaneKeepsOtherRequestsMoving() async throws {
        var limits = LocalHTTPServer.Limits()
        limits.maxConcurrent = 4
        limits.maxHeavy = 1
        let server = LocalHTTPServer(port: 0, maxBody: 1024, limits: limits, isHeavy: { $0.path == "/slow" }) { req in
            if req.path == "/slow" { Thread.sleep(forTimeInterval: 0.6) }
            return .text("ok")
        }
        let port = try server.start()
        defer { server.stop() }
        let s = session()
        let slow = Task { for _ in 0..<3 { _ = try? await s.data(from: URL(string: "http://127.0.0.1:\(port)/slow")!) } }
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Date()
        let (_, r) = try await s.data(from: URL(string: "http://127.0.0.1:\(port)/fast")!)
        XCTAssertEqual((r as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
        slow.cancel()
    }
}
