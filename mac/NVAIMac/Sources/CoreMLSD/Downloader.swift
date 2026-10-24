// Kopiert aus ios/NVAILocal (unverändert), für NVAI-open für Mac.
import Foundation

/// Laedt eine grosse Datei und meldet unterwegs den Fortschritt.
///
/// Bewusst `URLSessionDownloadTask` und **nicht** `URLSession.bytes(from:)`:
/// Letzteres liefert eine Sequenz *einzelner Bytes*. Bei einem 1,5-GB-Modell
/// waeren das anderthalb Milliarden `await`-Durchlaeufe — der Download stand
/// dadurch praktisch still und lief irgendwann ins Timeout. Der Download-Task
/// schreibt dagegen im Hintergrund in eine temporaere Datei und meldet den
/// Fortschritt ueber den Delegate.
final class Downloader: NSObject, URLSessionDownloadDelegate {

    struct Stand {
        let geladen: Int64
        let gesamt: Int64
        var anteil: Double { gesamt > 0 ? Double(geladen) / Double(gesamt) : 0 }
    }

    struct Fehler: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private var onProgress: ((Stand) -> Void)?
    private var weiter: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Grosszuegig: ein Modell kann bei langsamer Leitung eine Stunde brauchen.
        // Der Standardwert von 60 s gilt zwar nur fuer Pausen zwischen Paketen,
        // aber bei HuggingFace-CDN-Umleitungen ist Puffer gesünder.
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Laedt die URL und gibt den Pfad der fertigen temporaeren Datei zurueck.
    func lade(_ url: URL, fortschritt: @escaping (Stand) -> Void) async throws -> URL {
        onProgress = fortschritt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { fortsetzung in
                weiter = fortsetzung
                let t = session.downloadTask(with: url)
                task = t
                t.resume()
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(Stand(geladen: totalBytesWritten, gesamt: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Ein Download-Task scheitert nicht an 404 -- er speichert dann die
        // Fehlerseite. Ohne diese Pruefung landete sie als „Modell" im Entpacker.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let datei = downloadTask.originalRequest?.url?.lastPathComponent ?? t("eine Datei", "a file")
            weiter?.resume(throwing: Fehler(text: t("Server antwortet mit \(http.statusCode) für \(datei).",
                                                    "Server answered \(http.statusCode) for \(datei).")))
            weiter = nil
            return
        }
        // `location` wird direkt nach dieser Methode geloescht -- also sofort
        // an einen eigenen Platz verschieben.
        let ziel = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvai-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: ziel)
            weiter?.resume(returning: ziel)
        } catch {
            weiter?.resume(throwing: error)
        }
        weiter = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Die Sitzung haelt ihren Delegate fest, bis sie aufgeloest wird. Bei
        // vielen Einzeldateien sammelten sich sonst Dutzende Sitzungen an.
        session.finishTasksAndInvalidate()
        guard let error else { return }          // Erfolg meldet didFinishDownloadingTo
        weiter?.resume(throwing: error)
        weiter = nil
    }
}
