import Foundation

public enum NVAIError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case http(Int, String)
    case invalidResponse(String)
    /// Erreichbar, aber nicht nutzbar: andere Vertragsversion (`api`) oder Zugriff verweigert.
    case incompatible(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let url): return t("NVAI-open ist nicht erreichbar (\(url)).", "NVAI-open is not reachable (\(url)).")
        case .http(let status, let detail): return t("NVAI-open meldet \(status): \(detail)", "NVAI-open reports \(status): \(detail)")
        case .invalidResponse(let m): return t("Unerwartete Antwort von NVAI-open: \(m)", "Unexpected answer from NVAI-open: \(m)")
        case .incompatible(let m): return m
        }
    }
}

/// Antwort von `GET /api/version` (ab NVAI-open 0.2.0).
public struct NVAIVersion: Equatable, Sendable {
    public var version: String
    /// Vertragsversion; steigt nur bei brechenden Änderungen.
    public var api: Int
    /// Bekannte Anfragefelder, z. B. `mask`, `references`, `upsampler`.
    public var features: [String]
    /// `local` (nur 127.0.0.1) oder `token` (Netz mit `X-NVAI-Token`).
    public var auth: String?
    /// Kämen Anfragen dieses Clients durch (Token passt bzw. lokal)?
    public var authorized: Bool

    public init(_ json: JSONValue) throws {
        guard let version = json["version"]?.stringValue, let api = json["api"]?.intValue else {
            throw NVAIError.invalidResponse("/api/version ohne version/api")
        }
        self.version = version
        self.api = api
        features = json["features"]?.arrayValue?.compactMap(\.stringValue) ?? []
        auth = json["auth"]?.stringValue
        authorized = json["authorized"]?.boolValue ?? true
    }
}

/// Client für die REST-API von NVAI-open (der Vertrag zwischen Windows-Server und Mac-App).
///
/// Basis-URL und Token sind frei wählbar (etwa über Tailscale); der Token geht als Header
/// `X-NVAI-Token` mit. Vertrag: contract/nvai-openapi.json; siehe docs/mac-port.md, Abschnitt 7.
public final class NVAIClient: @unchecked Sendable {
    /// Vertragsversion, die dieser Client spricht (`GET /api/version` → `api`).
    public static let apiVersion = 1

    public let baseURL: URL
    public let token: String?
    private let session: URLSession
    private var maskSupport: (Date, Bool)?
    private var versionInfo: (Date, NVAIVersion?)?
    private let lock = NSLock()

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Läuft NVAI-open auf diesem Rechner? Nur dann darf eine App es selbst starten.
    public var isLocal: Bool {
        ["127.0.0.1", "localhost", "::1"].contains((baseURL.host ?? "").lowercased())
    }

