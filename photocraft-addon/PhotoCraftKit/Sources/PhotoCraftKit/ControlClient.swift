import Foundation
import Network

/// Fehler im Umgang mit dem PhotoCraft-Steuerkanal.
public enum ControlError: Error, LocalizedError, Equatable {
    /// Kein PhotoCraft mit Steuerkanal erreichbar – es wurde nichts gesendet.
    case notConnected(String)
    /// PhotoCraft hat die Anfrage abgelehnt (`ok: false`).
    case rejected(String)
    /// Verbindung während der Anfrage abgerissen – der Befehl wurde eventuell ausgeführt.
    case connectionLost(method: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let m): return m
        case .rejected(let m): return m
        case .connectionLost(let method, let detail):
            return t("Die Verbindung zu PhotoCraft ist während „\(method)“ abgerissen (\(detail)). "
                        + "Der Befehl wurde eventuell trotzdem ausgeführt.",
                     "The connection to PhotoCraft broke during \"\(method)\" (\(detail)). "
                        + "The command may have been carried out anyway.")
        }
    }
}

/// Alles, was den Ablauf mit PhotoCraft verbindet – der echte Client oder ein Replay im Test.
public protocol PhotoCraftControlling: AnyObject {
    func call(_ method: String, _ params: JSONValue, read: Bool) async throws -> JSONValue
}

public extension PhotoCraftControlling {
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await call(method, params, read: false)
    }

    /// Einen Engine-Befehl ausführen (Liste: `photocraft-cli commands`).
    func execute(_ command: String, _ params: JSONValue = [:], read: Bool = false) async throws -> JSONValue {
        try await call("engine.execute", ["command": .string(command), "params": params], read: read)
    }

    func inspect() async throws -> JSONValue { try await call("ui.inspect", [:], read: true) }
    func document() async throws -> JSONValue { try await execute("document.inspect", read: true) }

    /// Dokument `index` (Tab-Reihenfolge) nach vorn holen.
    func activate(_ index: Int) async throws {
        _ = try await call("ui.menu.invoke", ["id": .string("window.document.\(index)")])
    }
}

/// Client für den Steuerkanal einer mit `--control <port>` gestarteten PhotoCraft-Instanz.
///
/// Eine JSON-Zeile je Anfrage und Antwort; die erste Zeile jeder Verbindung meldet sich mit dem
/// Token an. Siehe docs/mac-port.md, Abschnitte 2 und 3.
public actor ControlClient: PhotoCraftControlling {
    /// PhotoCraft schließt nach 30 s Leerlauf – nach 20 s vorsorglich neu verbinden.
    public static let idleReconnect: TimeInterval = 20
    /// PhotoCraft antwortet spätestens nach 60 s.
    public static let replyTimeout: TimeInterval = 65

    public let port: UInt16
    public let tokenURL: URL
    private var transport: LineTransport?
    private var lastUsed = Date.distantPast
    private var nextID = 0

    public init(port: UInt16, tokenURL: URL) {
        self.port = port
        self.tokenURL = tokenURL
    }

    public func close() {
        transport?.cancel()
        transport = nil
    }

    private func token() throws -> String {
        guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            throw ControlError.notConnected(t("PhotoCraft wurde noch nicht mit NVAI-open-Anbindung gestartet.",
                                              "PhotoCraft has not been started with the NVAI-open connection yet."))
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64 else {
            throw ControlError.notConnected(t("Die Token-Datei \(tokenURL.path) ist ungültig.", "The token file \(tokenURL.path) is invalid."))
        }
        return token
    }

    private func connect() async throws {
        let token = try token()
        let line = LineTransport(port: port)
        do {
            try await line.start(timeout: 2)
        } catch {
            line.cancel()
            throw ControlError.notConnected(t("PhotoCraft mit NVAI-open-Anbindung läuft nicht.",
                                              "PhotoCraft with the NVAI-open connection is not running."))
        }
        do {
            try await line.send(line: ["id": "auth", "method": "auth", "params": ["token": .string(token)]])
            let reply = try await line.receive(id: "auth", timeout: Self.replyTimeout)
            guard reply["ok"]?.boolValue == true else {
                line.cancel()
                let reason = reply["error"]?.stringValue ?? "?"
                throw ControlError.notConnected(t("PhotoCraft lehnt die Anmeldung ab: \(reason)", "PhotoCraft refuses the sign-in: \(reason)"))
            }
        } catch let error as ControlError {
            throw error
        } catch {
            line.cancel()
            throw ControlError.notConnected(t("Anmeldung bei PhotoCraft gescheitert (\(error.localizedDescription)).",
                                              "Sign-in to PhotoCraft failed (\(error.localizedDescription))."))
        }
        transport = line
    }

    /// Anfrage senden und `result` zurückgeben. `read: true` erlaubt nach einem Verbindungsfehler
    /// genau eine Wiederholung; Bearbeitungen werden nie erneut gesendet, sobald sie abgeschickt waren.
    public func call(_ method: String, _ params: JSONValue, read: Bool) async throws -> JSONValue {
        for attempt in 1...2 {
            if transport != nil && Date().timeIntervalSince(lastUsed) > Self.idleReconnect { close() }
            if transport == nil { try await connect() }
            guard let line = transport else {
                throw ControlError.notConnected(t("PhotoCraft ist nicht erreichbar.", "PhotoCraft is not reachable."))
            }
            nextID += 1
            let rid = JSONValue.int(nextID)
            do {
                try await line.send(line: ["id": rid, "method": .string(method), "params": params])
            } catch {
                close()
                if attempt == 1 { continue } // nichts ist angekommen – gefahrlos
                throw ControlError.notConnected(t("PhotoCraft ist nicht erreichbar (\(error.localizedDescription)).",
                                                  "PhotoCraft is not reachable (\(error.localizedDescription))."))
            }
            let reply: JSONValue
            do {
                reply = try await line.receive(id: rid, timeout: Self.replyTimeout)
                lastUsed = Date()
            } catch {
                close()
                lastUsed = Date()
                if read && attempt == 1 { continue }
                throw ControlError.connectionLost(method: method, detail: error.localizedDescription)
            }
            guard reply["ok"]?.boolValue == true else {
                throw ControlError.rejected(reply["error"]?.stringValue ?? t("unbekannter Fehler", "unknown error"))
            }
            return reply["result"] ?? .null
        }
        throw ControlError.notConnected(t("PhotoCraft ist nicht erreichbar.", "PhotoCraft is not reachable."))
    }
}

