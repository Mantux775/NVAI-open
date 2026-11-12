import Foundation
import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Schlüssel klein geschrieben.
    let headers: [String: String]
    let body: Data
    /// Großer Körper, beim Empfang blockweise in eine Datei geschrieben (Routen, für die `HTTPServer.streamTarget`
    /// eine Teildatei nennt, etwa POST /api/loras/upload). Die Datei gehört dem Handler; was danach noch liegt, löscht
    /// der Server.
    var bodyFile: HTTPBodyFile? = nil

    var json: JSONValue? { JSON.parse(body) }
}

/// Ein gestreamter Anfragekörper: Datei, Länge und SHA-256 (beim Schreiben gerechnet).
struct HTTPBodyFile: Sendable {
    let url: URL
    let size: Int64
    let sha256: String
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
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}

/// Kleiner HTTP/1.1-Server auf Network.framework, nur über das Loopback-Interface erreichbar.
///
/// Eine Verbindung, eine Anfrage, dann `Connection: close` – das reicht für die NVAI-open-Clients
/// (URLSession, httpx) und hält den Parser einfach. Bodys kommen mit Content-Length;
/// chunked lehnt der Server mit 411 ab.
///
/// Große Uploads (seit 0.5.5 eigene LoRA-Dateien, oft 100 MB bis 1 GB): Nennt `streamTarget` für eine Anfrage eine
/// Teildatei, schreibt der Server den Körper beim Empfang blockweise (höchstens 1 MB im Speicher) dorthin und rechnet
/// dabei SHA-256. Sonst läge jeder Körper ganz im Puffer und würde für die Anfrage noch einmal kopiert, bei 300 MB auf
/// einem 8-GB-Mac also 600 MB.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Was mit dem Körper einer Anfrage geschieht, sobald ihr Kopf da ist.
    enum BodyHandling {
        case buffer
        /// in diese neue Teildatei schreiben
        case stream(to: URL)
        /// gleich antworten (falsche Angaben, kein Platz), ohne den Körper zu lesen
        case reject(HTTPResponse)
    }

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
    /// Gepufferte Körper: 64 MB (Bilder, Studio-Pakete per Formular) plus Platz für einen safetensors-Kopf samt Länge.
    private let maxBody = 64 * 1024 * 1024 + 64 * 1024
    /// Größte Datei, die eine gestreamte Anfrage schreiben darf (Platz prüft die Route vorher selbst).
    private let maxStream: Int64 = 64 * 1024 * 1024 * 1024
    var onStateChange: (@Sendable (State) -> Void)?
    /// Entscheidet je Anfrage (nach dem Kopf), ob der Körper gepuffert oder in eine Datei geschrieben wird.
    var streamTarget: (@Sendable (HTTPParser.Head) -> BodyHandling)?

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
            // Kopf da: soll der Körper in eine Datei? Dann ab hier blockweise, ohne Puffer
            if let decide = self.streamTarget, case .head(let head) = HTTPParser.head(buffer) {
                switch decide(head) {
                case .reject(let response):
                    self.send(response, on: connection)
                    return
                case .stream(let url):
                    self.startStreaming(connection, head, url: url, initial: buffer.subdata(in: head.bodyStart..<buffer.endIndex))
                    return
                case .buffer:
                    break
                }
            }
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

    private func startStreaming(_ connection: NWConnection, _ head: HTTPParser.Head, url: URL, initial: Data) {
        guard head.contentLength >= 0, Int64(head.contentLength) <= maxStream else {
            send(.error(head.contentLength < 0 ? 411 : 413,
                        head.contentLength < 0 ? t("Content-Length fehlt.", "Content-Length is missing.") : t("Anfrage zu groß.", "Request too large.")),
                 on: connection)
            return
        }
        let writer: HashingFileWriter
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = try HashingFileWriter(url: url)
        } catch {
            send(.error(500, error.localizedDescription), on: connection)
            return
        }
        // curl fragt bei großen Körpern erst nach („Expect: 100-continue“) und wartet sonst eine Sekunde
        if head.headers["expect"]?.lowercased() == "100-continue", initial.isEmpty {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }
        streamBody(connection, head, writer, chunk: initial)
    }

    /// Schreibt einen Block und holt den nächsten, bis Content-Length erreicht ist; dann der Handler mit der Datei.
    private func streamBody(_ connection: NWConnection, _ head: HTTPParser.Head, _ writer: HashingFileWriter, chunk: Data) {
        let wanted = Int64(head.contentLength)
        do {
            let rest = wanted - writer.size
            try writer.write(Int64(chunk.count) > rest ? chunk.prefix(Int(rest)) : chunk)
        } catch {
            writer.discard()
            send(.error(507, t("Datei nicht schreibbar: ", "Cannot write the file: ") + error.localizedDescription), on: connection)
            return
        }
        if writer.size >= wanted {
            let file = HTTPBodyFile(url: writer.url, size: writer.size, sha256: writer.finish())
            var request = head.request(body: Data())
            request.bodyFile = file
            let handler = self.handler
            Task {
                let response = await handler(request)
                try? FileManager.default.removeItem(at: file.url)  // nicht übernommen: weg damit
                self.send(response, on: connection)
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { writer.discard(); connection.cancel(); return }
            if let data, !data.isEmpty {
                self.streamBody(connection, head, writer, chunk: data)
            } else if isComplete || error != nil {
                writer.discard()  // abgebrochen (Knopf, Seite zu, Netz): Teildatei weg, wie unter Windows
                AppLog.info("Upload \(head.path) cancelled after \(writer.size) of \(wanted) bytes")
                connection.cancel()
            } else {
                self.streamBody(connection, head, writer, chunk: Data())
            }
        }
    }
}

