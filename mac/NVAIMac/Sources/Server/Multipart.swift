import Foundation

/// Liest Felder aus multipart/form-data (POST /api/upload, POST /api/studio/import, Feld `file`).
enum Multipart {
    struct Part {
        var name: String
        var filename: String?
        var data: Data
    }

    /// Ein Feld als Bereich im Körper, ohne Kopie (seit 0.5.10 für gestreamte, eingeblendete Körper).
    struct Span {
        var name: String
        var filename: String?
        var range: Range<Data.Index>
        var isEmpty: Bool { range.isEmpty }
    }

    static func boundary(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for piece in contentType.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                return String(trimmed.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func parts(_ body: Data, boundary: String) -> [Part] {
        spans(body, boundary: boundary).map { Part(name: $0.name, filename: $0.filename, data: body.subdata(in: $0.range)) }
    }

    static func spans(_ body: Data, boundary: String) -> [Span] {
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let headerEnd = Data([13, 10, 13, 10])
        var result: [Span] = []
        // Der erste Trenner steht am Anfang (ohne CRLF davor), jeder weitere hinter einem CRLF: So endet ein Feld nie
        // an einem „--boundary“ mitten in seinen Daten, das nicht am Zeilenanfang steht.
        let first = Data("--\(boundary)".utf8)
        guard let start = body.range(of: first) else { return [] }
        var ranges: [Range<Data.Index>] = [start]
        var searchStart = start.upperBound
        while searchStart < body.endIndex, let r = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
        for (i, r) in ranges.enumerated() where i + 1 < ranges.count {
            // Feld zwischen diesem und dem nächsten Trenner, ohne das CRLF nach dem Trenner.
            var from = r.upperBound
            let end = ranges[i + 1].lowerBound
            if body[from..<min(from + 2, body.endIndex)] == Data([13, 10]) { from += 2 }
            guard from < end, let split = body.range(of: headerEnd, in: from..<end) else { continue }
            let head = String(decoding: body[from..<split.lowerBound], as: UTF8.self)
            var name = ""
            var filename: String?
            for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-disposition") {
                name = value(of: "name", in: line) ?? ""
                filename = value(of: "filename", in: line)
            }
            result.append(Span(name: name, filename: filename, range: split.upperBound..<end))
        }
        return result
    }

    private static func value(of key: String, in line: String) -> String? {
        for piece in line.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq].lowercased() == key {
                return String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

/// Felder eines Formular-Körpers, gepuffert oder gestreamt. Seit 0.5.10 gehen große Uploads und Studio-Pakete beim
/// Empfang in eine Teildatei (`HTTPServer`, `APIRouter.bodyHandling`), die hier nur eingeblendet wird (mmap): Die
/// Datei eines Feldes wird blockweise herausgeschrieben, nie ganz in den Speicher geladen. Vorher war bei 64 MB
/// Schluss (413), unter Windows nicht.
struct FormBody {
    let data: Data
    let spans: [Multipart.Span]

    /// Ab dieser Größe gehen POST /api/upload und POST /api/studio/import in eine Datei statt in den Puffer.
    static let streamFrom = 16 * 1024 * 1024

    init(_ req: HTTPRequest) throws {
        guard let boundary = Multipart.boundary(from: req.headers["content-type"]) else {
            throw APIError(422, t("Erwartet wird multipart/form-data mit dem Feld file.", "Expected multipart/form-data with the field file."))
        }
        data = try req.bodyFile.map { try Data(contentsOf: $0.url, options: .alwaysMapped) } ?? req.body
        spans = Multipart.spans(data, boundary: boundary)
    }

    func span(_ name: String) -> Multipart.Span? { spans.first { $0.name == name } }

    func text(_ name: String) -> String? {
        span(name).flatMap { String(data: data.subdata(in: $0.range), encoding: .utf8) }
    }

    func bytes(_ span: Multipart.Span) -> Data { data.subdata(in: span.range) }

    /// Inhalt eines Feldes in Blöcken zu 8 MB in eine neue Datei; scheitert das, ist die Datei wieder weg.
    func write(_ span: Multipart.Span, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw APIError(507, t("Datei nicht schreibbar: \(url.lastPathComponent)", "Cannot write the file: \(url.lastPathComponent)"))
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var position = span.range.lowerBound
            while position < span.range.upperBound {
                let end = min(position + 8 * 1024 * 1024, span.range.upperBound)
                try handle.write(contentsOf: data[position..<end])
                position = end
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw APIError(507, t("Datei nicht schreibbar: ", "Cannot write the file: ") + error.localizedDescription)
        }
    }

    /// Platz für den Körper und die daraus geschriebene Datei, beide im Ablageordner.
    static func checkSpace(_ bytes: Int64) throws {
        let folder = Settings.assetsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard 2 * bytes <= free - 256 * 1024 * 1024 else {
            let f = String(format: "%.1f", Double(free) / 1e9), b = String(format: "%.2f", Double(bytes) / 1e9)
            throw APIError(507, t("Zu wenig Platz in \(folder.path): \(f) GB frei; der Upload hat \(b) GB und braucht beim "
                                  + "Ablegen kurz das Doppelte.",
                                  "Not enough space in \(folder.path): \(f) GB free; the upload has \(b) GB and briefly "
                                  + "needs twice that while it is stored."))
        }
    }

    /// Teildatei für einen gestreamten Körper, versteckt im Ablageordner (Platz auf dem Laufwerk der Ablage).
    static func newPart() -> URL {
        Settings.assetsDirectory.appendingPathComponent(".body_\(UUID().uuidString.prefix(12).lowercased()).part")
    }

    /// Eine neue, versteckte Datei im Ablageordner mit dieser Endung (für das herausgeschriebene Feld).
    static func newFile(ext: String) -> URL {
        Settings.assetsDirectory.appendingPathComponent(".field_\(UUID().uuidString.prefix(12).lowercased()).\(ext)")
    }

    /// Reste abgebrochener Übertragungen (App beendet mitten im Hochladen) beim Start entfernen.
    static func removeStaleParts() {
        let folder = Settings.assetsDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where (name.hasPrefix(".body_") && name.hasSuffix(".part")) || name.hasPrefix(".field_") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
