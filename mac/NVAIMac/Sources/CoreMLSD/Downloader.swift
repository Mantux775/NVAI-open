// Ursprünglich aus ios/NVAILocal kopiert; seit NVAI-open für Mac 0.5.10 fortsetzbar.
import CryptoKit
import Foundation

/// Lädt eine große Datei und meldet unterwegs den Fortschritt.
///
/// **Fortsetzbar (seit Mac 0.5.10):** Die Daten gehen in eine Teildatei im Modellordner (`.partial/`). Ein Abbruch
/// (Knopf, Netz weg, App beendet) lässt sie liegen, und der nächste Versuch fragt per HTTP-Range nur den Rest an. Vorher
/// begann jeder Versuch bei null, bei 8 GB über eine langsame Leitung mehrere Stunden. Passen ETag oder Gesamtgröße nicht
/// mehr zur Teildatei (Datei auf Hugging Face geändert), fängt er von vorn an; `If-Range` übergeht der CDN von Hugging
/// Face (gemessen 20.11.2026: 206 auch mit falschem ETag), deshalb vergleicht der Downloader selbst. Kurze Netzfehler
/// und 5xx holt er bis zu fünfmal nach, jeweils ab dem Stand der Teildatei.
///
/// Bewusst Delegate-Blöcke und **nicht** `URLSession.bytes(from:)`: Letzteres liefert eine Sequenz *einzelner Bytes*.
/// Bei einem 1,5-GB-Modell wären das anderthalb Milliarden `await`-Durchläufe — der Download stand dadurch praktisch
/// still und lief irgendwann ins Timeout.
final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    struct Stand {
        let geladen: Int64
        let gesamt: Int64
        var anteil: Double { gesamt > 0 ? Double(geladen) / Double(gesamt) : 0 }
    }

    struct Fehler: LocalizedError {
        let text: String
        /// HTTP-Status, wenn der Server einen Fehler meldete; 5xx und 429 werden nachgeholt.
        var status: Int = 0
        /// Verbindung endete vor dem letzten Byte: nachholen.
        var unvollstaendig = false
        var errorDescription: String? { text }
    }

    /// Was zur Teildatei gehört: Adresse, ETag und Größe der vollständigen Datei.
    private struct Meta: Codable {
        var url: String
        var etag: String?
        var total: Int64?
    }

    /// Teildatei passt nicht mehr (andere Datei auf dem Server): ohne Wartezeit von vorn.
    private struct VonVorn: LocalizedError {
        var errorDescription: String? {
            t("Die Datei auf dem Server hat sich während des Ladens geändert.", "The file on the server changed while downloading.")
        }
    }

    /// Ordner der Teildateien, im Modellordner (gleicher Datenträger wie die Ziele, das Ablegen ist ein Umbenennen).
    static var partialFolder: URL { Settings.modelsDirectory.appendingPathComponent(".partial", isDirectory: true) }

    private let lock = NSLock()
    private var onProgress: ((Stand) -> Void)?
    private var weiter: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    // Zustand eines Versuchs; gesetzt vor task.resume(), danach nur in den Delegate-Methoden (serielle Queue)
    private var part: URL!
    private var metaURL: URL!
    private var meta = Meta(url: "")
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private var vonVorn = false
    private var schonFertig = false
    private var lastReport = Date.distantPast
    /// Zusätzliche Kopfzeilen (FLUX.2: das Token, wenn eins gespeichert ist)
    private var headers: [String: String] = [:]

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Großzügig: ein Modell kann bei langsamer Leitung eine Stunde brauchen. Der Wert gilt für Pausen zwischen
        // Paketen; bei den CDN-Umleitungen von Hugging Face ist Puffer gesünder.
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Lädt die URL und gibt den Pfad der fertigen Datei zurück; der Aufrufer verschiebt sie ans Ziel.
    func lade(_ url: URL, headers: [String: String] = [:], fortschritt: @escaping (Stand) -> Void) async throws -> URL {
        onProgress = fortschritt
        self.headers = headers
        // Schon abgebrochen: gar nicht erst laden (seit 0.5.9)
        try Task.checkCancellation()
        let folder = Self.partialFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.removeOldParts(in: folder)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        part = folder.appendingPathComponent("\(key).part")
        metaURL = folder.appendingPathComponent("\(key).json")
        meta = (try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))) ?? Meta(url: url.absoluteString)
        if meta.url != url.absoluteString { verwerfen(url) }
        defer { session.finishTasksAndInvalidate() }  // die Sitzung hält ihren Delegate fest, bis sie aufgelöst wird
        var versuche = 0, neuanfaenge = 0
        while true {
            try Task.checkCancellation()
            do {
                try await versuch(url)
                break
            } catch is VonVorn where neuanfaenge < 2 {
                neuanfaenge += 1
                AppLog.info("Download \(url.lastPathComponent): partial file no longer matches, starting over")
                verwerfen(url)
            } catch let error where Self.nachholbar(error) && versuche < 5 {
                versuche += 1
                AppLog.info("Download \(url.lastPathComponent): \(error.localizedDescription); retry \(versuche) from byte \(written)")
                try await Task.sleep(nanoseconds: UInt64(versuche) * 3_000_000_000)
            }
        }
        try? FileManager.default.removeItem(at: metaURL)
        return part
    }

    /// Ein Versuch ab dem Stand der Teildatei.
    private func versuch(_ url: URL) async throws {
        written = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? 0
        total = meta.total ?? 0
        failure = nil
        vonVorn = false
        schonFertig = false
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if written > 0 { request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (fortsetzung: CheckedContinuation<Void, Error>) in
                let t = session.dataTask(with: request)
                lock.withLock {
                    weiter = fortsetzung
                    task = t
                }
                t.resume()
                if Task.isCancelled { t.cancel() }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.task }?.cancel()
        }
    }

    /// Teildatei und Angaben verwerfen.
    private func verwerfen(_ url: URL) {
        try? FileManager.default.removeItem(at: part)
        try? FileManager.default.removeItem(at: metaURL)
        meta = Meta(url: url.absoluteString)
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: metaURL, options: .atomic) }
    }

    /// Netzfehler, abgerissene Verbindung, 5xx und 429: nachholen. Abbrechen und 4xx nicht.
    private static func nachholbar(_ error: Error) -> Bool {
        if let f = error as? Fehler { return f.unvollstaendig || f.status >= 500 || f.status == 429 }
        guard let code = (error as? URLError)?.code else { return false }
        return [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable, .badServerResponse].contains(code)
    }

    /// Teildateien, die zwei Wochen niemand fortgesetzt hat, aufräumen.
    private static func removeOldParts(in folder: URL) {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-14 * 24 * 3600)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < limit { try? fm.removeItem(at: url) }
        }
    }

    /// „bytes 100-199/548105171“ → (100, 548105171); „bytes */548105171“ → (nil, 548105171).
    private static func contentRange(_ value: String?) -> (start: Int64?, total: Int64?) {
        guard let value, let range = value.split(separator: " ").last else { return (nil, nil) }
        let pieces = range.split(separator: "/")
        let total = pieces.count == 2 ? Int64(pieces[1]) : nil
        let start = pieces.first.flatMap { $0.split(separator: "-").first }.flatMap { Int64($0) }
        return (start, total)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = Fehler(text: t("Keine HTTP-Antwort.", "No HTTP response."))
            completionHandler(.cancel)
            return
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let datei = dataTask.originalRequest?.url?.lastPathComponent ?? t("eine Datei", "a file")
        switch http.statusCode {
        case 206:
            let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range"))
            // Teildatei gehört zu einer anderen Fassung der Datei: von vorn
            if range.start != written || (meta.etag != nil && etag != nil && meta.etag != etag)
                || (meta.total != nil && range.total != nil && meta.total != range.total) {
                vonVorn = true
                completionHandler(.cancel)
                return
            }
            total = range.total ?? (written + max(0, http.expectedContentLength))
            if meta.etag == nil || meta.total == nil {
                meta.etag = meta.etag ?? etag
                meta.total = total > 0 ? total : nil
                saveMeta()
            }
            do {
                let h = try FileHandle(forWritingTo: part)
                try h.seekToEnd()
                handle = h
            } catch {
                failure = error
                completionHandler(.cancel)
                return
            }
        case 200:
            // ganze Datei (kein Range verlangt, oder der Server übergeht ihn): Teildatei neu
            written = 0
            total = max(0, http.expectedContentLength)
            meta.etag = etag
            meta.total = total > 0 ? total : nil
            saveMeta()
            guard FileManager.default.createFile(atPath: part.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: part) else {
                failure = Fehler(text: t("Teildatei nicht schreibbar: \(part.path)", "Cannot write the partial file: \(part.path)"))
                completionHandler(.cancel)
                return
            }
            handle = h
        case 416:
            // Range hinter dem Ende: Ist die Teildatei schon vollständig, ist der Download fertig. Der CDN von Hugging
            // Face schickt dabei kein Content-Range (gemessen 20.11.2026), dann zählt die gespeicherte Größe
            let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range"))
            if let full = range.total ?? meta.total, full == written, full > 0 {
                total = full
                schonFertig = true
            } else {
                vonVorn = true
            }
            completionHandler(.cancel)
            return
        default:
            // Ein Fehler kommt nicht als Datei an: Früher landete eine Fehlerseite sonst als „Modell“ im Entpacker
            failure = Fehler(text: t("Server antwortet mit \(http.statusCode) für \(datei).",
                                     "Server answered \(http.statusCode) for \(datei)."), status: http.statusCode)
            completionHandler(.cancel)
            return
        }
        onProgress?(Stand(geladen: written, gesamt: total))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error  // Platte voll: Teildatei bleibt, der Rest später
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 {
            lastReport = now
            onProgress?(Stand(geladen: written, gesamt: total))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let fortsetzung = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let w = weiter
            weiter = nil
            self.task = nil
            return w
        }
        if schonFertig {
            onProgress?(Stand(geladen: written, gesamt: total))
            fortsetzung?.resume()
        } else if vonVorn {
            fortsetzung?.resume(throwing: VonVorn())
        } else if let failure {
            fortsetzung?.resume(throwing: failure)
        } else if let error {
            // Abbrechen bleibt Abbrechen; die Teildatei bleibt für den nächsten Versuch liegen
            fortsetzung?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if total > 0, written != total {
            fortsetzung?.resume(throwing: Fehler(text: t("Verbindung endete nach \(written) von \(total) Bytes.",
                                                         "The connection ended after \(written) of \(total) bytes."),
                                                 unvollstaendig: true))
        } else {
            onProgress?(Stand(geladen: written, gesamt: max(total, written)))
            fortsetzung?.resume()
        }
    }
}
