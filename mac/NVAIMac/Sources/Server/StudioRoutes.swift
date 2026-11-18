import AVFoundation
import Foundation

/// REST des Studios (`/api/studio/*`), Pfade und Antworten wie im Windows-Server (main.py), damit Claude und
/// eigene Skripte auf beiden Systemen dasselbe schicken. Fehler der Befehle: 422, Unbekanntes: 404.
enum StudioRoutes {
    static func handle(_ req: HTTPRequest, _ parts: [String]) async throws -> HTTPResponse? {
        let store = StudioStore.shared
        let path = Array(parts.dropFirst(2))  // nach "api", "studio"
        let summary = req.query["format"] == "summary"
        do {
            switch (req.method, path.count, path.first ?? "") {
            case ("GET", 1, "projects"):
                return .json(JSONValue.array(await store.list()).any)
            case ("POST", 1, "projects"):
                let body = req.json?.objectValue ?? [:]
                let fps = body["fps"]?.arrayValue?.compactMap(\.intValue) ?? [24, 1]
                let p = try await store.create(name: body["name"]?.stringValue ?? "",
                                               width: body["width"]?.intValue ?? 1920,
                                               height: body["height"]?.intValue ?? 1080,
                                               fps: fps.count == 2 ? fps : [24, 1])
                return .json(StudioJSON.full(p, history: (0, 0)).any)
            case ("GET", 1, "presets"):
                // codec wie unter Windows (seit 0.5.9)
                return .json(StudioRender.presets.map { ["id": $0.id, "label": Lang.current == .de ? $0.label.de : $0.label.en,
                                                         "codec": $0.codec == .hevc ? "hevc" : $0.codec == .proRes4444 ? "prores" : "h264",
                                                         "ext": $0.ext] })
            case ("POST", 1, "import"):
                // Studio-Paket (.zip) oder Projektdatei (.json) als multipart/form-data, Feld file
                guard let boundary = Multipart.boundary(from: req.headers["content-type"]),
                      let part = Multipart.parts(req.body, boundary: boundary).first(where: { $0.name == "file" }), !part.data.isEmpty else {
                    return .error(422, t("Erwartet wird multipart/form-data mit dem Feld file.", "Expected multipart/form-data with the field file."))
                }
                // nur die Endung des Client-Dateinamens (seit 0.5.9; ein „/“ darin gab vorher einen Serverfehler 500)
                let ext = ((part.filename ?? "paket.zip") as NSString).pathExtension.lowercased()
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).\(ext.isEmpty ? "zip" : ext)")
                try part.data.write(to: temp)
                defer { try? FileManager.default.removeItem(at: temp) }
                let p = try await StudioPackage.importFile(temp, store: store)
                Task { @MainActor in await AppState.shared.refresh() }
                return .json(StudioJSON.full(p, history: (0, 0)).any)
            case ("GET", 1, "commands"):
                return .json(StudioCommands.names.map { ["command": $0, "help": ""] })
            case (_, 2..., "projects"):
                return try await project(req, store, id: path[1], rest: Array(path.dropFirst(2)), summary: summary)
            default:
                return nil
            }
        } catch let error as StudioError {
            return .error(error.notFound ? 404 : 422, error.message)
        }
    }

    private static func project(_ req: HTTPRequest, _ store: StudioStore, id: String, rest: [String],
                                summary: Bool) async throws -> HTTPResponse? {
        func view(_ p: StudioProject) async -> JSONValue {
            summary ? StudioJSON.summary(p) : StudioJSON.full(p, history: await store.history(p.id))
        }
        switch (req.method, rest.first ?? "") {
        case ("GET", ""):
            // fertige Erzeugungsaufträge sind dabei schon als Takes eingetragen
            let p = try await StudioGenerator.shared.refresh(store, id)
            return .json(await view(p).any)
        case ("DELETE", ""):
            try await store.delete(id)
            return .json(["ok": true])
        case ("POST", "command"):
            let body = req.json?.objectValue ?? [:]
            let (p, result) = try await store.apply(id, body["command"]?.stringValue ?? "", body["params"]?.objectValue ?? [:])
            return .json(JSONValue.object(["project": await view(p), "result": result]).any)
        case ("POST", "undo"):
            return .json(await view(try await store.undo(id)).any)
        case ("POST", "redo"):
            return .json(await view(try await store.redo(id)).any)
        case ("POST", "generate"):
            // Eine leere Liste heißt wie unter Windows „alle Szenen ohne Take“ (seit 0.5.9; vorher erzeugte der Mac nichts)
            let ids = req.json?["scene_ids"]?.arrayValue?.compactMap(\.stringValue)
            return .json(try await StudioGenerator.shared.generate(store, id, sceneIDs: ids?.isEmpty == true ? nil : ids).any)
        case ("POST", "cancel"):
            return .json(try await StudioGenerator.shared.cancel(store, id).any)
        case ("POST", "export"):
            let preset = req.json?["preset"]?.stringValue ?? "youtube-1080p"
            guard StudioRender.preset(preset) != nil else {
                return .error(422, t("Unbekannte Vorlage: \(preset)", "Unknown preset: \(preset)"))
            }
            let p = try await store.load(id)
            guard !p.clips.isEmpty else {
                return .error(422, t("Der Schnitt ist leer: erst Szenen übernehmen oder Clips anlegen.",
                                     "The edit is empty: conform scenes or add clips first."))
            }
            return .json(await JobQueue.shared.submitStudioExport(StudioExportRequest(projectID: id, preset: preset)).json)
        case ("GET", "package") where rest.count == 2 && rest[1] == "info":
            let p = try await store.load(id)
            let info = StudioPackage.info(p)
            return .json(["name": p.name, "files": info.files, "bytes": info.bytes, "master_bytes": 0])
        case ("GET", "package"):
            let p = try await store.load(id)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(p.id)-\(Int(Date().timeIntervalSince1970)).zip")
            do {
                try StudioPackage.build(p, to: out)
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            // Gestreamt (seit 0.5.9): Ein Paket mit Videos hat schnell einige GB und lag vorher zweimal im Speicher.
            // Die Teildatei löscht der Server, sobald er sie geöffnet hat. Dateiname wie unter Windows (FileResponse).
            let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.uint64Value ?? 0
            var response = HTTPResponse(status: 200, contentType: "application/zip")
            response.file = HTTPFileBody(url: out, offset: 0, length: size, removeAfterOpen: true)
            let name = "\(p.name).zip"
            let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 32 ? Character($0) : "_" })
            // nur ASCII im Kopf: .alphanumerics ließe „ü“ stehen
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let encoded = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ascii
            response.extraHeaders["Content-Disposition"] = "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
            return response
        case ("GET", "conform"):
            // Was „Übernehmen“ täte (neue Clips, ausgetauschtes Material, Überdeckungen), ohne etwas zu ändern
            let p = try await StudioGenerator.shared.refresh(store, id)
            await StudioMediaProbe.prefetch(StudioMediaProbe.referencedAssets([:], p))
            return .json(StudioCommands.conformPlan(p, store.env).any)
        default:
            return nil
        }
    }
}
