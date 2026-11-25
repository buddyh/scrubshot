import Foundation
import Network

// A small HTTP/1.1 server for the local web UI. Loopback only, one request per connection,
// no keep-alive, no chunked request bodies (a body needs Content-Length).

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]   // keys lowercased
    public var body: Data

    public enum ParseResult {
        case needMore
        case request(HTTPRequest, consumed: Int)
        case tooLarge
        case bad
    }

    static let maxHeaderBytes = 64 * 1024

    /// Parse one request from the front of `data`. Pure, so it can be tested without sockets.
    public static func parse(_ input: Data, maxBody: Int) -> ParseResult {
        let data = Data(input)   // normalise indices to start at 0
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .tooLarge : .needMore
        }
        if sep.lowerBound > maxHeaderBytes { return .tooLarge }
        let head = String(decoding: data[0..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/"),
              !first[0].isEmpty, first[0].allSatisfy({ $0.isASCII && $0.isUppercase }) else { return .bad }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .bad }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .bad }
            if n > maxBody { return .tooLarge }
            length = n
        }
        let bodyStart = sep.upperBound
        guard data.count >= bodyStart + length else { return .needMore }

        let target = first[1]
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = String(rawPath[0]).removingPercentEncoding else { return .bad }
        var query: [String: String] = [:]
        if rawPath.count == 2 {
            for pair in rawPath[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let k = decodeComponent(String(kv[0])), let v = decodeComponent(kv.count == 2 ? String(kv[1]) : "") else { return .bad }
                query[k] = v
            }
        }
        let req = HTTPRequest(method: first[0], path: path, query: query, headers: headers,
                              body: data.subdata(in: bodyStart..<(bodyStart + length)))
        return .request(req, consumed: bodyStart + length)
    }

    static func decodeComponent(_ s: String) -> String? {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `json` is an already-encoded JSON string.
    public static func json(_ json: String, status: Int = 200) -> HTTPResponse {
        data(Data(json.utf8), contentType: "application/json; charset=utf-8", status: status)
    }

    public static func text(_ text: String, contentType: String = "text/plain; charset=utf-8", status: Int = 200) -> HTTPResponse {
        data(Data(text.utf8), contentType: contentType, status: status)
    }

    public static func data(_ data: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: data)
    }

    static let reasons = [200: "OK", 304: "Not Modified", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                          408: "Request Timeout", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]

    func serialized() -> Data {
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        var out = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        return Data(out.utf8) + body
    }
}

public final class LocalHTTPServer: @unchecked Sendable {
    public struct StartError: Error, CustomStringConvertible { public let description: String }

    /// Bounds that keep a few slow or idle clients from using up every thread.
    public struct Limits {
        public init() {}
    }

    public typealias Responder = (HTTPResponse) -> Void

    private let handler: (HTTPRequest, @escaping Responder) -> Void
    private let isHeavy: (HTTPRequest) -> Bool
    private let maxBody: Int
    private let limits: Limits
    private let queue = DispatchQueue(label: "scrubshot.http")
    private let work = DispatchQueue(label: "scrubshot.http.work", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    /// The bound port. Set by `start`.
    public private(set) var port: Int

    private final class Conn {
        let nw: NWConnection
        var closed = false
        init(_ nw: NWConnection) { self.nw = nw }
    }

    /// `port` 0 picks a free port. The handler may answer later, from any thread, by calling the responder once.
    /// It must not block waiting for slow work: hand that to another queue and call the responder when done.
    public init(port: Int, maxBody: Int, limits: Limits = Limits(), isHeavy: @escaping (HTTPRequest) -> Bool = { _ in false },
                asyncHandler: @escaping (HTTPRequest, @escaping Responder) -> Void) {
        self.port = port
        self.maxBody = maxBody
        self.limits = limits
        self.isHeavy = isHeavy
        self.handler = asyncHandler
    }

    /// A handler that answers before it returns.
    public convenience init(port: Int, maxBody: Int, limits: Limits = Limits(), isHeavy: @escaping (HTTPRequest) -> Bool = { _ in false },
                            handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.init(port: port, maxBody: maxBody, limits: limits, isHeavy: isHeavy) { req, respond in respond(handler(req)) }
    }

    /// Bind 127.0.0.1 and start accepting. Returns once the listener is ready.
    @discardableResult
    public func start() throws -> Int {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: UInt16(port))
        guard let nwPort else { throw StartError(description: "bad port \(port)") }
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = "\(e)"; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        l.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { l.cancel(); throw StartError(description: "listener did not start") }
        if let failure { l.cancel(); throw StartError(description: "cannot listen on 127.0.0.1:\(port): \(failure)") }
        listener = l
        if let p = l.port?.rawValue { port = Int(p) }
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ nw: NWConnection) {
        let c = Conn(nw)
        nw.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: Conn, _ buffer: Data) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf, maxBody: self.maxBody) {
            case .needMore:
                if error != nil || isComplete { self.close(c) } else { self.receive(c, buf) }
            case .request(let req, _):
                self.dispatch(req, on: c)
            case .tooLarge:
                self.send(c, Self.failure(413, "request too large"))
            case .bad:
                self.send(c, Self.failure(400, "bad request"))
            }
        }
    }

    private func dispatch(_ req: HTTPRequest, on c: Conn) {
        work.async { [self] in handler(req) { [self] response in send(c, response) } }
    }

    private static func failure(_ status: Int, _ message: String) -> HTTPResponse {
        .json("{\"error\":\"\(message)\"}", status: status)
    }

    /// Mark the connection closed once and free its slot. Returns false when it was already closed.
    private func markClosed(_ c: Conn) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if c.closed { return false }
        c.closed = true
        return true
    }

    private func close(_ c: Conn) {
        guard markClosed(c) else { return }
        c.nw.cancel()
    }

    private func send(_ c: Conn, _ response: HTTPResponse) {
        guard markClosed(c) else { return }
        c.nw.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in c.nw.cancel() })
    }
}