/// Zeilenweiser Transport über `NWConnection` auf 127.0.0.1.
final class LineTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PhotoCraftKit.LineTransport")
    private var buffer = Data()

    enum TransportError: Error, LocalizedError {
        case closed, timeout, failed(String)
        var errorDescription: String? {
            switch self {
            case .closed: return t("Verbindung geschlossen", "connection closed")
            case .timeout: return t("Zeitüberschreitung", "timeout")
            case .failed(let m): return m
            }
        }
    }

    init(host: String = "127.0.0.1", port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            let finish: @Sendable (Error?) -> Void = { error in
                once.run { if let error { cont.resume(throwing: error) } else { cont.resume() } }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed(let e): finish(TransportError.failed(e.localizedDescription))
                case .waiting(let e): finish(TransportError.failed(e.localizedDescription)) // z. B. abgelehnt
                case .cancelled: finish(TransportError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(TransportError.timeout) }
        }
    }

    func cancel() { connection.cancel() }

    func send(line: JSONValue) async throws {
        var data = try line.serialized()
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Nächste Antwort mit dieser `id`; fremde Antworten (aus abgebrochenen Anfragen) überspringen.
    func receive(id: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line = try await nextLine(deadline: deadline)
            let reply = try JSONValue.parse(line)
            if reply["id"] == id { return reply }
        }
    }

    private func nextLine(deadline: Date) async throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TransportError.timeout }
            buffer.append(try await receiveChunk(timeout: remaining))
        }
    }

    private func receiveChunk(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, error in
                once.run {
                    if let error { cont.resume(throwing: error) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else { cont.resume(throwing: TransportError.closed) }
                }
            }
            let connection = connection
            queue.asyncAfter(deadline: .now() + timeout) {
                // Nur wenn die Antwort ausblieb: dann ist die Verbindung nicht mehr brauchbar.
                if once.run({ cont.resume(throwing: TransportError.timeout) }) { connection.cancel() }
            }
        }
    }
}

/// Führt genau einen Block aus – für Rückrufe, die sich gegenseitig zuvorkommen (Antwort vs. Timeout).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Gibt zurück, ob dieser Aufruf der erste war und `body` ausgeführt hat.
    @discardableResult
    func run(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        body()
        return true
    }
}
