import Foundation
import UniformTypeIdentifiers

/// Server-Teil des Bereichs „Ton-Forensik“ (seit 0.5.7): Der Bereich zeigt die Prüf-App (NVAI-Pruefer.html, dieselbe
/// Datei, die NVAI-open unter Windows in jedes Prüfpaket legt) in einem WKWebView. WebKit kann weder Ordner öffnen noch
/// „Speichern unter“ (File System Access gibt es nur in Chrome und Edge); deshalb liefert dieser Server das gewählte
/// Paket aus und nimmt Änderungen und Exporte an:
///
///     GET    /review/app                          die Prüf-App aus dem App-Bundle
///     GET    /review/pkg/<token>/<pfad>           Datei des Pakets, mit Range (Video, Ton, Spektrogramm)
///     PUT    /review/pkg/<token>/bearbeitung/<n>  Änderungen der Prüf-App (transkript.json, protokoll.jsonl …)
///     PUT    /review/out/<token>?at=<stelle>      Export stückweise in die per Dialog gewählte Datei
///     POST   /review/out/<token>                  Export fertig, Datei schließen
///     DELETE /review/out/<token>                  Export abgebrochen, halbe Datei löschen
///
/// Die Token entstehen nur über die Dialoge der App (`ReviewBridge`); der Server lauscht nur auf 127.0.0.1, und
/// `APIRouter.isLocal` weist fremde Origins ab. Gelesen wird nur innerhalb des gewählten Ordners, geschrieben nur in
/// dessen Unterordner „bearbeitung“: Die gelieferten Dateien bleiben unverändert (PRUEFSUMMEN.sha256).
enum ReviewRoutes {
    /// Offene Range-Anfragen (`bytes=a-`, so fragen Audio und Video) bekommen höchstens 4 MB: Sonst hielte jedes der
    /// vielen Medienelemente eine Verbindung offen, und WebKit hat je Server nur sechs (wie unter Windows `capped_file`).
    static let openRangeCap: UInt64 = 4 << 20
    /// Ausdrückliche Ausschnitte (`bytes=a-b`, Exporte lesen so) höchstens 256 MB je Antwort.
    static let rangeCap: UInt64 = 256 << 20

    static func handle(_ req: HTTPRequest, _ parts: [String]) async throws -> HTTPResponse? {
        guard parts.first == "review" else { return nil }
        if parts.count == 2, parts[1] == "app", req.method == "GET" { return app() }
        if parts.count >= 4, parts[1] == "pkg" {
            guard let root = await ReviewPackages.shared.root(parts[2]) else {
                throw APIError(404, t("Prüfpaket nicht geöffnet.", "Review package not open."))
            }
            return try packageFile(req, root: root, rel: Array(parts[3...]))
        }
        if parts.count == 3, parts[1] == "out" { return try await ReviewExports.shared.handle(req, token: parts[2]) }
        return nil
    }

