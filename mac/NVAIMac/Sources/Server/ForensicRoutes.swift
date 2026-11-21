import Foundation

/// REST-Wege der Ton-Forensik (seit 0.5.11), für Skripte und den Prüfstand; die Oberfläche ruft dieselben Funktionen.
///
///     GET  /api/forensic/cases                 Fälle in der Ablage
///     POST /api/forensic/cases                 {"files": [Pfad …], "name": "…"} → Auftrag „Neuer Fall“
///     POST /api/forensic/transcribe            {"folder": Pfad, "language": "de"?} → Auftrag „Sprache erkennen“
///     GET  /api/forensic/models                Whisper large-v3 und Silero VAD: geladen?
///     POST /api/forensic/models                beide laden (Aufträge „download“)
///
/// Pfade nur von diesem Rechner: Der Server lauscht nur auf 127.0.0.1 (`APIRouter.isLocal`).
enum ForensicRoutes {
    static func handle(_ req: HTTPRequest, _ parts: [String]) async throws -> HTTPResponse? {
        let path = Array(parts.dropFirst(2))
        let body = req.json?.objectValue ?? [:]
        switch (req.method, path.first ?? "", path.count) {
        case ("GET", "cases", 1):
            return .json(ForensicCases.list().map { c -> [String: Any] in
                ["folder": c.folder.path, "name": c.name, "project_id": c.projectID, "created": c.created, "duration": c.duration,
                 "tracks": c.tracks, "has_video": c.hasVideo, "segments": c.segments, "program": c.program]
            })
        case ("POST", "vdr", 1):
            // Vorschau eines VDR-Exports wie „Prüfen“ unter Windows: Zeitraum, Kanäle, Bildquellen, Platzbedarf
            guard let path = body["folder"]?.stringValue else { throw APIError(422, t("„folder“ fehlt.", "“folder” is missing.")) }
            do {
                return .json(try VDRPreview(URL(fileURLWithPath: path)).json)
            } catch {
                throw APIError(422, error.localizedDescription)
            }
        case ("POST", "cases", 1):
            if let path = body["vdr"]?.stringValue {
                // Fall aus einem VDR-Export (Ordner mit block.<n>.<id>.gz)
                let folder = URL(fileURLWithPath: path)
                do { _ = try VDR.findExport(folder) } catch { throw APIError(422, error.localizedDescription) }
                let job = await JobQueue.shared.submitForensicCase(
                    ForensicImport.Request(files: [folder], name: body["name"]?.stringValue ?? "", vdr: true))
                return .json(job.json)
            }
            let files = (body["files"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(fileURLWithPath: $0) }
            guard !files.isEmpty else { throw APIError(422, t("„files“ fehlt.", "“files” is missing.")) }
            for f in files where !FileManager.default.fileExists(atPath: f.path) {
                throw APIError(404, t("Datei nicht gefunden: \(f.lastPathComponent)", "File not found: \(f.lastPathComponent)"))
            }
            let job = await JobQueue.shared.submitForensicCase(ForensicImport.Request(files: files, name: body["name"]?.stringValue ?? ""))
            return .json(job.json)
        case ("POST", "transcribe", 1):
            guard let folder = body["folder"]?.stringValue.map({ URL(fileURLWithPath: $0) }), ForensicCases.isCase(folder) else {
                throw APIError(422, t("„folder“ muss ein Fall sein (mit fall/manifest.json).", "“folder” must be a case (with fall/manifest.json)."))
            }
            guard ForensicModel.whisper.installed else {
                throw APIError(409, t("Whisper large-v3 ist nicht geladen: POST /api/forensic/models.",
                                      "Whisper large-v3 is not downloaded: POST /api/forensic/models."))
            }
            let lang = body["language"]?.stringValue.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
            let job = await JobQueue.shared.submitForensicTranscribe(ForensicTranscribe.Request(folder: folder, language: lang))
            return .json(job.json)
        case ("POST", "translate", 1):
            guard let folder = body["folder"]?.stringValue.map({ URL(fileURLWithPath: $0) }), ForensicCases.isCase(folder) else {
                throw APIError(422, t("„folder“ muss ein Fall sein (mit fall/manifest.json).", "“folder” must be a case (with fall/manifest.json)."))
            }
            guard ForensicTranslate.installed else {
                throw APIError(409, t("\(ForensicTranslate.modelName) ist nicht geladen: POST /api/forensic/models mit translator=true.",
                                      "\(ForensicTranslate.modelName) is not downloaded: POST /api/forensic/models with translator=true."))
            }
            let target = body["target"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let job = await JobQueue.shared.submitForensicTranslate(ForensicTranslate.Request(folder: folder, target: target,
                                                                                               all: body["all"]?.boolValue ?? false))
            return .json(job.json)
        case ("GET", "models", 1):
            var list = ForensicModel.allCases.map { m -> [String: Any] in
                ["id": m.id, "name": m.name, "installed": m.installed, "size_gb": m.sizeGB, "license": m.license, "by": m.by]
            }
            list.append(["id": "forensic-translator", "name": ForensicTranslate.modelName, "installed": ForensicTranslate.installed,
                         "size_gb": ForensicTranslate.sizeGB, "license": "Apache-2.0", "by": "Alibaba (Qwen)"])
            return .json(list)
        case ("POST", "models", 1):
            var jobs: [[String: Any]] = []
            if body["translator"]?.boolValue == true {
                if !ForensicTranslate.installed { jobs.append(await JobQueue.shared.submitTranslatorDownload().json) }
            } else {
                for m in ForensicModel.allCases where !m.installed { jobs.append(await JobQueue.shared.submitDownload(m).json) }
            }
            return .json(["jobs": jobs])
        default:
            return nil
        }
    }
}
