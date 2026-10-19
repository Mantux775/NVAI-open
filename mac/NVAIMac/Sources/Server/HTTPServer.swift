import Foundation
import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Schlüssel klein geschrieben.
    let headers: [String: String]
    let body: Data

    var json: JSONValue? { JSON.parse(body) }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String = "application/json"
    var body: Data = Data()
    var extraHeaders: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: JSON.data(object))
    }

    /// Fehler wie FastAPI: `{"detail": "…"}`.
    static func error(_ status: Int, _ detail: String) -> HTTPResponse {
        json(["detail": detail], status: status)
    }

    static func file(_ data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: contentType, body: data)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-cache\r\n"
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// Kleiner HTTP/1.1-Server auf Network.framework, nur über das Loopback-Interface erreichbar.
///
/// Eine Verbindung, eine Anfrage, dann `Connection: close` – das reicht für die NV-AI-Clients
/// (URLSession, httpx) und hält den Parser einfach. Bodys kommen mit Content-Length;
/// chunked lehnt der Server mit 411 ab.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum State: Equatable {
        case stopped
        case starting
        case listening(UInt16)
        case failed(String)
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "nvai.http.listener")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var attempts = 0
    private var retry: DispatchWorkItem?
    private let maxBody = 64 * 1024 * 1024
    var onStateChange: (@Sendable (State) -> Void)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Startet den Server und versucht es weiter, bis der Port frei ist.
    ///
    /// Gemessen am 19.10.2026: War Port 8100 beim Start belegt (hier von einer SSH-Weiterleitung),
    /// schlug der erste Bind fehl, und die App lief ohne Server weiter – auch nachdem der Port frei
    /// wurde. Jetzt wird alle 2 s neu versucht und jeder zehnte Fehlschlag protokolliert.
    func start(port: UInt16) {
        queue.async { self.bind(port: port, fresh: true) }
    }

    func stop() {
        queue.async {
            self.retry?.cancel()
            self.retry = nil
            self.listener?.cancel()
            self.listener = nil
            self.onStateChange?(.stopped)
        }
    }

    private func bind(port: UInt16, fresh: Bool) {
        retry?.cancel()
        retry = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        if fresh { attempts = 0 }
        self.port = port
        onStateChange?(.starting)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange?(.failed(t("Ungültiger Port \(port)", "Invalid port \(port)")))
            return
        }
        let parameters = NWParameters.tcp
        // Ausdrücklich 127.0.0.1: ohne das stand der Socket auf *:8100 (lsof).
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if self.attempts > 0 {
                        AppLog.info("Server listening on 127.0.0.1:\(port) (after \(self.attempts) failed attempts)")
                    } else {
                        AppLog.info("Server listening on 127.0.0.1:\(port)")
                    }
                    self.attempts = 0
                    self.onStateChange?(.listening(port))
                case .failed(let error), .waiting(let error):
                    self.scheduleRetry(error.localizedDescription)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            scheduleRetry(error.localizedDescription)
        }
    }

    private func scheduleRetry(_ reason: String) {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        attempts += 1
        if attempts == 1 || attempts % 10 == 0 {
            AppLog.error("Server on port \(port) not started: \(reason). Retrying every 2 s (attempt \(attempts)).")
        }
        onStateChange?(.failed(t("Port \(port): \(reason). Neuer Versuch …", "Port \(port): \(reason). Retrying …")))
        let port = self.port
        let work = DispatchWorkItem { [weak self] in self?.bind(port: port, fresh: false) }
        retry = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        let connectionQueue = DispatchQueue(label: "nvai.http.connection")
        connection.start(queue: connectionQueue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer, maxBody: self.maxBody) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            case .invalid(let status, let detail):
                self.send(.error(status, detail), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum HTTPParser {
    enum Result {
        case complete(HTTPRequest)
        case incomplete
        case invalid(Int, String)
    }

    private static let headerEnd = Data([13, 10, 13, 10])

    static func parse(_ buffer: Data, maxBody: Int) -> Result {
        guard let end = buffer.range(of: headerEnd) else {
            return buffer.count > 64 * 1024 ? .invalid(400, t("Kopfzeilen zu lang.", "Headers too long.")) : .incomplete
        }
        let headText = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        // components(separatedBy:) trennt am Text "\r\n" – ein Vergleich einzelner Zeichen
        // ginge schief, weil "\r\n" in Swift ein einziges Character ist.
        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else { return .invalid(400, t("Ungültige Anfragezeile.", "Invalid request line.")) }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid(411, t("Bitte mit Content-Length senden (chunked wird nicht unterstützt).", "Please send Content-Length (chunked is not supported)."))
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBody else { return .invalid(413, t("Anfrage zu groß.", "Request too large.")) }
        let bodyStart = end.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        if available < length { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))

        let components = URLComponents(string: target)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }
}