    private static func app() -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: "NVAI-Pruefer", withExtension: "html"),
              let data = try? Data(contentsOf: url) else {
            return .error(404, t("NVAI-Pruefer.html fehlt im App-Bundle.", "NVAI-Pruefer.html is missing from the app bundle."))
        }
        return .file(data, contentType: "text/html; charset=utf-8")
    }

    /// Pfad im Paket ohne „..“, versteckte oder leere Teile; das Ergebnis liegt sicher unter `root`.
    static func resolve(_ root: URL, _ rel: [String]) throws -> URL {
        guard !rel.isEmpty, rel.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\\") }) else {
            throw APIError(400, t("Ungültiger Pfad.", "Invalid path."))
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = rel.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { throw APIError(400, t("Ungültiger Pfad.", "Invalid path.")) }
        return url
    }

    static func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "jsonl": return "application/x-ndjson"
        case "html": return "text/html; charset=utf-8"
        case "txt", "sha256", "md", "csv", "srt", "vtt": return "text/plain; charset=utf-8"
        case "webm": return "audio/webm"
        case "mp4", "m4v": return "video/mp4"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    private static func packageFile(_ req: HTTPRequest, root: URL, rel: [String]) throws -> HTTPResponse {
        if req.method == "PUT" {
            // nur „bearbeitung/<name>“: was die Prüf-App selbst schreibt
            guard rel.count == 2, rel[0] == "bearbeitung",
                  rel[1].range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$", options: .regularExpression) != nil else {
                throw APIError(403, t("Die Prüf-App schreibt nur in den Ordner „bearbeitung“.", "The review app only writes to the folder “bearbeitung”."))
            }
            let dir = root.appendingPathComponent("bearbeitung", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = try resolve(root, rel)
            try req.body.write(to: url, options: .atomic)
            return .json(["ok": true, "bytes": req.body.count])
        }
        guard req.method == "GET" else { throw APIError(405, "\(req.method)") }
        let url = try resolve(root, rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            throw APIError(404, t("Nicht im Paket: \(rel.joined(separator: "/"))", "Not in the package: \(rel.joined(separator: "/"))"))
        }
        var response = HTTPResponse(status: 200, contentType: contentType(url))
        response.extraHeaders["Accept-Ranges"] = "bytes"
        guard let header = req.headers["range"] else {
            response.file = HTTPFileBody(url: url, offset: 0, length: size)
            return response
        }
        guard let (start, end) = parseRange(header, size: size) else {
            var bad = HTTPResponse.error(416, "Range")
            bad.extraHeaders["Content-Range"] = "bytes */\(size)"
            return bad
        }
        response.status = 206
        response.file = HTTPFileBody(url: url, offset: start, length: end - start + 1)
        response.extraHeaders["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        return response
    }

    /// Eine Range der Form `bytes=a-b`, `bytes=a-` oder `bytes=-n`; Ergebnis einschließlich `end`, gekappt (siehe oben).
    static func parseRange(_ header: String, size: UInt64) -> (UInt64, UInt64)? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = value.dropFirst(6).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let ab = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard ab.count == 2 else { return nil }
        if ab[0].isEmpty {
            guard let n = UInt64(ab[1]), n > 0 else { return nil }
            let start = size - min(n, size)
            return (start, min(size - 1, start + openRangeCap - 1))
        }
        guard let start = UInt64(ab[0]), start < size else { return nil }
        if ab[1].isEmpty { return (start, min(size - 1, start + openRangeCap - 1)) }
        guard let end = UInt64(ab[1]), end >= start else { return nil }
        return (start, min(size - 1, end, start + rangeCap - 1))
    }
}

/// Geöffnete Prüfpakete: Token → Ordner (nur über den Ordner-Dialog oder die Startoption `--review-package`).
actor ReviewPackages {
    static let shared = ReviewPackages()
    private var roots: [String: URL] = [:]

    func register(_ root: URL) -> String {
        let token = UUID().uuidString.lowercased()
        roots[token] = root.standardizedFileURL
        AppLog.info("Review package opened (token \(token.prefix(8)))")
        return token
    }

    func root(_ token: String) -> URL? { roots[token] }

    /// Ein Ordner ist ein Prüfpaket, wenn fall/manifest.json „nvai-pruefpaket“ nennt.
    static func isPackage(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("fall/manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["format"] as? String == "nvai-pruefpaket"
    }
}

/// Exporte der Prüf-App (WAV, Video mit Ton, Untertitel, Text): Die Datei wählt der Speichern-Dialog der App, die Seite
/// schreibt dann stückweise hinein (MP4 mit Nachtrag der mdat-Größe am Ende, daher `at`).
actor ReviewExports {
    static let shared = ReviewExports()
    private var files: [String: (url: URL, handle: FileHandle, bytes: UInt64)] = [:]

    func register(_ url: URL) throws -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw APIError(500, t("Datei nicht anlegbar: \(url.lastPathComponent)", "Cannot create the file: \(url.lastPathComponent)"))
        }
        let handle = try FileHandle(forWritingTo: url)
        let token = UUID().uuidString.lowercased()
        files[token] = (url, handle, 0)
        return token
    }

    func handle(_ req: HTTPRequest, token: String) throws -> HTTPResponse {
        guard let f = files[token] else { throw APIError(404, t("Export nicht offen.", "Export not open.")) }
        switch req.method {
        case "PUT":
            guard let at = UInt64(req.query["at"] ?? "") else { throw APIError(400, "at") }
            try f.handle.seek(toOffset: at)
            try f.handle.write(contentsOf: req.body)
            files[token]?.bytes = max(f.bytes, at + UInt64(req.body.count))
            return .json(["ok": true])
        case "POST":
            try f.handle.synchronize()
            try f.handle.close()
            files[token] = nil
            AppLog.info("Review export saved: \(f.url.pathExtension), \(f.bytes) bytes")
            return .json(["ok": true, "bytes": f.bytes])
        case "DELETE":
            try? f.handle.close()
            try? FileManager.default.removeItem(at: f.url)
            files[token] = nil
            AppLog.info("Review export cancelled, partial file removed")
            return .json(["ok": true])
        default:
            throw APIError(405, req.method)
        }
    }
}