    // MARK: Transport

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: JSONValue? = nil,
                 body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!, timeoutInterval: timeout)
        req.httpMethod = method
        if let token { req.setValue(token, forHTTPHeaderField: "X-NVAI-Token") }
        // NVAI-open liefert Modelltexte und Fehlermeldungen in dieser Sprache (ohne Angabe Englisch).
        req.setValue(Localization.language, forHTTPHeaderField: "Accept-Language")
        if let json {
            req.httpBody = try json.serialized()
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw NVAIError.unavailable(baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw NVAIError.invalidResponse("keine HTTP-Antwort") }
        guard http.statusCode < 400 else {
            let detail = (try? JSONValue.parse(data))?["detail"]?.stringValue ?? String(decoding: data, as: UTF8.self)
            throw NVAIError.http(http.statusCode, detail)
        }
        return data
    }

    func requestJSON(_ method: String, _ path: String, query: [URLQueryItem] = [], json: JSONValue? = nil,
                     body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        let data = try await request(method, path, query: query, json: json, body: body, contentType: contentType, timeout: timeout)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    // MARK: Abfragen

    public func health() async throws -> JSONValue { try await requestJSON("GET", "/api/health", timeout: 4) }

    public func imageModels() async throws -> [JSONValue] {
        try await requestJSON("GET", "/api/models", query: [URLQueryItem(name: "kind", value: "image")]).arrayValue ?? []
    }

    /// `GET /api/version` (ohne Token abrufbar, 30 s gemerkt); `nil` bei Servern vor 0.2.0.
    public func version() async throws -> NVAIVersion? {
        let cached = lock.withLock { versionInfo }
        if let cached, Date().timeIntervalSince(cached.0) < 30 { return cached.1 }
        let info: NVAIVersion?
        do {
            info = try NVAIVersion(try await requestJSON("GET", "/api/version", timeout: 4))
        } catch NVAIError.http(404, _) {
            info = nil
        } catch is DecodingError {
            info = nil // alter Server, der unbekannte Pfade mit HTML beantwortet
        }
        lock.withLock { versionInfo = (Date(), info) }
        return info
    }

    /// Vertragsversion und Zugriff prüfen; wirft `NVAIError.incompatible` mit Klartext.
    @discardableResult
    public func checkCompatible() async throws -> NVAIVersion? {
        guard let info = try await version() else { return nil } // vor 0.2.0: wie bisher nutzbar
        guard info.api == Self.apiVersion else {
            throw NVAIError.incompatible(t("NVAI-open \(info.version) spricht API-Version \(info.api), diese App Version "
                                            + "\(Self.apiVersion). Bitte App oder NVAI-open aktualisieren.",
                                           "NVAI-open \(info.version) speaks API version \(info.api), this app version "
                                            + "\(Self.apiVersion). Please update the app or NVAI-open."))
        }
        guard info.authorized else {
            if info.auth == "local" { // ohne Token bedient NVAI-open nur den eigenen Rechner (403)
                throw NVAIError.incompatible(t("NVAI-open nimmt nur Anfragen vom eigenen Rechner an. Für den Zugriff von hier "
                                                + "NVAI-open dort mit „scripts\\start.ps1 -Lan“ starten und dessen Token (data\\api_token) eintragen.",
                                               "NVAI-open only accepts requests from its own computer. To use it from here, start "
                                                + "NVAI-open there with \"scripts\\start.ps1 -Lan\" and enter its token (data\\api_token)."))
            }
            throw NVAIError.incompatible(t("NVAI-open lehnt den Zugriff ab: Token fehlt oder ist falsch.",
                                           "NVAI-open refuses access: the token is missing or wrong."))
        }
        return info
    }

    /// Gemerkte Versions- und Maskenangaben verwerfen (nach Neustart von NVAI-open).
    public func forget() {
        lock.withLock { versionInfo = nil; maskSupport = nil }
    }

    /// Kennt der Server `mask_asset_id`? Ältere Server würden das Feld still ignorieren. Ab 0.2.0
    /// steht es in `/api/version` unter `features`, davor in `/openapi.json` (60 s gemerkt).
    public func supportsMasks() async throws -> Bool {
        if let info = try await version() { return info.features.contains("mask") }
        let cached = lock.withLock { maskSupport }
        if let cached, Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        let spec = try await requestJSON("GET", "/openapi.json", timeout: 4)
        let ok = spec["components"]?["schemas"]?["GenerateImageRequest"]?["properties"]?["mask_asset_id"] != nil
        lock.withLock { maskSupport = (Date(), ok) }
        return ok
    }

    /// Kennt der Server „Prompt ausbauen“ (`POST /api/prompt/expand`, NVAI-open ab 0.4 unter Windows,
    /// NVAI-open für Mac ab 0.4)? Steht in `/api/version` unter `features`.
    /// Kennt NVAI-open `outpaint` (Windows ab 0.5.4, Mac ab 0.4.3)? Dann legt der Server Rand und Maske selbst an.
    public func supportsOutpaint() async throws -> Bool {
        try await version()?.features.contains("outpaint") ?? false
    }

    public func supportsExpand() async throws -> Bool {
        try await version()?.features.contains("expand_prompt") ?? false
    }

    /// Knappen Prompt zur vollen Bildbeschreibung ausbauen. Das Sprachmodell lädt dafür erst; auf
    /// kleinen Macs dauert das über eine Minute, deshalb die lange Wartezeit.
    public func expandPrompt(_ prompt: String) async throws -> (expanded: String, seconds: Double) {
        let r = try await requestJSON("POST", "/api/prompt/expand", json: ["prompt": .string(prompt)], timeout: 600)
        guard let text = r["expanded"]?.stringValue, !text.isEmpty else {
            throw NVAIError.invalidResponse("/api/prompt/expand ohne expanded")
        }
        return (text, r["seconds"]?.doubleValue ?? 0)
    }

    /// Ein laufender oder wartender Modell-Download von NVAI-open.
    public struct Download: Equatable, Sendable {
        public var job: String
        public var name: String
        public var running: Bool
        public var progress: Double
        public var stage: String
    }

    /// Laufende und wartende Downloads (Windows: `params.entry.name`, Mac: `params.model_id`).
    public func downloads() async throws -> [Download] {
        let jobs = try await requestJSON("GET", "/api/jobs", query: [URLQueryItem(name: "limit", value: "50")], timeout: 4)
            .arrayValue ?? []
        return jobs.compactMap { j in
            guard j["kind"]?.stringValue == "download", let id = j["id"]?.stringValue,
                  let status = j["status"]?.stringValue, status == "queued" || status == "running" else { return nil }
            let p = j["params"]
            let name = p?["name"]?.stringValue ?? p?["entry"]?["name"]?.stringValue ?? p?["model_id"]?.stringValue ?? id
            return Download(job: id, name: name, running: status == "running",
                            progress: j["progress"]?.doubleValue ?? 0, stage: j["stage"]?.stringValue ?? "")
        }
    }

    /// Einen Download abbrechen (ab NVAI-open 0.5.2 bzw. Mac 0.4.2: `POST /api/jobs/{id}/cancel`).
    /// Ältere NVAI-open unter Windows kennen nur „alle Downloads abbrechen“.
    public func cancelDownload(_ jobID: String) async throws {
        if try await version()?.features.contains("cancel_job") == true {
            _ = try await request("POST", "/api/jobs/\(jobID)/cancel")
        } else {
            _ = try await request("POST", "/api/downloads/cancel")
        }
    }

    public func job(_ id: String) async throws -> JSONValue { try await requestJSON("GET", "/api/jobs/\(id)") }
    public func asset(_ id: String) async throws -> JSONValue { try await requestJSON("GET", "/api/assets/\(id)") }

    public func assets(kind: String? = nil, limit: Int = 200) async throws -> [JSONValue] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        return try await requestJSON("GET", "/api/assets", query: query).arrayValue ?? []
    }

    /// Datei eines Assets laden (`url` ist z. B. `/files/<name>`).
    public func fetch(_ urlPath: String) async throws -> Data {
        try await request("GET", urlPath, timeout: 60)
    }

    // MARK: Aufträge

    public static func multipartBody(boundary: String, field: String, filename: String, mime: String, data: Data) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// PNG hochladen (`POST /api/upload`, Feld `file`); die Antwort-`id` taugt als Start-, Masken-
    /// oder Referenzbild.
    public func upload(png: Data, filename: String) async throws -> JSONValue {
        let boundary = "PhotoCraftKit-\(UUID().uuidString)"
        let body = Self.multipartBody(boundary: boundary, field: "file", filename: filename, mime: "image/png", data: png)
        return try await requestJSON("POST", "/api/upload", body: body,
                                     contentType: "multipart/form-data; boundary=\(boundary)", timeout: 60)
    }

    public func generateImage(_ payload: JSONValue) async throws -> JSONValue {
        try await requestJSON("POST", "/api/generate/image", json: payload)
    }

    public func deleteAsset(_ id: String) async throws { _ = try await request("DELETE", "/api/assets/\(id)") }

    /// Nur den eigenen Auftrag stoppen – NVAI-open wird womöglich parallel anderweitig benutzt.
    public func cancel(jobID: String) async throws {
        let job = try await job(jobID)
        switch job["status"]?.stringValue {
        case "queued":
            _ = try await request("DELETE", "/api/jobs/\(jobID)")
        case "running":
            if try await health()["current_job"]?.stringValue == jobID {
                _ = try await request("POST", "/api/jobs/current/cancel")
            }
        default:
            break
        }
    }
}