enum HTTPParser {
    enum Result {
        case complete(HTTPRequest)
        case incomplete
        case invalid(Int, String)
    }

    /// Kopf einer Anfrage, sobald er ganz da ist: für die Entscheidung, ob der Körper in eine Datei geht.
    struct Head: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        /// -1, wenn Content-Length fehlt oder unlesbar ist
        let contentLength: Int
        /// Index im Empfangspuffer, an dem der Körper beginnt
        let bodyStart: Int

        func request(body: Data) -> HTTPRequest {
            HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        }
    }

    enum HeadResult {
        case head(Head)
        case incomplete
        case invalid(Int, String)
    }

    private static let headerEnd = Data([13, 10, 13, 10])

    static func parse(_ buffer: Data, maxBody: Int) -> Result {
        let h: Head
        switch head(buffer) {
        case .incomplete: return .incomplete
        case .invalid(let status, let detail): return .invalid(status, detail)
        case .head(let found): h = found
        }
        // ohne (lesbare) Content-Length: kein Körper, wie bisher
        let length = max(0, h.contentLength)
        guard length <= maxBody else { return .invalid(413, t("Anfrage zu groß.", "Request too large.")) }
        let available = buffer.endIndex - h.bodyStart
        if available < length { return .incomplete }
        return .complete(h.request(body: buffer.subdata(in: h.bodyStart..<(h.bodyStart + length))))
    }

    /// Abfrage wie ein Formular (application/x-www-form-urlencoded, so liest sie auch Starlette unter Windows): „+“
    /// ist ein Leerzeichen, %2B ein Plus. URLComponents ließe das „+“ stehen; ein Name „Meine LoRA“ aus Python
    /// (requests) oder einem Browser (URLSearchParams) kam dann als „Meine+LoRA“ an.
    static func query(of target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        var query: [String: String] = [:]
        let rest = target[target.index(after: mark)...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        for pair in rest.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            query[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return query
    }

    static func head(_ buffer: Data) -> HeadResult {
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
        let length = Int(headers["content-length"] ?? "") ?? -1
        let components = URLComponents(string: target)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        return .head(Head(method: method, path: path, query: query(of: target), headers: headers, contentLength: length,
                          bodyStart: end.upperBound))
    }
}
